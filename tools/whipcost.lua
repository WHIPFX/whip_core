-- ============================================
-- /whipcost [seconds] — what each part of whip really costs where it runs
-- ============================================
--
-- Every section timed with
-- WhipCost (lib/cost.lua) — whip_core's loops and the satellites' — is timed for a while (20 s unless asked; 5 to 120)
-- with no profiler recording, then printed as one table, the dearest first:
--
--     us a frame   its share of every frame: what it really costs the game (the column to read)
--     us a run     one run of it
--     a second     how often it runs
--     KB a second  the memory it makes a second: what Lua's collector has to clear after it
--
-- Then MEMORY BY RESOURCE: how much each whip resource makes a second in all, timed or not (every satellite that
-- loads lib/satellite.lua or lib/cost.lua says), the most first. Memory that climbs and drops back in resmon is
-- this: made, then cleared. The collector is paused in each of them while this runs (lib/cost.lua), and the
-- memory it would have cleared is cleared when it ends.
--
-- Then EVERY LOOP, timed or not, in every whip resource (lib/cost.lua, lib/satellite.lua): what one pass makes, by
-- the function its thread started with. And NOT COUNTED: each resource's total less its loops and (whip_core) what it
-- was asked to run, so what is still unexplained is a number, not a guess.
--
-- A section nested in another (the dial's send inside its read + send) is counted in both. One reading of the
-- clock is timed every frame here and taken off each run. A section with few runs is only roughly priced (a
-- millisecond clock, summed): marked "rough". Play as usual while it runs. A dev command (developer mode on), like
-- /mousedebug: it times this client's own code.

local DEFAULT_SECONDS, MIN_SECONDS, MAX_SECONDS = 20, 5, 120
local ROUGH_RUNS = 100
local CLOCK = '(reading the clock)'

local running = false
---@type table[]|nil
local reports = nil

-- ============================================
-- What whip_core is asked to run: every event handler and export call, by name
-- ============================================
--
-- Code no section times still runs somewhere: much of it is whip_core answering others. Every event handler and every
-- export call reaching whip_core passes through CreateThreadNow, where shared/error_tap.lua hands it to `count` while
-- this times. A call made each frame from another resource costs both sides every frame (the runtime makes a
-- coroutine and a few tables for each one before it starts, which its KB here leaves out), so how many a second is the
-- figure to read.
local asked = nil   -- while timing: [label] = { n, kb, ms }

--- 'event whip_core:client:x', 'export IsKeyPressed', or where a callback whip_core handed out lives.
---@return string|false
local function askedLabel(name)
    if type(name) ~= 'string' then return '(unnamed)' end
    local event = name:match('^event (%S+)')
    -- /whipcost's own events (the satellites' reports coming in) are its work, not whip_core's
    if event and event:find('whip_core:cost:', 1, true) == 1 then return false end
    if event then return 'event ' .. event end
    local timeout = name:match('^timeout %[(.+)%]$')
    if timeout then return 'timeout ' .. timeout end
    local at = name:match('^ref call %[(.+)%]$')
    if at then
        local export = WhipExportsAt and WhipExportsAt[at]
        if export then return 'export ' .. export end
        -- The error tap's wrapper round state bag handlers, NUI callbacks and commands: each counts itself, by name
        -- (shared/error_tap.lua rethrow), so not here as well
        if at:find('error_tap.lua', 1, true) then return false end
        return 'callback ' .. at
    end
    return name
end

