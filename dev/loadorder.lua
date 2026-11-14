--- loadorder — does any file read, AS IT LOADS, a global that only a later file defines?
---
--- fxmanifest.lua loads files in order, and a file's top-level code runs as it loads. A global that a
--- LATER file defines is still nil then: the read errors, the file stops at that line, and everything
--- defined after it is missing — with only the first error in the console (e.g. "attempt to call a
--- nil value (method 'serialize')" when player.lua once called Stores.beforeFlush at load).
---
--- Two passes: the server's files (shared/, server/, config.lua) and the client's (shared/, client/, tools/, lib/,
--- config.lua), each against its own side's lines of globals-baseline.txt. A client file calling PlayerPrefs.define,
--- ControlBlocks.hold or PropPrompts.define at file scope depends on the order as much as a server one.
---
--- It reads each file's main chunk (luac -l -l, never run) for globals, and the owner of each global from
--- globals-baseline.txt. Calls made at load time INTO functions are not followed — keep load-time code to
--- registrations. Not loaded by fxmanifest.lua.
---
--- Usage (from anywhere): lua loadorder.lua      exit 1 when a file reads a later file's global at load

local here = debug.getinfo(1, 'S').source:sub(2):gsub('\\', '/'):match('^(.*)/[^/]*$') or '.'
local R = here .. '/../'

local mf = io.open(R .. 'fxmanifest.lua'):read('a')

--- A manifest entry as the files it names, in the order FiveM loads them: a glob ('server/items/*.lua') is listed,
--- by name, as globalcheck.lua expands it. (Taken literally, luac could not open it, and the file counted as clean:
--- audit 20, DX-1.)
local function expand(entry)
    if not entry:find('*', 1, true) then return { entry } end
    local dir = entry:match('^(.*)/[^/]*$') or '.'
    local out = {}
    local pipe = assert(io.popen('dir /b /on "' .. (R .. dir):gsub('/', '\\') .. '\\*.lua" 2>nul'))
    for name in pipe:lines() do out[#out + 1] = dir .. '/' .. name end
    pipe:close()
    return out
end

--- The files one side loads, in the manifest's order: those under `prefixes` (and config.lua).
local function orderOf(prefixes)
    local order, seen = {}, {}
    for line in mf:gmatch('[^\n]+') do
        local entry = line:match("^%s*shared_script%s+'([^']+%.lua)'") or line:match("^%s*'([^@'][^']*%.lua)',?")
        for _, f in ipairs(entry and expand(entry) or {}) do
            local mine = f == 'config.lua'
            for _, p in ipairs(prefixes) do
                if f:sub(1, #p) == p then mine = true end
            end
            if mine and not seen[f] then
                seen[f] = true
                order[#order + 1] = f
            end
        end
    end
    return order
end

local TMP = ('%s\\whip_loadorder_%d_%d.lua'):format(os.getenv('TEMP') or '.', os.time(), math.random(1, 0x7fffffff))

--- The globals a file's main chunk reads as it loads, or nil when luac could not read it. CfxLua's backtick hashes are
--- turned into identifiers first (stock luac refuses them), and a chunk past 255 constants, which reaches a global by
--- LOADK + GETTABLE on _ENV (GETUPVAL), is read as the GETTABUP it stands for (as globalcheck.lua reads them).
local function readsAtLoad(f)
    local h = io.open(R .. f, 'rb')
    if not h then return nil end
    local src = h:read('a'):gsub('^\239\187\191', '')
    h:close()
    local t = assert(io.open(TMP, 'wb')); t:write((src:gsub('`', 'Q'))); t:close()
    local p = assert(io.popen(('luac54 -l -l -p "%s" 2>&1'):format(TMP)))
    local out = p:read('a'); p:close()
    if not out:match('^%s*main <') then return nil end
    local mainPart = out:match('^(.-)\nfunction <') or out
    local names, kstr, envr = {}, {}, {}
    for line in mainPart:gmatch('[^\n]+') do
        local op, ops = line:match('^%s*%d+%s+%[%d+%]%s+(%u[%u%d]*)%s+(%-?%d[%-%dk ]*)')
        if op then
            local a, b, c = ops:match('^(%-?%d+)%s*(%-?%d*)%s*(%-?%d*)')
            local name = line:match('; _ENV "([%w_]+)"')
            if op == 'GETTABUP' and name then names[#names + 1] = name end
            if op == 'GETTABLE' and envr[b] and kstr[c] then names[#names + 1] = kstr[c] end
            local writesA = not (op:match('^SET') or op:match('^RETURN') or op == 'JMP' or op == 'CLOSE' or op == 'TBC'
                or op:match('^EQ') or op:match('^L[TE]') or op:match('^G[TE]') or op == 'TEST' or op == 'EXTRAARG')
            if writesA then kstr[a], envr[a] = nil, nil end
            if op == 'LOADK' then kstr[a] = line:match(';%s+"([%w_]+)"') end
            if op == 'GETUPVAL' and line:match(';%s+_ENV%s*$') then envr[a] = true end
        end
    end
    return names
end

local function pass(side, prefixes)
    local order = orderOf(prefixes)
    local pos = {}
    for i, f in ipairs(order) do pos[f] = i end

    local definedIn = {}
    for line in io.open(here .. '/globals-baseline.txt'):lines() do
        local name, file = line:match('^GLOBAL%s+' .. side .. '%s+(%S+)%s+(%S+)')
        -- (profiling.lua wraps the runtime's own AddEventHandler and the like: they are there before any file)
        if name and not file:find('profiling.lua', 1, true) then definedIn[name] = file end
    end

    local problems = 0
    for i, f in ipairs(order) do
        local reads = readsAtLoad(f)
        if not reads then
            -- Not read is not clean: a file luac could not open or compile fails the run
            problems = problems + 1
            print(('could not read %s (%s): luac could not open or compile it'):format(f, side))
            reads = {}
        end
        for _, name in ipairs(reads) do
            -- (A global several files define: the first of them listed)
            local def = definedIn[name]
            if def and def:find(',', 1, true) then def = def:match('^([^,]+)') end
            if def and pos[def] and pos[def] > i then
                problems = problems + 1
                print(('%s (%s) reads %s as it loads, but %s defines it and loads later'):format(f, side, name, def))
            end
        end
    end
    return problems, #order
end

local sp, sn = pass('server', { 'shared/', 'server/' })
local cp, cn = pass('client', { 'shared/', 'client/', 'tools/', 'lib/' })
os.remove(TMP)
local problems = sp + cp

if problems == 0 then
    print(('OK — %d server and %d client files, none reads a later file\'s global as it loads'):format(sn, cn))
else
    print(('%d load-order problem(s): register from the later file, or move the read into a function'):format(problems))
    os.exit(1)
end
