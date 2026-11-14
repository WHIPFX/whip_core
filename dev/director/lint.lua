-- ============================================
-- The Director's lint: no name outside its registries
-- ============================================
--
--   lua54 lint.lua      (from whip_core/dev/director; golden.lua runs it too)
--
-- Code that asks for a step type, a card type or a kind by its name must name one that exists: a misspelt one is a
-- branch that never runs, said by nothing. Each Director file, Lua and the editor's JS, is read for
--   a step's type    .t == 'x'      (shared/director/steps.lua DirectorSteps, another resource's aside)
--   a card's type    .type == 'a.b' (the card types whip_core defines: server/director/nodes*.lua and the rest)
--   a field's kind   f.kind == 'x'  (server/director/fields.lua)
--   a thing's kind   w.kind == 'x'  (shared/director/things.lua, and the few the world builder and Dungeon Mode keep:
--                                   OTHER_KINDS)
-- (f and w are the house's names for a field and a placed thing: other variables called kind are not read.)
-- and the editor's data files must match their Lua (export_data.lua check). The last line says how many are wrong.

local HERE = (arg[0]:match('^(.*)[/\\]') or '.')
local CORE = HERE .. '/../..'
local WIN = package.config:sub(1, 1) == '\\'

rawset(_G, 'IsDuplicityVersion', function() return true end)
dofile(CORE .. '/shared/director/kit.lua')
dofile(CORE .. '/shared/director/steps.lua')
dofile(CORE .. '/shared/director/things.lua')
dofile(CORE .. '/server/director/fields.lua')

-- Files whose `w` is not a placed thing (the runtime's is a wait).
local W_IS_NOT_A_THING = { ['runtime.lua'] = true }

-- Kinds a `w` may be that are not a placed thing's, each with where it is from.
local OTHER_KINDS = {
    point = 'the world builder: a task step\'s or a route\'s point', hero = 'the world builder: the player\'s copy',
    live = 'Dungeon Mode: a thing of the live world', liveProp = 'Dungeon Mode: a live prop', hide = 'Dungeon Mode: a hidden map prop',
}

local function list(dir, pattern)
    local cmd = WIN and ('dir /b "%s" 2>nul'):format(dir:gsub('/', '\\')) or ('ls "%s" 2>/dev/null'):format(dir)
    local out = {}
    local p = assert(io.popen(cmd))
    for name in p:lines() do if name:match(pattern) then out[#out + 1] = dir .. '/' .. name end end
    p:close()
    table.sort(out)
    return out
end

local function read(path)
    local f = io.open(path, 'rb')
    if not f then return '' end
    local s = f:read('a')
    f:close()
    return s
end

-- The card types whip_core defines (every `type = 'a.b'` in a card file's define).
local CARDS = {}
for _, path in ipairs(list(CORE .. '/server/director', '%.lua$')) do
    for t in read(path):gmatch("%f[%w]type = '([%a][%w_]*%.[%a][%w_.]*)'") do CARDS[t] = true end
end

local FILES = {}
for _, d in ipairs({ '/server/director', '/html/js/director' }) do
    for _, p in ipairs(list(CORE .. d, '%.l?u?a?j?s?$')) do
        if p:match('%.lua$') or p:match('%.js$') then FILES[#FILES + 1] = p end
    end
end
for _, p in ipairs(list(CORE .. '/client', '^director.*%.lua$')) do FILES[#FILES + 1] = p end
FILES[#FILES + 1] = CORE .. '/client/npcs.lua'
FILES[#FILES + 1] = CORE .. '/client/actors.lua'
FILES[#FILES + 1] = CORE .. '/server/npcs.lua'
FILES[#FILES + 1] = CORE .. '/server/task_seq.lua'

local problems = 0
local function bad(path, n, what)
    problems = problems + 1
    print(('%s:%d  %s'):format(path:gsub('^.*/whip_core/', 'whip_core/'), n, what))
end

for _, path in ipairs(FILES) do
    local n = 0
    for line in (read(path) .. '\n'):gmatch('([^\n]*)\n') do
        n = n + 1
        -- (Comments out; `typeof x.t` is a type's name, not a step's.)
        local code = line:gsub('%-%-.*$', ''):gsub('//.*$', ''):gsub('typeof%s+[%w_.%[%]]+', '')
        -- a step's type
        for t in code:gmatch("%.t%s*[=!~]=+%s*'([%w_]+)'") do
            if not DirectorSteps.TYPES[t] then bad(path, n, ('step type "%s" is not one of DirectorSteps\'s'):format(t)) end
        end
        -- a card's type
        for t in code:gmatch("type%s*[=!~]=+%s*'([%a][%w_]*%.[%a][%w_.]*)'") do
            if not CARDS[t] then bad(path, n, ('card type "%s" is not one whip_core defines'):format(t)) end
        end
        -- a field's kind, a placed thing's kind
        for k in code:gmatch("%f[%w]f%.kind%s*[=!~]=+%s*'([%w_]+)'") do
            if not DirectorFields.get(k) then bad(path, n, ('field kind "%s" is not one of DirectorFields\'s'):format(k)) end
        end
        for k in code:gmatch("%f[%w]w%.kind%s*[=!~]=+%s*'([%w_]+)'") do
            if not (DirectorThings.get(k) or OTHER_KINDS[k] or W_IS_NOT_A_THING[path:match('[^/\\]+$')]) then
                bad(path, n, ('placed thing kind "%s" is not one of DirectorThings\'s (or OTHER_KINDS)'):format(k))
            end
        end
    end
end

-- The editor's data files, as their Lua says them.
local ok = os.execute(('lua54 "%s/export_data.lua" check'):format(HERE))
if ok ~= true and ok ~= 0 then
    problems = problems + 1
    print('the editor\'s data files are behind their Lua: lua54 export_data.lua')
end

print(('lint: %d problems'):format(problems))
os.exit(problems == 0 and 0 or 1)
