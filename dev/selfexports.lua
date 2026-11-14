--- selfexports — does whip_core call its OWN exports?
---
--- `exports.whip_core:X()` from inside whip_core is a full funcref round trip: the arguments and the
--- answer are msgpack'd both ways (tables copied, functions turned into callable tables, the answer cut
--- at the first nil), and the export runs on a FRESH coroutine (scheduler.lua's ref call routine,
--- CreateThreadNow). On the server that coroutine belongs to no player action — Actions.current()
--- answers {} for a call whose invoker is whip_core — so whatever the export saves is written apart
--- from the action that asked for it. whip_core calls the function: Stores.takeAt, Inventory.
--- registerUseHandler, Vehicles.resolve, Zones.setDebug ... (each export is a thin wrapper that reads
--- its caller first).
---
--- It reads every whip_core Lua file in server/, client/, shared/ and tools/ (git ls-files), with
--- comments and strings left out (a snippet in a string is not a call), and counts
--- `exports.whip_core`, `exports['whip_core']`, `exports[CORE]`, `exports[RESOURCE]` and
--- `exports[GetCurrentResourceName()]`. selfexports-baseline.txt lists files still allowed some, with
--- how many — the Director session's, until they move to the functions. The baseline only shrinks.
--- Not loaded by fxmanifest.lua.
---
--- Usage (from anywhere):
---   lua selfexports.lua            exit 1 when a file has more than its baseline allows
---   lua selfexports.lua report     every call, file:line
---   lua selfexports.lua baseline   write the baseline from the code as it is now (only to shrink it)

local here = debug.getinfo(1, 'S').source:sub(2):gsub('\\', '/'):match('^(.*)/[^/]*$') or '.'
local R = here .. '/../'
local mode = arg[1] or 'check'

--- The code of a file with comments and strings blanked, line breaks kept (so line numbers hold). A
--- string straight after `exports[` is kept: it is the resource being named.
local function codeOnly(src)
    local out, i, n = {}, 1, #src
    local recent = ''   -- the last few characters of code, to see `exports[` before a string
    local function keepNewlines(s) return (s:gsub('[^\n]', '')) end
    while i <= n do
        local c = src:sub(i, i)
        local long = src:match('^%[(=*)%[', i)
        if src:sub(i, i + 1) == '--' then
            local lvl = src:match('^%-%-%[(=*)%[', i)
            local j
            if lvl then
                local _, e = src:find(']' .. lvl .. ']', i, true)
                j = e or n
            else
                j = (src:find('\n', i, true) or (n + 1)) - 1
            end
            out[#out + 1] = keepNewlines(src:sub(i, j))
            i = j + 1
        elseif long then
            local _, e = src:find(']' .. long .. ']', i, true)
            e = e or n
            out[#out + 1] = keepNewlines(src:sub(i, e))
            i = e + 1
        elseif c == '"' or c == "'" then
            local j = i + 1
            while j <= n do
                local d = src:sub(j, j)
                if d == '\\' then j = j + 2
                elseif d == c or d == '\n' then break
                else j = j + 1 end
            end
            local body = src:sub(i, j)
            out[#out + 1] = recent:match('exports%s*%[%s*$') and body or (c .. c)
            recent = ''
            i = j + 1
        else
            out[#out + 1] = c
            recent = (recent .. c):sub(-24)
            i = i + 1
        end
    end
    return table.concat(out)
end

local PATTERNS = {
    'exports%s*%.%s*whip_core%f[^%w_]',
    'exports%s*%[%s*[\'"]whip_core[\'"]%s*%]',
    'exports%s*%[%s*CORE%s*%]',
    'exports%s*%[%s*RESOURCE%s*%]',
    'exports%s*%[%s*GetCurrentResourceName%(%)%s*%]',
}

-- Tracked AND new (not yet added) files: the house rule runs this before committing, when a new file is untracked, and
-- only the tracked ones were looked at (audit 20, DX-7). lib/ too (lib/cost.lua is whip_core's), but not
-- lib/satellite.lua, which whip_core never loads (the satellites do, and call whip_core's exports from outside).
local p = assert(io.popen(('git -C "%s" ls-files --cached --others --exclude-standard -- server client shared tools lib'):format(R)))
local files, seenFile = {}, {}
for f in p:lines() do
    if f:match('%.lua$') and f ~= 'lib/satellite.lua' and not seenFile[f] then
        seenFile[f] = true
        files[#files + 1] = f
    end
end
p:close()
table.sort(files)

local found, total = {}, 0
for _, f in ipairs(files) do
    local h = io.open(R .. f, 'rb')
    if h then
        local code = codeOnly(h:read('a')); h:close()
        local lineNo = 0
        for line in (code .. '\n'):gmatch('([^\n]*)\n') do
            lineNo = lineNo + 1
            for _, pat in ipairs(PATTERNS) do
                for _ in line:gmatch(pat) do
                    found[f] = found[f] or {}
                    table.insert(found[f], lineNo)
                    total = total + 1
                end
            end
        end
    end
end

local BASELINE = here .. '/selfexports-baseline.txt'

if mode == 'baseline' then
    local h = assert(io.open(BASELINE, 'w'))
    h:write('# whip_core files still allowed to call whip_core\'s own exports, and how many times (dev/selfexports.lua).\n')
    h:write('# Only ever shrinks: a file moved to the functions comes off.\n')
    local names = {}
    for f in pairs(found) do names[#names + 1] = f end
    table.sort(names)
    for _, f in ipairs(names) do h:write(('%d %s\n'):format(#found[f], f)) end
    h:close()
    print(('baseline written: %d calls in %d files'):format(total, #names))
    return
end

if mode == 'report' then
    for _, f in ipairs(files) do
        for _, ln in ipairs(found[f] or {}) do print(('%s:%d'):format(f, ln)) end
    end
    print(('%d self-export calls'):format(total))
    return
end

local allowed = {}
local bh = io.open(BASELINE)
if bh then
    for line in bh:lines() do
        local n, f = line:match('^(%d+)%s+(%S+)')
        if n then allowed[f] = tonumber(n) end
    end
    bh:close()
end

local problems, fewer = 0, {}
for _, f in ipairs(files) do
    local have = found[f] and #found[f] or 0
    local may = allowed[f] or 0
    if have > may then
        problems = problems + 1
        print(('%s calls whip_core\'s own exports %d time(s) (allowed %d): lines %s'):format(
            f, have, may, table.concat(found[f], ', ')))
    elseif have < may then
        fewer[#fewer + 1] = f
    end
end
if #fewer > 0 then
    print(('fewer than the baseline in %s — `lua selfexports.lua baseline` to shrink it'):format(table.concat(fewer, ', ')))
end
if problems == 0 then
    print(('OK — %d files, no self-export call past the baseline (%d left in the baseline\'s files)'):format(#files, total))
else
    print('Call the function, not the export: an export from inside whip_core is a round trip on a fresh')
    print('coroutine, and on the server what it saves is not tied to the player\'s action (review 8, Q-5).')
    os.exit(1)
end
