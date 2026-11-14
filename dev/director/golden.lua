-- The Director's regression net: every dev/director module and test, whip_test's Director tests, Check over every
-- scenario those build (CHECKONLY) and the lint, run one after another; their counts written to golden_last.txt and compared with
-- golden_baseline.txt (what passed before a change). A line that differs is printed, and the exit code says so.
--   lua54 golden.lua            (from whip_core/dev/director)
--   lua54 golden.lua --accept   the counts as they are now become the baseline (after a change that meant them)
local here = (arg[0] or ''):match('^(.*)[/\\]') or '.'
local accept = arg[1] == '--accept'
local WIN = package.config:sub(1, 1) == '\\'

local function list(dir, pattern)
    local cmd = WIN and ('dir /b "%s" 2>nul'):format(dir:gsub('/', '\\')) or ('ls "%s" 2>/dev/null'):format(dir)
    local out = {}
    local p = assert(io.popen(cmd))
    for name in p:lines() do if name:match(pattern) then out[#out + 1] = name end end
    p:close()
    table.sort(out)
    return out
end

local function run(env, args)
    local set = {}
    for k, v in pairs(env) do set[#set + 1] = WIN and ('set "%s=%s" && '):format(k, v) or ('%s=%s '):format(k, v) end
    table.sort(set)
    local cmd = (WIN and ('cd /d "%s" && '):format(here:gsub('/', '\\')) or ('cd "%s" && '):format(here))
        .. table.concat(set) .. 'lua54 ' .. args .. ' 2>&1'
    local p = assert(io.popen(cmd))
    local text = p:read('a')
    p:close()
    return text
end

local lines = {}
local function add(name, text, pattern)
    local found = nil
    for l in text:gmatch('[^\r\n]+') do
        local m = l:match(pattern)
        if m then found = m end
    end
    lines[#lines + 1] = ('%-40s %s'):format(name, found or 'NO RESULT')
    io.write(lines[#lines], '\n')
end

local TESTS = '../../../whip_test/server/tests/'
for _, m in ipairs(list(here, '_module%.lua$')) do
    add(m, run({ MEMCAP_MB = 512 }, 'guard.lua harness.lua ' .. m), '(%d+ passed, %d+ failed, %d+ skipped)')
end
for _, t in ipairs(list(here, '_test%.lua$')) do
    add(t, run({ MEMCAP_MB = 512 }, t), '(%d+ passed, %d+ failed)')
end
for _, t in ipairs(list(here .. '/' .. TESTS, '^%d+_director.*%.lua$')) do
    add(t, run({ MEMCAP_MB = 512 }, 'guard.lua harness.lua ' .. TESTS .. t), '(%d+ passed, %d+ failed, %d+ skipped)')
    add(t .. ' (Check)', run({ MEMCAP_MB = 512, CHECKONLY = 1 }, 'guard.lua harness.lua ' .. TESTS .. t),
        'CHECKONLY: (%d+ scenarios checked, %d+ with errors)')
end
-- No name outside the registries, and the editor's data files as their Lua says them (lint.lua).
add('lint.lua', run({}, 'lint.lua'), '(lint: %d+ problems)')

local now = table.concat(lines, '\n') .. '\n'
local f = assert(io.open(here .. '/golden_last.txt', 'wb')) f:write(now) f:close()
if accept then
    f = assert(io.open(here .. '/golden_baseline.txt', 'wb')) f:write(now) f:close()
    print('baseline written')
    return
end
local bf = io.open(here .. '/golden_baseline.txt', 'rb')
if not bf then print('no baseline yet: lua54 golden.lua --accept') os.exit(1) end
local base = {}
for l in bf:read('a'):gmatch('[^\r\n]+') do base[l:match('^(%S+.-)%s%s+') or l] = l end
bf:close()
local differ = 0
for _, l in ipairs(lines) do
    local key = l:match('^(%S+.-)%s%s+') or l
    if base[key] ~= l then
        differ = differ + 1
        print('DIFFERS  now:  ' .. l)
        print('         was:  ' .. tostring(base[key]))
    end
end
print(differ == 0 and 'golden: the same as the baseline' or ('golden: %d line(s) differ'):format(differ))
os.exit(differ == 0 and 0 or 1)
