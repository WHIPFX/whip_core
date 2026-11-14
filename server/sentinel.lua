-- ============================================
-- Sentinel — statebag integrity guard
-- ============================================
--
-- FiveM lets a client write its own player bag and the bags of entities it owns, and
-- sv_stateBagStrictMode (which would forbid that globally) is off on purpose. whip is a
-- framework, and a server built on it must be free to run whatever needs client bag writes
-- — voice resources are the classic case — so whip has to be safe WITH strict mode off.
-- (With it on, this file has nothing to catch and costs nothing to keep.) So whip's
-- replicated state — the player keys in shared/statebags.lua and the vehicle keys — is
-- forgeable by exactly the person it describes (a spoofed damageModifier makes every attacker's
-- client pull its punches).
--
-- The Sentinel is whip's answer: a server-side statebag change handler. One watcher per WATCHED KEY — the native
-- keyFilter means changes to unwatched keys (voice, other resources) never reach Lua at
-- all — and each watcher does one thing: compare the bag against what the server believes,
-- and when they disagree, put the truth back and write the incident down.
--
-- Why truth-compare and not origin-detection: the handler's `replicated` argument does not
-- reliably say which side wrote the value, so the design never asks. Instead: the server's
-- own writes always equal the ledger (they go ledger-first through setPlayerKey below), so
-- an echo compares equal and costs one comparison. A value that does NOT equal the ledger
-- has exactly one possible author — a client — because no legitimate code path writes these
-- keys client-side. That makes every detection a tamper, not a heuristic — ON ONE CONDITION:
-- every SERVER write to a watched key goes through the ledger (setPlayerKey, or the entity
-- family's truth function). A whip code path that sets a watched key directly with
-- `state:set` does not update the ledger, so its own write reads as a client's, is reverted,
-- and is logged against an innocent player. If the incident log ever names someone for a key
-- whip just changed, look for that direct write before looking at the player.
--
-- COST: zero in steady state. Handlers are event-driven; whip's player keys change a
-- handful of times per player per session. The one exception is the whipLive echo (the key
-- whip itself writes several times a second per driven live-stat car) — its handler is
-- profiler-scoped in vehicle_stats.lua, measured before ever being "optimized".
--
-- The re-stamp itself re-fires the handler once; the re-fire compares equal and stops.
-- A cheater who re-writes in a loop is fighting cfx's own client bag-write rate limiters
-- long before they inconvenience us. From FiveM's StateBagPacketHandler.cpp: past 75 writes
-- a second (burst 125) their writes are DROPPED (`sbag-update-dropped` in the console); past
-- 150 a second (burst 175), or 128 KB a second (burst 256 KB), they are KICKED with
-- "Reliable state bag packet overflow." (This said 75/125 was the kick. It is the drop.)

Sentinel = Sentinel or {}

-- ---- state ----

-- [key] = { key, family='player'|'entity', truth=fn|nil, owner, cookie, detections, lastAt }
-- The registry is keyed by BAG KEY, which is therefore global across families — fine,
-- because a player key appearing on an entity bag (or vice versa) is itself nonsense the
-- handlers ignore via their id resolution.
Sentinel._registry = {}

-- [src][key] = the last value the server wrote. THE truth for the player family — a ledger,
-- not a recompute, because at least one write site (jobs.lua clock-off picking the "next"
-- job by pairs() order) is legitimately non-deterministic: recomputing could disagree with
-- what was actually written and flag whip's own write as a tamper.
Sentinel._ledger = {}

local _strikes  = {}   -- [src] = count (reset when they wear off — strikesForgetMinutes)
local _strikeAt = {}   -- [src] = GetGameTimer() of their last strike
local _debounce = {}   -- [src .. '|' .. key] = GetGameTimer() of last LOGGED detection

-- > 0 while whip ITSELF is writing an entity key (Sentinel.setEntityKey). Change handlers run inside
-- the server's own SetKey, so a mismatch seen while this is up was written by whip, not a client.
local _serverWriting = 0

-- Detection ring buffer for the /w panel. Separate from secure.lua's shared event log so
-- a chatty server can't churn tamper history out of the 500-slot shared ring.
local DET_LOG_MAX = 200
local _detLog, _detHead, _detCount = {}, 0, 0

-- ---- pure helpers ----

--- Deep structural equality. Scalars take the fast path; tables recurse both ways (a key
--- present in one and absent in the other is a difference). Runs only on echo/tamper
--- events — never on a timer, never per frame. Bag values are plain data, so this does not
--- need the rawget care shared/registry.lua's copy takes with a satellite's functions.
local function deepEquals(a, b)
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    for k, v in pairs(a) do
        if not deepEquals(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end
-- (Registrations that change nothing are spotted by shared/registry.lua now, with its own copy.)
Sentinel.deepEquals = deepEquals

--- A value rendered small enough to log. json handles tables; tostring covers the rest.
local function shortVal(v)
    if v == nil then return 'nil' end
    local ok, s = pcall(json.encode, v)
    if not ok or type(s) ~= 'string' then s = tostring(v) end
    if #s > 120 then s = s:sub(1, 117) .. '...' end
    return s
end

-- ---- detection core ----

--- A watched key diverged from truth. The correction is already QUEUED by the time this runs
--- (correctNextTick) — this function only handles the bookkeeping (log, strike, kick), which is
--- what the debounce below gates. Correction is never debounced; noise is.
---@param key string
---@param family string
---@param src number|nil   attributed player (entity family: the entity's current owner)
---@param got any          what the bag said
---@param expected any     what the ledger/truth said
local function record(key, family, src, got, expected)
    local reg = Sentinel._registry[key]
    if reg then
        reg.detections = reg.detections + 1
        reg.lastAt = os.time()
    end

    local now = GetGameTimer()
    local dKey = tostring(src or 0) .. '|' .. key
    local cfg = Config.Sentinel or {}
    if _debounce[dKey] and (now - _debounce[dKey]) < (cfg.logDebounceMs or 1000) then
        return
    end
    _debounce[dKey] = now

    local playerName = 'Unknown'
    if src and Players[src] then
        playerName = Players[src].fullName or Players[src].firstName or 'Unknown'
    end

    local strikes = 0
    if src then
        -- Strikes wear off: three stray detections hours apart must not add up to a kick. After
        -- strikesForgetMinutes with no new one, the count starts again.
        local forgetMin = tonumber(cfg.strikesForgetMinutes)
        if forgetMin and forgetMin > 0 and _strikeAt[src] and (now - _strikeAt[src]) > forgetMin * 60000 then
            _strikes[src] = 0
        end
        _strikes[src] = (_strikes[src] or 0) + 1
        _strikeAt[src] = now
        strikes = _strikes[src]
    end

    local reason = ('client wrote %s (server: %s)'):format(shortVal(got), shortVal(expected))

    -- Into the shared secure-event feed, so the Event Monitor shows tampers alongside every
    -- other refusal. Rejections are always recorded there, viewers or not; the client feed
    -- synthesizes a registry row for the unknown 'sentinel:*' name. The coroutine-marking
    -- half of RecordEventRejection is a harmless no-op outside a SecureEvent handler.
    RecordEventRejection('sentinel:' .. key, src or 0, reason)

    -- Own ring, for the Event Monitor's Sentinel tab.
    local entry = {
        t = os.time(), key = key, family = family,
        src = src, name = playerName,
        got = shortVal(got), expected = shortVal(expected),
        strikes = strikes,
    }
    _detLog[_detHead] = entry
    _detHead = (_detHead + 1) % DET_LOG_MAX
    if _detCount < DET_LOG_MAX then _detCount = _detCount + 1 end

    DevTools.eachViewer(DevTools.viewers.sn, function(viewer)   -- still allowed
        TriggerClientEvent('whip_core:client:snNewDetection', viewer, entry)
    end)

    print(('[whip_core:sentinel] TAMPER %s (%s) by %s [%s]: %s — reverted, strike %d')
        :format(key, family, playerName, tostring(src), reason, strikes))

    -- The kick, when configured. The note is written BEFORE the drop (the target must
    -- still be in Players for the userId), pcall'd so a DB hiccup cannot block the
    -- enforcement — the pmKick idiom, with the Sentinel as the acting "admin".
    local threshold = cfg.autoKick
    if src and threshold and strikes >= threshold then
        local target = Players[src]
        if target then
            local noted, noteErr = pcall(MySQL.insert.await,
                'INSERT INTO `admin_notes` (`userId`, `note`, `createdBy`, `createdByName`) VALUES (?, ?, ?, ?)',
                { target.userId,
                  ('SENTINEL KICK: %d statebag tampers this session (last: %s — %s)'):format(strikes, key, reason),
                  0, 'Sentinel' })
            if not noted then
                print(('[whip_core:sentinel] the kick note for %s did not save: %s'):format(playerName, tostring(noteErr)))
            end
        end
        DropPlayer(src, ('Kicked: statebag tampering detected (%s)'):format(key))
    end
end

--- Put the truth back on the NEXT server tick, not from inside the change handler.
---
--- FiveM runs change handlers BEFORE it stores the incoming value (StateBagComponent.cpp:
--- SetKey calls OnStateBagChange, then the continuation that stores the data), and its docs say
--- "the old value is still stored in the state bag at the time this callback executes". A set
--- made inside the handler therefore compared against the old value, changed nothing, and was
--- then overwritten by the client's value a moment later. Detection worked; the correction
--- never stuck. Deferred, the forged value is already stored when we look, and the set replaces
--- it and replicates to everyone.
---
--- Truth and bag are both re-read at that point: a legitimate server write can land in between,
--- and then there is nothing left to correct.
---@param readBag function   () -> the value currently on the bag
---@param readTruth function () -> ok, truth
---@param writeBag function  (truth) -> nil
local function correctNextTick(readBag, readTruth, writeBag)
    SetTimeout(0, function()
        pcall(function()
            local ok, truth = readTruth()
            if not ok then return end
            if deepEquals(readBag(), truth) then return end
            writeBag(truth)
        end)
    end)
end

local function setKeyNow(entity, key, value)
    Entity(entity).state:set(key, value, true)
end

--- How whip_core writes a WATCHED ENTITY KEY (the vehicle keys) — never a bare `state:set`.
--- The same write, with a flag up while it happens: the change handler runs inside it, so a
--- mismatch it sees then is whip's own writer and truth disagreeing (a whip bug to report), not a
--- client to strike.
---@param entity number
---@param key string
---@param value any
function Sentinel.setEntityKey(entity, key, value)
    _serverWriting = _serverWriting + 1
    local ok, err = pcall(setKeyNow, entity, key, value)
    _serverWriting = _serverWriting - 1
    if not ok then error(err, 2) end
end

--- Handler factory, player family. Truth is the ledger.
local function makePlayerHandler(key)
    return function(bagName, _, value)
        local src = GetPlayerFromStateBagName(bagName)
        if not src or src == 0 then return end   -- not a player bag; not our family

        -- NOT `ledger and ledger[key] or nil`: `false` is a legitimate ledger value
        -- (activeJob, isEscorted) and the or-chain would collapse it to nil — making
        -- whip's own login writes flag themselves as tampers.
        local truth = Sentinel.getTruth(src, key)
        if deepEquals(value, truth) then return end   -- echo, or a spoof-to-truth no-op

        -- Correction on the next tick (see correctNextTick), book-keeping now. The pcall inside
        -- covers a player who drops before that tick, leaving a dead bag behind the name.
        correctNextTick(
            function() return Player(src).state[key] end,
            function() return true, Sentinel.getTruth(src, key) end,
            function(t) Player(src).state[key] = t end)

        record(key, 'player', src, value, truth)
    end
end

--- Handler factory, entity family. Truth comes from the registered truth fn — required,
--- because entity truth lives in the owning module's private state (vehicle records, the
--- stat store), not in a ledger here. A truth fn returning nil for an entity means "this
--- entity should not carry the key at all" — which makes a watched key appearing on an
--- untracked entity exactly the tamper it looks like: the key gets stripped.
local function makeEntityHandler(key)
    return function(bagName, _, value)

        local entity = GetEntityFromStateBagName(bagName)
        if not entity or entity == 0 or not DoesEntityExist(entity) then return end

        local reg = Sentinel._registry[key]
        if not reg or not reg.truth then return end

        local ok, truth = pcall(reg.truth, entity)
        if not ok then
            print(('[whip_core:sentinel] truth fn for "%s" errored: %s'):format(key, tostring(truth)))
            return
        end
        if deepEquals(value, truth) then return end

        correctNextTick(
            function() return Entity(entity).state[key] end,
            function()
                if not DoesEntityExist(entity) then return false end
                return pcall(reg.truth, entity)
            end,
            function(t) Sentinel.setEntityKey(entity, key, t) end)

        -- Whip wrote it: a mismatch under Sentinel.setEntityKey is whip's truth function disagreeing
        -- with whip's own writer, a whip bug, not the driver's doing. Corrected and reported for the
        -- developer; nobody is struck.
        if _serverWriting > 0 then
            -- The writer is whip or, through SentinelSetEntityKey, the satellite that owns the key.
            print(('[whip_core:sentinel] %s wrote %s = %s but its truth says %s — corrected, nobody struck%s')
                :format(reg.owner == 'whip_core' and 'WHIP BUG: whip' or tostring(reg.owner), key,
                    shortVal(value), shortVal(truth),
                    reg.owner == 'whip_core' and '' or ' (change your truth first, then write)'))
            return
        end

        -- Attribution: only the current owner CAN have written an entity bag, so the owner
        -- at handler time is the suspect. Ownership can migrate between the write and this
        -- handler — rare, and why entity strikes feed the same ladder but the log says
        -- which entity, not just who.
        local src = NetworkGetEntityOwner(entity) ---@type integer|nil
        if src and src <= 0 then src = nil end
        record(key, 'entity', src, value, truth)
    end
end

-- ---- registration ----

--- The watched keys, on the one registration rule (shared/registry.lua). Satellites register from
--- whip_core:onReady, which re-fires: the same owner re-registering is a no-op when nothing changed
--- and a replace when it did; only ANOTHER resource is refused.
---
--- The stopped-resource sweep is the registry's too: a watcher whose truth fn lives in a dead Lua
--- state would error on every change of that key forever, so its handler comes off (onRemove).
Sentinel._keys = Registry.new('SentinelKey', {
    label = 'Sentinel key',
    store = Sentinel._registry,
    -- Nothing changed if it watches the same family with the same truth. A satellite's truth fn
    -- arrives as a new reference every time, so its re-registration replaces — which costs one
    -- handler swap and keeps the detection counters (onAdd).
    same  = function(old, new) return old.family == new.family and old.truth == new.truth end,
    onAdd = function(key, reg, _, old)
        if old then
            if old.cookie then RemoveStateBagChangeHandler(old.cookie) end
            reg.detections, reg.lastAt = old.detections, old.lastAt
        end
        if Config.Sentinel and Config.Sentinel.enabled then
            local handler = (reg.family == 'player') and makePlayerHandler(key) or makeEntityHandler(key)
            reg.cookie = AddStateBagChangeHandler(key, nil, handler)
        end
    end,
    onRemove = function(_, reg)
        if reg.cookie then RemoveStateBagChangeHandler(reg.cookie) end
    end,
})

-- TURNED ON OR OFF in /whip → Settings: every watched key's handler taken off, and put back when
-- on, as registration does (onAdd above). The keys and their counts stay registered either way.
Settings.onChange('Sentinel.enabled', function(on)
    for key, reg in pairs(Sentinel._registry) do
        if reg.cookie then
            RemoveStateBagChangeHandler(reg.cookie)
            reg.cookie = nil
        end
        if on then
            local handler = (reg.family == 'player') and makePlayerHandler(key) or makeEntityHandler(key)
            reg.cookie = AddStateBagChangeHandler(key, nil, handler)
        end
    end
    -- Back on: a value written while it was off fires no handler until it changes again, so every
    -- watched value is put back to the truth now, as at start (corrections, no strikes).
    if on then Sentinel.sweep(true) end
end)

--- Watch a statebag key. Internal; satellites come in through the export below.
--- `enabled = false` makes this registry-only — no handler is created, zero runtime cost,
--- which is the whole "disabled" story: there is nothing else to turn off.
---@param def table { key, family = 'player'|'entity', truth = fn|nil, owner = string }
---@return boolean ok
---@return string|nil err
function Sentinel.watch(def)
    if type(def) ~= 'table' then return false, 'def (table) is required' end
    if type(def.key) ~= 'string' or def.key == '' then return false, 'def.key (string) is required' end
    if def.family ~= 'player' and def.family ~= 'entity' then
        return false, "def.family must be 'player' or 'entity'"
    end
    if def.family == 'entity' and def.truth == nil then
        return false, 'entity-family keys require def.truth (the module that owns the state must say what it is)'
    end

    -- Copied, not kept — the caller holds no live reference into the registry. Same rule
    -- as Stats.register and the accessory-slot registry.
    local owner = def.owner or 'whip_core'
    local reg = {
        key        = def.key,
        family     = def.family,
        truth      = def.truth,
        owner      = owner,
        cookie     = nil,
        detections = 0,
        lastAt     = 0,
    }

    local ok, why = Sentinel._keys:add(owner, def.key, reg)
    if not ok then return false, why --[[@as string]] end
    return true
end

-- ---- the write-through API (player family) ----

--- THE sanctioned write path for player statebag keys. Ledger first, bag second — that
--- ordering is what makes the handler race-free: by the time any echo (or any tamper that
--- lands between our two lines) reaches the handler, the ledger already holds the value
--- the comparison should use. Unwatched keys are tolerated (both halves still written), so
--- a call site never breaks by being written before its watch is registered.
---@param src number
---@param key string
---@param value any
function Sentinel.setPlayerKey(src, key, value)
    local ledger = Sentinel._ledger[src]
    if not ledger then
        ledger = {}
        Sentinel._ledger[src] = ledger
    end
    ledger[key] = value
    Player(src).state[key] = value
end

--- What the server believes a player key holds: THE server-side read for player state. A bag read
--- answers "what does the (client-writable) bag say", this answers "what did the server write", and
--- server logic must only ever want the second.
---@param src number
---@param key string
---@return any
function Sentinel.getTruth(src, key)
    local ledger = Sentinel._ledger[src]
    if not ledger then return nil end
    return ledger[key]   -- NOT `ledger[key] or nil` — false is a real value here
end

-- ---- boot sweep ----

--- Statebags OUTLIVE the Lua state (reconcileWorld exists for exactly this reason). A
--- tamper written just before a whip_core restart would survive it: the ledger restarts
--- empty, and a key whose truth is nil-by-default (the modifiers) is never re-written by
--- any legit path — so nothing would ever correct it. One pass at start closes that.
---@param force boolean|nil  sweep even with bootSweep off (Sentinel turned back on in /whip → Settings)
function Sentinel.sweep(force)
    if not (Config.Sentinel and Config.Sentinel.enabled and (force or Config.Sentinel.bootSweep)) then return end

    -- Corrections only, NO record(): at boot a divergence is usually a STALE bag, not a
    -- forged one — a connected player's bag legitimately holds last session's values while
    -- the fresh ledger holds nothing. Stripping them is right; striking someone for a
    -- restart would be a false accusation the design promises never to make. Live tampers
    -- after this moment hit the handlers, which do record.
    local swept = 0
    for _, srcStr in ipairs(GetPlayers()) do
        local src = tonumber(srcStr)
        if src then
            for key, reg in pairs(Sentinel._registry) do
                if reg.family == 'player' then
                    local bagValue = Player(src).state[key]
                    local truth = Sentinel.getTruth(src, key)
                    if not deepEquals(bagValue, truth) then
                        pcall(function() Player(src).state[key] = truth end)
                        swept = swept + 1
                    end
                end
            end
        end
    end

    -- The vehicle half: the walk is over whatever is watched, so it is a no-op until something
    -- registers entity truths.
    if Vehicles and Vehicles.spawnedEntities then
        for _, entity in ipairs(Vehicles.spawnedEntities()) do
            if DoesEntityExist(entity) then
                for key, reg in pairs(Sentinel._registry) do
                    if reg.family == 'entity' and reg.truth then
                        local ok, truth = pcall(reg.truth, entity)
                        if ok then
                            local bagValue = Entity(entity).state[key]
                            if not deepEquals(bagValue, truth) then
                                Sentinel.setEntityKey(entity, key, truth)
                                swept = swept + 1
                            end
                        end
                    end
                end
            end
        end
    end

    if swept > 0 then
        print(('[whip_core:sentinel] boot sweep corrected %d stale/tampered bag value(s)'):format(swept))
    end
end

AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    -- Not necessarily after the vehicle restore: start-up waits up to 3 s for the database to settle before Vehicles.loadAll and
    -- reconcileWorld, so on a restart this sweep can run while the vehicle index is still empty.
    -- That costs nothing today: whip_core's stop strips its keys from every car it tracked and
    -- deletes or hands back the car, so no whip-stamped entity is left for the vehicle half to judge.
    -- The player half is what this sweep is for.
    SetTimeout(2000, Sentinel.sweep)
end)

-- ---- whip's own player keys (file scope — this file loads before any satellite) ----

for _, key in ipairs({
    PLAYER_DEAD_KEY, PLAYER_JOB_KEY,
    PLAYER_ESCORTED_KEY, PLAYER_ESCORTER_KEY, PLAYER_DMGMOD_KEY, PLAYER_MELEEMOD_KEY,
    PLAYER_MOOD_KEY,
}) do
    Sentinel.watch({ key = key, family = 'player', owner = 'whip_core' })
end

-- ---- satellite surface ----

--- Watch a key a satellite writes. Same contract as every registration export: call from
--- a whip_core:onReady handler (this registry's state dies with core and onReady re-fires
--- exactly then). Registering again from the same resource is safe — the same thing again does
--- nothing — and another resource's key is refused with (false, reason). Stopping your resource
--- unwinds your watches automatically.
---@param def table { key, family = 'player'|'entity', truth = fn|nil (required for entity) }
exports('RegisterSentinelKey', function(def)
    local owner = Registry.caller()   -- first, before anything can yield
    if type(def) ~= 'table' then return false, 'def (table) is required' end
    def.owner = owner
    return Sentinel.watch(def)
end)

--- The sanctioned write path, for satellites that put their own keys on player bags.
---
--- Your own keys only: the ledger is what whip's gates read back as the truth ("is this player
--- dead?"). A WATCHED key belongs to whoever registered it with RegisterSentinelKey and only they may
--- write it here; whip_core's own are refused to everyone else. A key nobody watches is anyone's to
--- write.
---
--- Answers `true`, or `false, reason`. The player must be connected: a ledger written for a
--- source nobody holds would never be cleared (clearSource runs on a drop that never comes).
---@param src number
---@param key string
---@param value any
---@return boolean ok
---@return string|nil err
exports('SentinelSetPlayerKey', function(src, key, value)
    local caller = Registry.caller()   -- first, before anything can yield
    if type(key) ~= 'string' or key == '' then return false, 'key (string) is required' end
    if type(src) ~= 'number' or not GetPlayerName(src) then return false, 'no such player' end

    local reg = Sentinel._registry[key]
    if reg and reg.owner ~= caller then
        return false, ('key "%s" is owned by %s'):format(key, tostring(reg.owner))
    end

    Sentinel.setPlayerKey(src, key, value)
    return true
end)

--- The write path for a satellite's own ENTITY keys.
---
--- Writes with the flag whip_core's own vehicle writes carry (Sentinel.setEntityKey), so a mismatch
--- during it is reported as a bug and nobody (the car's driver) is struck; a bare `Entity(e).state:set`
--- has no flag. Change your truth first, then write: the watcher compares the bag with your truth at
--- the moment of the write either way.
---
--- Your own keys only: a key another resource watches is refused, and so are whip's. A key nobody
--- watches is anyone's to write. Answers `true`, or `false, reason`.
---@param entity number|string|nil
---@param key string
---@param value any
---@return boolean ok
---@return string|nil err
exports('SentinelSetEntityKey', function(entity, key, value)
    local caller = Registry.caller()   -- first, before anything can yield
    if type(key) ~= 'string' or key == '' then return false, 'key (string) is required' end
    entity = tonumber(entity)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return false, 'no such entity' end

    local reg = Sentinel._registry[key]
    if reg and reg.owner ~= caller then
        return false, ('key "%s" is owned by %s'):format(key, tostring(reg.owner))
    end
    if reg and reg.family ~= 'entity' then
        return false, ('key "%s" is watched as a player key'):format(key)
    end

    local ok, err = pcall(Sentinel.setEntityKey, entity, key, value)
    if not ok then return false, tostring(err) end
    return true
end)

--- The server-truth read, for satellites (and for whip's own gates — see events_misc).
exports('SentinelGetTruth', function(src, key)
    return Sentinel.getTruth(src, key)
end)

-- A stopping resource's watches are swept by the registry (Sentinel._keys above).

--- Per-source sweep. Called EXPLICITLY from player_lifecycle's playerDropped handler
--- (at its end), not from an own playerDropped registration: this file loads first, so an
--- own handler would run first and wipe the ledger before lifecycle's escort unwind reads
--- it via getTruth. An explicit call makes the ordering a fact instead of a hope.
function Sentinel.clearSource(src)
    Sentinel._ledger[src] = nil
    _strikes[src] = nil
    _strikeAt[src] = nil
    local prefix = tostring(src) .. '|'
    for dKey in pairs(_debounce) do
        if dKey:sub(1, #prefix) == prefix then
            _debounce[dKey] = nil
        end
    end
end

-- ============================================
-- Sentinel Panel — Server Events
-- ============================================
--
-- Raw RegisterNetEvent for the same reason the Event Monitor's trio is (in secure.lua):
-- routing a monitor's own traffic through SecureEvent would make it its own busiest
-- subject. ACE-gated inline; viewers live in DevTools.viewers.sn so the shared playerDropped
-- sweep in player_lifecycle cleans them with every other tool's.

local function snBuildRegistrySummary()
    local summary = {}
    for key, reg in pairs(Sentinel._registry) do
        summary[#summary + 1] = {
            key        = key,
            family     = reg.family,
            owner      = reg.owner,
            detections = reg.detections,
            lastAt     = reg.lastAt,
            armed      = reg.cookie ~= nil,
        }
    end
    return summary
end

local function snBuildLogArray()
    local arr = {}
    if _detCount == 0 then return arr end
    local start = (_detHead - _detCount) % DET_LOG_MAX
    for i = 0, _detCount - 1 do
        arr[#arr + 1] = _detLog[(start + i) % DET_LOG_MAX]
    end
    return arr
end

local function snBuildStrikes()
    local arr = {}
    for src, count in pairs(_strikes) do
        local p = Players[src]
        arr[#arr + 1] = { src = src, name = p and p.fullName or 'Unknown', strikes = count }
    end
    return arr
end

-- The Sentinel viewer's three events are plain net events gated by hand (DevTools.isAllowed), as the Monitor's are:
-- why, above the Monitor's in server/secure.lua.
RegisterNetEvent('whip_core:server:snGetAll', function()
    local source = source
    if not DevTools.isAllowed(source) then return end
    DevTools.viewers.sn[source] = true
    TriggerClientEvent('whip_core:client:snAllData', source, {
        registry = snBuildRegistrySummary(),
        log      = snBuildLogArray(),
        strikes  = snBuildStrikes(),
        enabled  = Config.Sentinel and Config.Sentinel.enabled or false,
        autoKick = Config.Sentinel and Config.Sentinel.autoKick or false,
    })
end)

-- Not gated: leaving is never refused. Removing yourself from a set you are not in does nothing.
RegisterNetEvent('whip_core:server:snClosed', function()
    DevTools.viewers.sn[source] = nil
end)

--- Clear the detection feed only. A light broadcast, not a fresh snAllData — a full
--- snapshot would re-run the client's open path and reset its view state (the same
--- stealth-reset hazard the Event Monitor's Clear had). Registry detection counters and
--- strikes deliberately survive: Clear empties scrollback, not the arithmetic.
RegisterNetEvent('whip_core:server:snClearLog', function()
    if not DevTools.isAllowed(source) then return end
    _detLog, _detHead, _detCount = {}, 0, 0
    DevTools.eachViewer(DevTools.viewers.sn, function(viewer)
        TriggerClientEvent('whip_core:client:snCleared', viewer)
    end)
end)
