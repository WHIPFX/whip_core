-- ============================================
-- WHIP COST — what each part of whip really costs where it runs (/whipcost)
-- ============================================
--
-- A profiler capture says WHERE the time goes, but overstates the cost (recording adds bookkeeping). This times
-- sections directly, for any loop in whip_core and its satellites:
--
--     local cost = WhipCost.start()
--     ... the work: NEVER a Wait() inside it, or the wait is what gets timed ...
--     WhipCost.stop('vehicle dial: read + send', cost)
--
-- OFF (always, unless /whipcost is running), start() answers nil and stop() returns at once: a section costs two
-- calls and a check. /whipcost (whip_core, tools/whipcost.lua) turns it on in every resource that loads this file
-- for a while, then prints one table: each section's runs a second, microseconds a run, and microseconds a frame —
-- its real share of the game's time.
--
-- THE CLOCK is GetNetworkTimeAccurate: the client's Lua has no os library, and GetGameTimer is read once a frame.
-- It moves in whole milliseconds, so one run reads 0 or 1; the SUM over hundreds of runs is the cost, because each
-- run starts anywhere inside a millisecond. A section that runs rarely is only roughly priced: the table says how
-- many runs it had.
--
-- MEMORY, TOO: how much each section makes a second (what Lua's collector has to clear after it: every table, string
-- and closure it builds), and how much this whole resource makes, timed or not. While /whipcost runs the collector is
-- paused here, so the count only goes up and a section's share is exact (lib/satellite.lua does the same for a
-- satellite that times nothing, for its whole-resource figure). Should the count come down anyway (something stepped
-- the collector), the figures are at least that much, and the table says so. Past MEMORY_CAP_KB it is let run again
-- and memory is no longer counted.
--
-- The other half is client/profiling.lua: each event handler named after its event in a FiveM profiler capture.
--
-- BOTH SIDES. Loaded by whip_core and by a satellite with
--     client_script '@whip_core/lib/cost.lua'      (the player's game: /whipcost in F8)
--     server_script '@whip_core/lib/cost.lua'      (the server: whipcost in the server console)
-- ON THE SERVER it times only (no memory: pausing a live server's collector is not worth the figure), with os.clock,
-- the server's CPU clock in fractions of a millisecond. The server has no frame count to tell a section that waited,
-- so the rule matters more there: never a Wait() between start and stop.

WhipCost = WhipCost or {}

--- True while /whipcost runs. A hot loop that times several sections may read it to take its timed path only then
--- (client/controls.lua).
WhipCost.on = false

local RESOURCE = GetCurrentResourceName()

if IsDuplicityVersion() then
    local sMs, sRuns = {}, {}

    --- The start of a section: a reading to hand to stop(), or nil while nothing is timing.
    ---@return number|nil
    function WhipCost.start()
        if WhipCost.on then return os.clock() end
        return nil
    end

    --- The end of a section begun with start(). `name` is its line in the table.
    ---@param name string
    ---@param started number|nil
    function WhipCost.stop(name, started)
        if started == nil then return end
        local dt = (os.clock() - started) * 1000
        if dt < 0 then return end
        sMs[name] = (sMs[name] or 0) + dt
        sRuns[name] = (sRuns[name] or 0) + 1
    end

    AddEventHandler('whip_core:cost:serverStarted', function()
        sMs, sRuns = {}, {}
        WhipCost.on = true
    end)
    AddEventHandler('whip_core:cost:serverStopped', function()
        if not WhipCost.on then return end
        WhipCost.on = false
        TriggerEvent('whip_core:cost:serverReported', { resource = RESOURCE, ms = sMs, runs = sRuns })
    end)
    return
end
-- The collector paused, this much more memory and it is let run again. 32 MB: a busy resource's run reads true well
-- before it, and ten satellites paused at once stay a few hundred MB on the player's PC, not gigabytes.
local MEMORY_CAP_KB = 32 * 1024
local WATCH_MS = 250               -- how often the paused collector is looked at
local SLOTS = 1024                 -- sections open at once (nested) can be at most this many

local ms, runs, waited = {}, {}, {}   -- [section] = milliseconds summed, runs counted, runs that waited (not counted)
local kb, kbRuns = {}, {}             -- [section] = KB made, summed over the runs that could be read; those runs

-- An open section's clock and memory, in one of SLOTS slots (filled before timing, so writing them makes nothing)
local slotAt, slotKb, slot = {}, {}, 0
local memory = nil   -- while timing: { from = KB at the start, at = when, last, gc = it came down anyway, capped }

-- ---- EVERY LOOP, timed or not ----
--
-- A loop's pass is what one coroutine runs between waking and its next Wait, and nothing else of this resource runs
-- meanwhile, so the memory that grew in between is that pass's. While /whipcost runs, this resource's global Wait (every
-- file calls it as a global) is one that measures that and files it under the loop: the function its thread was started
-- with, as file:line. Worked out once a coroutine (the first time it waits), so a pass's counting makes nothing.
-- lib/satellite.lua does the same for a satellite that does not load this file.
--
-- A THREAD STARTED WHILE IT TIMES (CreateThread, made the same way) has its first pass, from its start to its first
-- Wait, and its last, from its last Wait to its end, filed the same: a thread that runs once and never waits is a loop
-- of one pass a run. What the counting itself makes (naming a loop, its row) is a row of its own, so it is not taken
-- for this resource's.
local loops = nil                                     -- while timing: [file:line] = { n, kb }
---@type function|nil, function|nil
local nativeWait, nativeThread = nil, nil
local SELF_ROW = '(/whipcost itself: naming the loops)'
local wokeAt = setmetatable({}, { __mode = 'k' })     -- [coroutine] = KB when it last woke
local loopOf = setmetatable({}, { __mode = 'k' })     -- [coroutine] = its loop's name
local WRAPPERS = { 'error_tap.lua', 'lib/satellite.lua', 'lib/cost.lua', 'scheduler.lua' }

--- The function this coroutine was started with, as file:line: its deepest frame that is not a wrapper of whip's or
--- the runtime's (the error tap's guard sits under every thread). Called from countedWait, inside the coroutine.
local function loopName()
    local name, wrapped
    local level = 3   -- 1 this, 2 countedWait, 3 whoever called Wait
    while true do
        local info = debug.getinfo(level, 'S')
        if not info then break end
        if info.what ~= 'C' then
            local src, isWrapper = info.short_src, false
            for _, w in ipairs(WRAPPERS) do
                if src:find(w, 1, true) then isWrapper = true break end
            end
            if isWrapper then wrapped = wrapped or (src .. ':' .. info.linedefined)
            else name = src .. ':' .. info.linedefined end
        end
        level = level + 1
    end
    return name or wrapped or '?'
end

--- One pass of `name`'s loop: `made` KB (read before anything here made its own), then what filing it made, on the
--- counting's own row.
local function file(list, name, made, kbNow)
    local e = list[name]
    if not e then
        e = { n = 0, kb = 0.0 }
        list[name] = e
    end
    e.n = e.n + 1
    if made > 0 then e.kb = e.kb + made end
    local own = list[SELF_ROW]
    own.kb = own.kb + math.max(0, collectgarbage('count') - kbNow)
end

local function countedWait(waitMs)
    local co = coroutine.running()
    local list = loops
    if co and list then
        local kbNow = collectgarbage('count')   -- first: the naming below is the counting's, not the pass's
        local from = wokeAt[co]
        if from then
            local name = loopOf[co]
            if not name then
                name = loopName()
                loopOf[co] = name
            end
            file(list, name, kbNow - from, kbNow)
        end
    end
    ---@cast nativeWait -nil   -- this is Wait only while countLoops holds the real one there
    nativeWait(waitMs)
    if co and loops then wokeAt[co] = collectgarbage('count') end
end

--- A counted thread's end: its last pass filed, under the function it started with. Its answers passed straight through.
local function threadEnded(co, fn, ...)
    local list, from = loops, wokeAt[co]
    if list and from then
        local kbNow = collectgarbage('count')
        local name = loopOf[co]
        if not name then
            local info = debug.getinfo(fn, 'S')
            name = info.short_src .. ':' .. info.linedefined
        end
        file(list, name, kbNow - from, kbNow)
    end
    return ...
end

local function countedThread(fn)
    ---@cast nativeThread -nil   -- this is CreateThread only while countLoops holds the real one there
    if type(fn) ~= 'function' or not loops then return nativeThread(fn) end
    return nativeThread(function(...)
        local co = coroutine.running()
        if loops then wokeAt[co] = collectgarbage('count') end
        return threadEnded(co, fn, fn(...))
    end)
end

local function countLoops(on)
    if on and not nativeWait then
        nativeWait, nativeThread, loops = Wait, CreateThread, { [SELF_ROW] = { n = 0, kb = 0.0 } }
        Wait, CreateThread = countedWait, countedThread
    elseif not on and nativeWait then
        Wait, CreateThread = nativeWait, nativeThread
        nativeWait, nativeThread = nil, nil
    end
end

--- The start of a section: a reading to hand to stop(), or nil while nothing is timing.
---
--- THE READING CARRIES THE FRAME it was taken in, as a fraction (the frame count's last ten bits over 1024 — exact in a
--- Lua number), so stop() can tell a section that waited a frame or more in between: something it called yielded,
--- and its time is the wait's, not its own. Such a run is left out and counted apart. Its whole part is the slot its
--- clock and memory are kept in.
---@return number|nil
function WhipCost.start()
    if WhipCost.on then
        -- The frame read BEFORE the clock, so that native isn't part of the section's time
        local frame = (GetFrameCount() % 1024) / 1024
        slot = slot % SLOTS + 1
        slotKb[slot] = collectgarbage('count')
        slotAt[slot] = GetNetworkTimeAccurate()
        return slot + frame
    end
    return nil
end

--- The end of a section begun with start(). `name` is its line in the table ('area: what'). Building the name costs
--- something, so a name made with `..` is best made only when `started` is not nil.
---@param name string
---@param started number|nil
function WhipCost.stop(name, started)
    if started == nil then return end
    local now = GetNetworkTimeAccurate()
    local kbNow = collectgarbage('count')
    local s = math.floor(started)
    if (started - s) * 1024 ~= GetFrameCount() % 1024 then
        waited[name] = (waited[name] or 0) + 1
        return
    end
    local dt = now - slotAt[s]
    if dt < 0 or dt >= 1000 then return end   -- the network clock's sync jumped: not this section's time
    ms[name] = (ms[name] or 0) + dt
    runs[name] = (runs[name] or 0) + 1
    -- Memory only while the collector is paused: a count that came down is a collection, not this section
    local made = kbNow - slotKb[s]
    if memory and not memory.capped and made >= 0 then
        kb[name] = (kb[name] or 0) + made
        kbRuns[name] = (kbRuns[name] or 0) + 1
    end
end

-- /whipcost's start and stop. Stopping hands this resource's totals to whip_core, which prints them with everyone's.
AddEventHandler('whip_core:cost:started', function(info)
    ms, runs, waited, kb, kbRuns = {}, {}, {}, {}, {}
    for i = 1, SLOTS do slotAt[i], slotKb[i] = 0, 0 end
    collectgarbage('stop')
    local m = { from = collectgarbage('count'), at = GetGameTimer() }
    m.last = m.from
    -- No stop by then (whip_core went in the middle of it): the timing ends here, and the collector runs again
    m.giveUpAt = m.at + ((tonumber(type(info) == 'table' and info.seconds) or 120) + 10) * 1000
    memory = m
    WhipCost.on = true
    countLoops(true)
    -- The paused collector looked at while it lasts: a count that came down, the cap, a stop that never came
    CreateThread(function()
        while memory == m and not m.capped do
            Wait(WATCH_MS)
            if memory ~= m then break end
            if GetGameTimer() > m.giveUpAt then
                memory, WhipCost.on = nil, false
                countLoops(false)
                collectgarbage('restart')
                break
            end
            local now = collectgarbage('count')
            if now < m.last then m.gc = true end
            m.last = now
            if now - m.from > MEMORY_CAP_KB then
                m.capped, m.made, m.seconds = true, now - m.from, (GetGameTimer() - m.at) / 1000
                collectgarbage('restart')
            end
        end
    end)
end)

--- The end of the timing here: this resource's totals handed to whip_core. whip_core's own is ended by
--- tools/whipcost.lua before the stop goes out, so the satellites' reports it then takes in are not counted as its own.
function WhipCost.finish()
    if not WhipCost.on then return end
    WhipCost.on = false
    local m = memory
    memory = nil
    if m and not m.capped then
        m.made, m.seconds = collectgarbage('count') - m.from, (GetGameTimer() - m.at) / 1000
        collectgarbage('restart')
    end
    local counted = loops
    countLoops(false)
    loops = nil
    TriggerEvent('whip_core:cost:reported', {
        resource = RESOURCE, ms = ms, runs = runs, waited = waited, kb = kb, kbRuns = kbRuns, loops = counted,
        memory = m and { kb = m.made, seconds = m.seconds, gc = m.gc == true, capped = m.capped == true } or nil,
    })
end

AddEventHandler('whip_core:cost:stopped', function() WhipCost.finish() end)
