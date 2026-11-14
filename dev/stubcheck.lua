--- stubcheck — does every whip_core export have a stub, and every stub an export?
---
--- The stubs in types/server.lua and types/client.lua are what a developer's editor knows of whip: an export without
--- one is invisible to autocomplete, and a stub without an export is a call that throws. This compares them, side by
--- side: server/ is the server, client/ and tools/ the client, shared/ both (fxmanifest.lua loads them so). An export
--- is `exports('Name', ...)`; a stub is `function whip_core:Name(...)`. Names starting __ are internal (whip_test's __Test seams, and the plumbing behind
--- lib/satellite.lua's Whip.* helpers), not public, and are skipped.
--- Not loaded by fxmanifest.lua.
---
--- Usage (from anywhere):
---   lua stubcheck.lua           exit 1 when the two disagree, listing each name

local here = debug.getinfo(1, 'S').source:sub(2):gsub('\\', '/'):match('^(.*)/[^/]*$') or '.'
local R = here .. '/../'

local function read(path)
    local f = io.open(R .. path, 'rb')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return s
end

local function lines(cmd)
    local p = assert(io.popen(cmd))
    local out = {}
    for l in p:lines() do out[#out + 1] = l end
    p:close()
    return out
end

local files = lines(('git -C "%s" ls-files -- server client shared tools'):format(R))
local exportsOf = { server = {}, client = {} }

for _, path in ipairs(files) do
    if path:match('%.lua$') then
        local sides = path:match('^server/') and { 'server' }
            or (path:match('^client/') or path:match('^tools/')) and { 'client' }
            or path:match('^shared/') and { 'server', 'client' } or {}
        local src = read(path) or ''
        -- A line that is a comment says nothing: only code counts.
        for line in (src .. '\n'):gmatch('([^\n]*)\n') do
            local code = line:gsub('%-%-.*$', '')
            for name in code:gmatch("exports%(%s*['\"]([%w_]+)['\"]") do
                for _, s in ipairs(sides) do exportsOf[s][name] = path end
            end
        end
    end
end

local stubsOf = { server = {}, client = {} }
for side, file in pairs({ server = 'types/server.lua', client = 'types/client.lua' }) do
    for name in (read(file) or ''):gmatch('\nfunction whip_core:([%w_]+)%(') do stubsOf[side][name] = true end
end

local problems = 0
for _, side in ipairs({ 'server', 'client' }) do
    local noStub, noExport = {}, {}
    for name, path in pairs(exportsOf[side]) do
        if not name:match('^__') and not stubsOf[side][name] then noStub[#noStub + 1] = name .. ' (' .. path .. ')' end
    end
    for name in pairs(stubsOf[side]) do
        if not exportsOf[side][name] then noExport[#noExport + 1] = name end
    end
    table.sort(noStub)
    table.sort(noExport)
    for _, n in ipairs(noStub) do print(('%s: an export with no stub in types/%s.lua: %s'):format(side, side, n)) end
    for _, n in ipairs(noExport) do print(('%s: a stub with no export: %s'):format(side, n)) end
    problems = problems + #noStub + #noExport
end

if problems > 0 then
    print(('%d difference(s)'):format(problems))
    os.exit(1)
end
local n = 0
for _ in pairs(stubsOf.server) do n = n + 1 end
local m = 0
for _ in pairs(stubsOf.client) do m = m + 1 end
print(('OK — %d server and %d client stubs, one for every export'):format(n, m))
