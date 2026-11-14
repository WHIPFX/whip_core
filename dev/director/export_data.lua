-- ============================================
-- Write the editor's copies of the Director's shared data, from the Lua that says it
-- ============================================
--
--   lua54 export_data.lua          write them
--   lua54 export_data.lua check    say whether either is behind the Lua (exit 1 when one is): the lint's
--
--   html/js/director/things-data.js   the kinds of placed thing (shared/director/things.lua DirectorThings)
--   html/js/director/refs-data.js     where references live: what each field kind names (server/director/fields.lua),
--                                     where a placed thing is named in another's settings and in the scenario's
--
-- Plain data, so a page that never asks the server (the panel's map) reads what the server does.

local HERE = (arg[0]:match('^(.*)[/\\]') or '.')
local CORE = HERE .. '/../..'

rawset(_G, 'IsDuplicityVersion', function() return true end)
dofile(CORE .. '/shared/director/kit.lua')
dofile(CORE .. '/shared/director/things.lua')
dofile(CORE .. '/server/director/fields.lua')

--- Plain data as JSON, keys sorted (the same text every run). A list stays a list.
local function json(v, ind)
    ind = ind or ''
    local t = type(v)
    if t == 'string' then return '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"' end
    if t == 'number' or t == 'boolean' then return tostring(v) end
    if t ~= 'table' then return 'null' end
    local inner = ind .. '    '
    local parts = {}
    if #v > 0 then
        for _, x in ipairs(v) do parts[#parts + 1] = inner .. json(x, inner) end
        return '[\n' .. table.concat(parts, ',\n') .. '\n' .. ind .. ']'
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do parts[#parts + 1] = inner .. json(tostring(k)) .. ': ' .. json(v[k], inner) end
    return '{\n' .. table.concat(parts, ',\n') .. '\n' .. ind .. '}'
end

local function head(name, from)
    return '// ========================================\n'
        .. ('// %s — as %s says it\n'):format(name, from)
        .. '// ========================================\n'
        .. '// Written by dev/director/export_data.lua: never edit it here. Change the Lua, then run it.\n\n'
end

local FILES = {
    { path = CORE .. '/html/js/director/things-data.js', text = head('THINGS-DATA, the kinds of placed thing', 'shared/director/things.lua')
        .. 'export const THINGS = ' .. json(DirectorThings.KINDS) .. ';\n\n'
        .. '/** A part of a kind\'s (things.lua\'s list): its value, or false. */\n'
        .. 'export const thingIs = (kind, part) => !!THINGS[kind] && (THINGS[kind][part] || false);\n' },
    { path = CORE .. '/html/js/director/refs-data.js', text = head('REFS-DATA, where references live',
            'server/director/fields.lua (kinds) and shared/director/things.lua (named in)')
        .. '/** What each field kind names: { names, refs, sibling } (fields.lua\'s header). */\n'
        .. 'export const FIELD_REFS = ' .. json(DirectorFields.refsData()) .. ';\n\n'
        .. '/** Where a placed thing is named in another\'s settings: { kind, path } (things.lua NAMED_IN). */\n'
        .. 'export const NAMED_IN = ' .. json(DirectorThings.NAMED_IN) .. ';\n\n'
        .. '/** Where it is named in the scenario\'s Settings. */\n'
        .. 'export const SETTINGS_NAMED = ' .. json(DirectorThings.SETTINGS_NAMED) .. ';\n' },
}

if arg[1] == 'check' then
    local behind = 0
    for _, f in ipairs(FILES) do
        local h = io.open(f.path, 'rb')
        local have = h and h:read('a') or ''
        if h then h:close() end
        if have:gsub('\r', '') ~= f.text then
            print(('%s is behind its Lua: run lua54 export_data.lua (dev/director)'):format(f.path:match('[^/\\]+$')))
            behind = behind + 1
        end
    end
    if behind > 0 then os.exit(1) end
    print('things-data.js and refs-data.js match their Lua')
    return
end

for _, f in ipairs(FILES) do
    local h = assert(io.open(f.path, 'wb'))
    h:write(f.text)
    h:close()
    print('wrote ' .. f.path)
end
