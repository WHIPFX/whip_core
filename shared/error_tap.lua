-- ============================================
-- ERROR TAP — shared/error_tap.lua (whip_core's second file, both sides)
-- ============================================
--
-- A script error in a player's game is printed to their F8 console, and nothing else can read that: not the server,
-- not a tool. So whip keeps its own errors as well, the last KEEP of them on each side, for tools to read
-- (export GetErrorLog: whip_devlink's whip_errors, and a test checking nothing broke):
--
--   whip_core's threads, timeouts and event handlers   caught as they fail, kept, and printed as before
--   its NUI callbacks, commands, statebag handlers     kept, then raised again: FiveM reports them as before
--   a handler whip_core runs for others                a SecureEvent / SecureCallback handler that throws (secure.lua),
--                                                      kept under its owner's name (ErrorTap.caught)
--   whip_core's own catches and warnings               a print in red (^1), and a '[whip_core...]' line that reports
--                                                      an error it caught (ERROR, threw, errored)
--   the page's errors (client)                         html/js/error-tap.js sends them
--   satellites                                         lib/satellite.lua catches theirs the same way and hands them
--                                                      here (whip_core:errorTap:report)
--
-- NOT KEPT: an export's error (caught inside the runtime and handed to its caller, as before: the caller's own catch
-- is what reports it), and a plain print a catch site words some other way.
--
-- HOW. FiveM's Lua runtime runs every event handler through Citizen.CreateThreadNow, and looks it up each time, so the
-- function wrapped here catches errors in all of them; threads and timeouts are wrapped as they are made. NUI callbacks,
-- commands and statebag handlers have a pcall of the runtime's own around them, so their handlers are wrapped as they
-- are registered.

ErrorTap = {}

local KEEP = 200           -- entries kept on each side
local TEXT_MAX = 2000
local SIDE = IsDuplicityVersion() and 'server' or 'client'
local SELF = GetCurrentResourceName()
local nativePrint = print
local traceback = debug.traceback

local log = {}             -- oldest first
local seq = 0

--- Keep one error. The same text again within the last few is counted, not kept twice (an error every frame).
---@param kind string        'error' | 'warning' | 'page'
---@param text string
---@param resource string|nil  whose (whip_core's own when nil)
function ErrorTap.keep(kind, text, resource)
    text = tostring(text or ''):sub(1, TEXT_MAX)
    resource = resource or SELF
    for i = #log, math.max(1, #log - 5), -1 do
        local e = log[i]
        if e.text == text and e.resource == resource then
            e.count = e.count + 1
            e.at = GetGameTimer()
            seq = seq + 1
            e.seq = seq
            return
        end
    end
    seq = seq + 1
    log[#log + 1] = { seq = seq, at = GetGameTimer(), side = SIDE, resource = resource, kind = kind, text = text, count = 1 }
    if #log > KEEP then table.remove(log, 1) end
end

local function runCaught(fn, ...)
    local r = table.pack(xpcall(fn, traceback, ...))
    if r[1] then return table.unpack(r, 2, r.n) end
    ErrorTap.keep('error', r[2])
    nativePrint(('^1SCRIPT ERROR: %s^7'):format(tostring(r[2])))
end

local function guard(fn)
    if type(fn) ~= 'function' then return fn end
    return function(...) return runCaught(fn, ...) end
end

--- guard() for a thread, named as the function it wraps. FiveM names a thread after the function it was started with
--- ('thread <file>[first..last]': the profiler, resmon), and with one catch round every thread, all of whip_core's
--- loops were one row named after this file (Josh, 11 Nov: "error_tap.lua is eating 50% of the CPU", which was every
--- loop together). So the catch is compiled once for each function a thread starts with, as a function of that file
--- over those lines. A function it cannot name this way gets the plain catch.
local catchFor = {}   -- [source] = { [first line] = function(fn) -> fn caught }

--- The catch for `fn`, named as `like` (fn's own place when like is nil).
local function caughtAs(fn, like)
    local info = debug.getinfo(like or fn, 'S')
    local first, last = info.linedefined, info.lastlinedefined
    if info.what ~= 'Lua' or first < 1 or last < first then return guard(fn) end
    local bySource = catchFor[info.source]
    if not bySource then
        bySource = {}
        catchFor[info.source] = bySource
    end
    local make = bySource[first]
    if make == nil then
        -- The inner function starts on line `first` and ends on line `last` of a chunk named as that file
        local code = 'local run = ... return function(fn) return ' .. string.rep('\n', first - 1)
            .. 'function(...) return run(fn, ...)' .. string.rep('\n', last - first) .. ' end end'
        local chunk = load(code, info.source, 't')
        make = chunk and chunk(runCaught) or false
        bySource[first] = make
    end
    if not make then return guard(fn) end
    return make(fn)
end

local function threadGuard(fn)
    if type(fn) ~= 'function' then return fn end
    return caughtAs(fn)
end

-- /whipcost's count of what whip_core is asked to run (tools/whipcost.lua). Every event handler and every export
-- call reaching whip_core comes through CreateThreadNow, named by the runtime ('event <name> [file[lines]]',
-- 'ref call [file[lines]]'), and every timeout through SetTimeout, named here ('timeout [file[lines]]'): while
-- /whipcost times, this is a function that wraps each one to count it. nil the rest of the time, so all it costs is
-- one look at a nil.
ErrorTap.counting = nil

local nativeThread, nativeNow, nativeTimeout = Citizen.CreateThread, Citizen.CreateThreadNow, Citizen.SetTimeout
---@diagnostic disable-next-line: duplicate-set-field -- wrapped on purpose (HOW, at the top of this file)
Citizen.CreateThread = function(fn) return nativeThread(threadGuard(fn)) end
---@diagnostic disable-next-line: duplicate-set-field -- wrapped on purpose (HOW, at the top of this file)
Citizen.CreateThreadNow = function(fn, name)
    local count = ErrorTap.counting
    if count ~= nil and type(fn) == 'function' then fn = count(fn, name) end
    -- Named by the runtime (an event handler, a call into whip_core): that name is what shows
    return nativeNow(name ~= nil and guard(fn) or threadGuard(fn), name)
end
---@diagnostic disable-next-line: duplicate-set-field -- wrapped on purpose (HOW, at the top of this file)
Citizen.SetTimeout = function(ms, fn)
    local count = ErrorTap.counting
    if count ~= nil and type(fn) == 'function' then
        local di = debug.getinfo(fn, 'S')
        return nativeTimeout(ms, guard(count(fn, ('timeout [%s[%d..%d]]'):format(di.short_src, di.linedefined,
            di.lastlinedefined))))
    end
    return nativeTimeout(ms, threadGuard(fn))
end
CreateThread, SetTimeout = Citizen.CreateThread, Citizen.SetTimeout

--- A thread running `fn`, named after `like` (a function's file and lines): for a loop that runs someone else's
--- function (Every, server/lifecycle.lua), so the profiler shows each job rather than the one loop that runs them all.
---@param like function
---@param fn function
function ErrorTap.threadLike(like, fn)
    if type(like) ~= 'function' or type(fn) ~= 'function' then return CreateThread(fn) end
    return nativeThread(caughtAs(fn, like))
end

--- A handler the runtime catches itself: kept, then raised again, so FiveM's own report and the caller see it as before.
--- `label` names it in /whipcost's count ('state bag whipLive', 'NUI pauseSwap', 'command whip'): the runtime calls each
--- through this one wrapper, so by where it lives they would all be one row (tools/whipcost.lua leaves that row out).
local function rethrow(fn, label)
    if type(fn) ~= 'function' then return fn end
    local function body(...)
        local r = table.pack(xpcall(fn, traceback, ...))
        if r[1] then return table.unpack(r, 2, r.n) end
        ErrorTap.keep('error', r[2])
        error(r[2], 0)
    end
    return function(...)
        local count = ErrorTap.counting
        if count ~= nil then return count(body, label)(...) end
        return body(...)
    end
end
local nativeCommand, nativeBagHandler = RegisterCommand, AddStateBagChangeHandler
RegisterCommand = function(name, fn, restricted)
    return nativeCommand(name, rethrow(fn, 'command ' .. tostring(name)), restricted)
end
AddStateBagChangeHandler = function(key, bag, fn)
    return nativeBagHandler(key, bag, rethrow(fn, 'state bag ' .. (key and tostring(key) or '(any key)')))
end
if SIDE == 'client' then
    local nativeNUI, nativeNui = RegisterNUICallback, RegisterNuiCallback
    RegisterNUICallback = function(name, fn) return nativeNUI(name, rethrow(fn, 'NUI ' .. tostring(name))) end
    if nativeNui then RegisterNuiCallback = function(name, fn) return nativeNui(name, rethrow(fn, 'NUI ' .. tostring(name))) end end
end

--- An error whip_core caught itself, in code it runs for `resource` (a SecureEvent handler's pcall): kept under that
--- name, and printed in red. `line`: what to print instead of `text`; false: kept only (a throttled repeat).
---@param text string
---@param resource string|nil
---@param line string|false|nil
function ErrorTap.caught(text, resource, line)
    ErrorTap.keep('error', text, resource)
    if line ~= false then nativePrint(('^1%s^7'):format(line or text)) end
end

--- One of whip_core's own lines that reports an error it caught: '[whip_core...] ... ERROR / threw / errored'.
local function caughtLine(s)
    if s:sub(1, 10) ~= '[whip_core' then return false end
    return s:find('ERROR', 1, true) ~= nil or s:find(' threw', 1, true) ~= nil or s:find(' errored', 1, true) ~= nil
end

-- whip's own warnings (red lines), and the errors its catch sites print.
function print(...)
    nativePrint(...)
    local first = ...
    if type(first) ~= 'string' then return end
    local red = first:sub(1, 2) == '^1'
    if red or caughtLine(first) then
        local parts = table.pack(...)
        for i = 1, parts.n do parts[i] = tostring(parts[i]) end
        ErrorTap.keep(red and 'warning' or 'error', (table.concat(parts, ' ', 1, parts.n):gsub('%^%d', '')))
    end
end

-- A satellite's (lib/satellite.lua): only from this side's own resources (a local event).
AddEventHandler('whip_core:errorTap:report', function(resource, kind, text)
    if type(resource) ~= 'string' or type(text) ~= 'string' then return end
    ErrorTap.keep((kind == 'warning' or kind == 'page') and kind or 'error', text, resource)
end)

if SIDE == 'client' then
    -- The page's (html/js/error-tap.js).
    RegisterNUICallback('errorTap', function(d, cb)
        cb({ ok = true })
        if type(d) == 'table' and type(d.text) == 'string' then ErrorTap.keep('page', d.text, SELF .. ' page') end
    end)
end

--- What went wrong lately on this side: whip_core's errors and red warnings, its satellites', and (client) its page's.
--- `since`: only those after that number (the `last` of an earlier answer).
---@param opts { since?: number, max?: number }|nil
---@return { entries: table[], last: number, side: string }
local function getErrorLog(opts)
    opts = type(opts) == 'table' and opts or {}
    local since = tonumber(opts.since) or 0
    local max = math.min(tonumber(opts.max) or KEEP, KEEP)
    local out = {}
    for _, e in ipairs(log) do
        if e.seq > since then out[#out + 1] = e end
    end
    table.sort(out, function(a, b) return a.seq < b.seq end)
    while #out > max do table.remove(out, 1) end
    return { entries = out, last = seq, side = SIDE }
end

ErrorTap.read = getErrorLog   -- whip_core's own readers (whiperrors, whipsupport) call this, not the export
exports('GetErrorLog', getErrorLog)