local labelOf = {}   -- [the runtime's name] = label: worked out once a name

local function finish(e, kb0, t0, ...)
    local made = collectgarbage('count') - kb0
    if made > 0 then e.kb = e.kb + made end
    local dt = GetNetworkTimeAccurate() - t0
    if dt >= 0 and dt < 1000 then e.ms = e.ms + dt end
    e.n = e.n + 1
    return ...
end

local function count(fn, name)
    local list = asked
    if not list then return fn end
    -- whip_core's own CreateThreadNow calls pass no name
    local key = type(name) == 'string' and name or '(a thread whip_core started at once)'
    local label = labelOf[key]
    if label == nil then
        label = askedLabel(key)
        labelOf[key] = label
    end
    if label == false then return fn end   -- not counted here (askedLabel says why)
    local e = list[label]
    if not e then
        e = { n = 0, kb = 0.0, ms = 0.0 }
        list[label] = e
    end
    return function(...)
        local kb0, t0 = collectgarbage('count'), GetNetworkTimeAccurate()
        return finish(e, kb0, t0, fn(...))
    end
end

-- (Every loop of every whip resource is counted too, by lib/cost.lua and lib/satellite.lua: each report carries its
-- `loops`, [file:line] = { n, kb }, the memory each pass makes. Printed below, with what nothing counted.)

-- Each resource that loads lib/cost.lua or lib/satellite.lua answers whip_core:cost:stopped with its totals.
AddEventHandler('whip_core:cost:reported', function(r)
    if reports and type(r) == 'table' and type(r.resource) == 'string' and type(r.ms) == 'table'
        and type(r.runs) == 'table' then
        reports[#reports + 1] = r
    end
end)

-- What each satellite was asked to run (lib/satellite.lua: its event handlers and the calls into it), [resource] =
-- { [label] = { n, kb } }: in its report, or on its own from a satellite that also loads lib/cost.lua.
local satAsked = nil
AddEventHandler('whip_core:cost:askedReported', function(r)
    if satAsked and type(r) == 'table' and type(r.resource) == 'string' and type(r.asked) == 'table' then
        satAsked[r.resource] = r.asked
    end
end)

local function report(frames, seconds)
    ---@cast reports -nil   (run only while timing, before it is cleared)
    local p = function(...) print('[whip_core:cost] ' .. string.format(...)) end
    local base, kbBase = 0.0, 0.0
    for _, r in ipairs(reports) do
        if r.resource == 'whip_core' and (r.runs[CLOCK] or 0) > 0 then base = r.ms[CLOCK] * 1000 / r.runs[CLOCK] end
        local kr = r.resource == 'whip_core' and type(r.kbRuns) == 'table' and tonumber(r.kbRuns[CLOCK]) or 0
        if kr > 0 then kbBase = (tonumber(r.kb[CLOCK]) or 0) / kr end
    end

    local rows, quiet, byResource = {}, {}, {}
    for _, r in ipairs(reports) do
        local any = false
        local waited = type(r.waited) == 'table' and r.waited or {}
        local kb = type(r.kb) == 'table' and r.kb or {}
        local kbRuns = type(r.kbRuns) == 'table' and r.kbRuns or {}
        local names = {}
        for name in pairs(r.ms) do names[name] = true end
        for name in pairs(waited) do names[name] = true end
        for name in pairs(names) do
            local n = tonumber(r.runs[name]) or 0
            if name ~= CLOCK then
                any = true
                local perRun = n > 0 and math.max((r.ms[name] or 0) * 1000 / n - base, 0) or 0
                -- Memory from the runs that could be read, for every run
                local kr = tonumber(kbRuns[name]) or 0
                local kbSecond = kr > 0 and math.max((tonumber(kb[name]) or 0) / kr - kbBase, 0) * n / seconds or nil
                rows[#rows + 1] = {
                    label = r.resource == 'whip_core' and name or (r.resource .. ': ' .. name),
                    perRun = perRun, perFrame = perRun * n / frames, perSecond = n / seconds, runs = n,
                    waited = tonumber(waited[name]) or 0, kbSecond = kbSecond,
                }
            end
        end
        -- Only lib/cost.lua's reports carry sections (a satellite's lib/satellite.lua says its memory alone)
        if not any and type(r.kb) == 'table' then quiet[#quiet + 1] = r.resource end
        local m = type(r.memory) == 'table' and r.memory or nil
        if m and tonumber(m.kb) then
            local s = math.max(tonumber(m.seconds) or seconds, 0.001)
            byResource[#byResource + 1] = { resource = r.resource, kbSecond = math.max(m.kb, 0) / s, kb = m.kb,
                                            seconds = s, gc = m.gc == true, capped = m.capped == true }
        end
    end
    table.sort(rows, function(a, b) return a.perFrame > b.perFrame end)
    table.sort(byResource, function(a, b) return a.kbSecond > b.kbSecond end)

    p('%d frames in %.0f s (~%d fps); microseconds, %.2f for reading the clock taken off each run',
        frames, seconds, math.floor(frames / seconds + 0.5), base)
    p('%-56s %10s %10s %9s %11s', 'section', 'us a frame', 'us a run', 'a second', 'KB a second')
    for _, row in ipairs(rows) do
        local notes = {}
        if row.runs < ROUGH_RUNS then notes[#notes + 1] = ('rough: %d runs'):format(row.runs) end
        if row.waited > 0 then notes[#notes + 1] = ('%d runs waited a frame: left out'):format(row.waited) end
        p('%-56s %10.1f %10.1f %9.1f %11s%s', row.label, row.perFrame, row.perRun, row.perSecond,
            row.kbSecond and ('%.1f'):format(row.kbSecond) or '-',
            #notes > 0 and ('   ' .. table.concat(notes, '; ')) or '')
    end
    if #rows == 0 then p('nothing timed: no section ran') end
    if #quiet > 0 then p('loaded the timer, ran no section: %s', table.concat(quiet, ', ')) end

    -- What each resource makes in all: what climbs in resmon before the collector clears it
    p('')
    p('memory made, by resource (all of it, timed or not; what resmon shows climbing before it is cleared)')
    p('%-30s %11s %12s', 'resource', 'KB a second', 'MB in all')
    local sum = 0.0
    for _, m in ipairs(byResource) do
        sum = sum + m.kbSecond
        local notes = {}
        if m.gc then notes[#notes + 1] = 'at least: its collector ran anyway' end
        if m.capped then notes[#notes + 1] = ('counted for the first %.0f s only: past 32 MB'):format(m.seconds) end
        p('%-30s %11.1f %12.1f%s', m.resource, m.kbSecond, m.kb / 1024,
            #notes > 0 and ('   ' .. table.concat(notes, '; ')) or '')
    end
    if #byResource == 0 then
        p('no resource said')
    else
        p('%-30s %11.1f', 'all of whip', sum)
    end

    -- What whip_core was asked to run: the events and export calls it handled, the most often first
    local list = {}
    for label, e in pairs(asked or {}) do
        list[#list + 1] = { label = label, perSecond = e.n / seconds, kbSecond = e.kb / seconds,
                            perRun = e.n > 0 and e.ms * 1000 / e.n or 0 }
    end
    table.sort(list, function(a, b) return a.perSecond > b.perSecond end)
    p('')
    p('asked of whip_core on this game: every event, export call, state bag change, NUI callback and command it ran')
    p('(one a frame from another resource costs both sides every frame; the runtime\'s own unpacking of each is not in')
    p('the KB: it is in "not counted" below)')
    p('%-64s %9s %10s %11s', 'what', 'a second', 'us a run', 'KB a second')
    for i = 1, math.min(#list, 25) do
        local row = list[i]
        p('%-64s %9.1f %10.1f %11.1f', row.label:sub(1, 64), row.perSecond, row.perRun, row.kbSecond)
    end
    if #list == 0 then p('nothing') elseif #list > 25 then p('(and %d more, each less often)', #list - 25) end

    -- Every loop of every whip resource, the most memory first: what one pass makes, as the loop's own name (the function
    -- its thread was started with). A section timed above sits inside one of these, so it is counted in both.
    local loopRows, loopKb = {}, {}
    for _, r in ipairs(reports) do
        if type(r.loops) == 'table' then
            local loopSum = 0.0
            for key, e in pairs(r.loops) do
                local n, kbMade = tonumber(e.n) or 0, tonumber(e.kb) or 0
                loopSum = loopSum + kbMade
                loopRows[#loopRows + 1] = { key = (r.resource == 'whip_core' and '' or (r.resource .. ': ')) .. key,
                    perSecond = n / seconds, kbSecond = kbMade / seconds, bytesPass = n > 0 and kbMade * 1024 / n or 0 }
            end
            loopKb[r.resource] = loopSum / seconds
        end
    end
    table.sort(loopRows, function(a, b) return a.kbSecond > b.kbSecond end)
    p('')
    p('every loop, timed or not: the memory one pass makes (a loop is named by the function its thread started with;')
    p('a thread started while this timed counts its first and last pass too, so one that ran once is a row)')
    p('%-64s %9s %13s %11s', 'loop', 'a second', 'bytes a pass', 'KB a second')
    local shown = 0
    for _, row in ipairs(loopRows) do
        if shown >= 30 or row.kbSecond < 0.05 then break end
        shown = shown + 1
        p('%-64s %9.1f %13.0f %11.1f', row.key:sub(-64), row.perSecond, row.bytesPass, row.kbSecond)
    end
    if shown == 0 then p('no loop made any') elseif #loopRows > shown then
        p('(and %d more, each under 0.05 KB a second, or past the first 30)', #loopRows - shown)
    end

    -- What each satellite was asked to run: its event handlers and the calls into it (whip_core's rules and callbacks
    -- included), the most often first. How often is the figure to read: each call also costs the runtime's packing and
    -- unpacking, which is not in the KB (it is in "not counted").
    local satKb, satRows = {}, {}
    for _, r in ipairs(reports) do
        if type(r.asked) == 'table' and satAsked then satAsked[r.resource] = r.asked end
    end
    for resource, labels in pairs(satAsked or {}) do
        local satSum = 0.0
        for label, e in pairs(labels) do
            local n, kbMade = tonumber(e.n) or 0, tonumber(e.kb) or 0
            satSum = satSum + kbMade
            satRows[#satRows + 1] = { label = resource .. ': ' .. label, perSecond = n / seconds, kbSecond = kbMade / seconds,
                                      bytesRun = n > 0 and kbMade * 1024 / n or 0 }
        end
        satKb[resource] = satSum / seconds
    end
    table.sort(satRows, function(a, b) return a.perSecond > b.perSecond end)
    p('')
    p('asked of each satellite: its event handlers and the calls into it (whip_core\'s included), the most often first')
    p('%-64s %9s %13s %11s', 'what', 'a second', 'bytes a run', 'KB a second')
    for i = 1, math.min(#satRows, 25) do
        local row = satRows[i]
        p('%-64s %9.1f %13.0f %11.1f', row.label:sub(1, 64), row.perSecond, row.bytesRun, row.kbSecond)
    end
    if #satRows == 0 then p('nothing') elseif #satRows > 25 then p('(and %d more, each less often)', #satRows - 25) end

    -- What nothing above counted, by resource: its total, less its loops and what it was asked to run. The rest is the
    -- runtime's own work in that resource: unpacking an event's or a call's data before a handler runs, packing what it
    -- answers, and a thread started before the timing (or with Citizen.CreateThread) until it first waits.
    local askedKb = 0.0
    for _, e in pairs(asked or {}) do askedKb = askedKb + e.kb end
    p('')
    p('not counted anywhere above, by resource: its total less its loops and what it was asked')
    p('%-30s %11s %11s %11s %11s', 'resource', 'total', 'loops', 'asked', 'not counted')
    for _, m in ipairs(byResource) do
        local l = loopKb[m.resource] or 0
        local a = m.resource == 'whip_core' and askedKb / seconds or (satKb[m.resource] or 0)
        p('%-30s %11.1f %11.1f %11.1f %11.1f', m.resource, m.kbSecond, l, a, math.max(m.kbSecond - l - a, 0))
    end
end

DevCommand('whipcost', function(_, args)
    if running then
        print('[whip_core:cost] already timing')
        return
    end
    -- /whipcost [seconds]. (Every loop is counted now: a `loops` word, as it used to be typed, changes nothing.)
    local seconds = nil
    for _, a in ipairs(args or {}) do
        local n = tonumber(a)
        if n and not seconds then seconds = math.floor(n) end
    end
    seconds = math.max(MIN_SECONDS, math.min(MAX_SECONDS, seconds or DEFAULT_SECONDS))
    running, reports, satAsked = true, {}, {}
    CreateThread(function()
        print(('[whip_core:cost] timing whip for %d s: play as usual'):format(seconds))
        WhipEmit('whip_core:cost:started', { seconds = seconds })
        asked, ErrorTap.counting = {}, count
        local frame0, t0 = GetFrameCount(), GetGameTimer()
        while GetGameTimer() - t0 < seconds * 1000 do
            -- What a reading of the clock adds to every run, timed the same way, once a frame.
            WhipCost.stop(CLOCK, WhipCost.start())
            Wait(0)
        end
        local frames, took = GetFrameCount() - frame0, (GetGameTimer() - t0) / 1000
        ErrorTap.counting = nil
        -- whip_core's own totals first: the satellites' reports, taken in as the stop below goes out, are not its work
        WhipCost.finish()
        WhipEmit('whip_core:cost:stopped', {})   -- local events run their handlers before this returns
        local ok, err = pcall(report, math.max(frames, 1), math.max(took, 0.001))
        if not ok then print('[whip_core:cost] the report failed: ' .. tostring(err)) end
        running, reports, asked, satAsked = false, nil, nil, nil
    end)
end)

--- For tools (whip_devlink's whip_perf, a test): how smoothly this game runs over the next `seconds` (1 to 30, 5),
--- as numbers rather than /whipcost's printed table: frames a second on average and over the worst 1% of frames,
--- the median and the longest frame, and how many frames took over 33 ms and over 50 ms (a hitch a player feels).
--- Yields for that long.
---@param opts { seconds?: number }|nil
---@return { seconds: number, frames: number, fps: number, fpsWorst1: number, medianMs: number, worstMs: number, over33: number, over50: number }
exports('MeasureFrames', function(opts)
    local seconds = math.max(1, math.min(30, tonumber(type(opts) == 'table' and opts.seconds) or 5))
    local ms, untilAt = {}, GetGameTimer() + seconds * 1000
    while GetGameTimer() < untilAt do
        Wait(0)
        ms[#ms + 1] = GetFrameTime() * 1000
    end
    local n = #ms
    if n == 0 then return { seconds = seconds, frames = 0 } end
    local over33, over50 = 0, 0
    for _, v in ipairs(ms) do
        if v > 33 then over33 = over33 + 1 end
        if v > 50 then over50 = over50 + 1 end
    end
    table.sort(ms)
    local worst1 = ms[math.max(1, math.ceil(n * 0.99))]
    local r = function(v) return math.floor(v * 10 + 0.5) / 10 end
    return {
        seconds = seconds, frames = n, fps = r(n / seconds), fpsWorst1 = r(1000 / worst1),
        medianMs = r(ms[math.ceil(n / 2)]), worstMs = r(ms[n]), over33 = over33, over50 = over50,
    }
end)
