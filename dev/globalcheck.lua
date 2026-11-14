--- globalcheck — whip_core's module boundaries, measured and held.
---
--- whip_core's files talk through GLOBALS (`lua globalcheck.lua report` gives the numbers), and a
--- module's private parts (`Vehicles._records`, `Stores._dirty`) must not be reached from a file that
--- does not own it.
---
--- A private reach, or a global defined by more than one file, fails `check` whether or not the
--- baseline lists it. The only ones allowed are named in ALLOWED_BREAKS below, each with its reason.
--- A brand-new global fails against the baseline.
---
--- What it reports, per side (server = shared + server scripts, client = shared + client scripts,
--- in fxmanifest.lua's order):
---   GLOBAL  every global a file DEFINES (assigns at any depth), with the files that define it — a
---           name defined by more than one file is one file overwriting another (the helpers.lua
---           broadcast stubs).
---   PRIVATE `Module._field` read or written by a file that does not define `Module` — a module's
---           private state reached from outside it. The files in PRIVATE_EXEMPT below are counted
---           and named in the summary, but not listed, baselined or failed on.
---   FIELD   `Module.x` read where no file on that side defines Module.x. A misspelt loose global is a nil GLOBAL, which the global-read check
---           catches; a misspelt `Module.x` would only be nil when the line runs. Tables whose
---           fields cannot be known are not judged: filled by `M[k] = v`, given a metatable, or
---           assigned anything but a table built right there (a call's result, `x or {}`).
---
--- Files past 255 constants reach globals and fields through registers (LOADK + GETTABLE,
--- _ENV via GETUPVAL); they are read the same as the short forms, and so is a table-valued field
--- write (EXTRAARG is not a write of register 0).
---
--- It only reads. Each file is compiled with luac -l (never run); CfxLua's backtick hashes are
--- turned into identifiers first, as whipcheck does. Not loaded by fxmanifest.lua.
---
--- Usage (from anywhere; paths are found from this file):
---   lua globalcheck.lua report     the full picture, counts first
---   lua globalcheck.lua check      exit 1 on any boundary break not in ALLOWED_BREAKS, or anything
---                                  NEW against globals-baseline.txt
---   lua globalcheck.lua baseline   write globals-baseline.txt from the code as it is now
--- Set WHIP_LUAC to use a luac other than C:\Tools\lua54\luac.exe.

local LUAC = os.getenv('WHIP_LUAC') or [[C:\Tools\lua54\luac.exe]]
local HERE = (arg[0]:match('^(.*)[/\\]') or '.')
local ROOT = HERE .. '\\..'                       -- whip_core
local BASELINE = HERE .. '\\globals-baseline.txt'
-- A name of its own per run (Lua 5.4 seeds math.random at start), removed after each file: two
-- sessions checking at once wrote the same temp file and each read the other's code, so a clean tree
-- came back red ("defined twice", baseline lines "gone").
local TMP = ('%s\\whip_globalcheck_%d_%d.lua'):format(os.getenv('TEMP') or '.', os.time(), math.random(1, 0x7fffffff))

--- Files allowed to reach into other modules' private state, each with the reason. Keep this short:
--- a file belongs here only when reaching inside is its whole job.
local PRIVATE_EXEMPT = {
    -- Fault injection for whip_test: every seam in it is inert unless Config.EnableTestSeams is on,
    -- and pausing a flush or reading a dirty queue from outside is exactly what a test needs to do.
    -- Accessors made only for it would be API that nothing else should ever call.
    ['server/testseams.lua'] = 'test fault injection, inert unless Config.EnableTestSeams',
}

--- The boundary breaks still allowed, as the exact report lines, each with its reason. A PRIVATE line,
--- or a GLOBAL line naming more than one file, fails `check` unless it is here. Fix one and take it
--- out: `check` says when an entry no longer matches anything.
local SHOPS = 'client/shops.lua and client/inventory.lua share it; fix it in the shops code'
local WRAPS = 'two wrappers of the native, each calling the one before: the error tap keeps a handler\'s error '
    .. '(shared/error_tap.lua, second file), the profiler times it (client/profiling.lua, with whip_profiling on)'
local ALLOWED_BREAKS = {
    ['GLOBAL  client ActiveShopId  client/inventory.lua,client/shops.lua']    = SHOPS,
    ['GLOBAL  client AddStateBagChangeHandler  client/profiling.lua,shared/error_tap.lua'] = WRAPS,
    ['GLOBAL  client RegisterNUICallback  client/profiling.lua,shared/error_tap.lua']      = WRAPS,
}

--- Tables whose fields FIELD does not judge, each with the reason.
local FIELD_SKIP = {
}

--- Does this report line fail `check` whatever the baseline says: a private reach, one global defined
--- by several files, or a read of a field no file defines (always a nil — a typo, or a leftover)?
---@param line string
---@return boolean
local function isBreak(line)
    if line:sub(1, 8) == 'PRIVATE ' or line:sub(1, 6) == 'FIELD ' then return true end
    local files = line:match('^GLOBAL%s+%S+%s+%S+%s+(%S+)$')
    return files ~= nil and files:find(',', 1, true) ~= nil
end

local function readAll(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return (s:gsub('^\239\187\191', ''))
end

local function writeAll(path, s)
    local f = assert(io.open(path, 'wb'))
    f:write(s)
    f:close()
end

-- ============================================
-- The manifest: which files, on which side, in which order
-- ============================================

local function manifestLists()
    local lists = { shared = {}, server = {}, client = {} }
    local sideOf = {
        shared_script = 'shared', shared_scripts = 'shared',
        server_script = 'server', server_scripts = 'server',
        client_script = 'client', client_scripts = 'client',
    }
    local env = setmetatable({}, { __index = function(_, directive)
        return function(v)
            local side = sideOf[directive]
            if side then
                local list = lists[side]
                if type(v) == 'string' then list[#list + 1] = v
                elseif type(v) == 'table' then for _, s in ipairs(v) do list[#list + 1] = s end end
            end
            return function() end
        end
    end })
    local src = assert(readAll(ROOT .. '\\fxmanifest.lua'), 'no fxmanifest.lua next to dev/')
    assert(load(src, '@fxmanifest.lua', 't', env))()
    return lists
end

--- A manifest entry as the files it names: '@other/...' is another resource's, a glob is listed.
local function expand(entry)
    if entry:sub(1, 1) == '@' or entry:sub(-4) ~= '.lua' then return {} end
    if not entry:find('*', 1, true) then return { entry } end
    local dir = entry:match('^(.*)/[^/]*$') or '.'
    local out = {}
    local pipe = assert(io.popen('dir /b /on "' .. ROOT .. '\\' .. dir:gsub('/', '\\') .. '\\*.lua" 2>nul'))
    for name in pipe:lines() do out[#out + 1] = dir .. '/' .. name end
    pipe:close()
    return out
end

local function sideFiles(lists, side)
    local files, seen = {}, {}
    for _, group in ipairs({ lists.shared, lists[side] }) do
        for _, entry in ipairs(group) do
            for _, f in ipairs(expand(entry)) do
                if not seen[f] then seen[f] = true; files[#files + 1] = f end
            end
        end
    end
    return files
end

-- ============================================
-- One file's globals, from its bytecode listing
-- ============================================

--- Instructions whose first operand is NOT a register they write — everything else overwrites it,
--- and whatever global that register held is gone.
local KEEPS_A = {
    SETTABUP = true, SETTABLE = true, SETI = true, SETFIELD = true, SETLIST = true,
    RETURN = true, RETURN0 = true, RETURN1 = true, JMP = true, CLOSE = true, TBC = true,
    EQ = true, LT = true, LE = true, EQK = true, EQI = true, LTI = true, LEI = true, GTI = true,
    GEI = true, TEST = true,
    -- Follows every NEWTABLE, and its operand is a number, not a register. Treated as a write, it
    -- "cleared" register 0 after every `X.y = {}` — so a table-valued field was never seen as
    -- written, and a private write of a table (`Mod._x = {}` from outside) was never reported.
    EXTRAARG = true,
}

---@return table|nil defs   set of global names this file assigns (all three nil: the file could not be read)
---@return table|nil priv   list of { global, field, how = 'reads'|'writes' }
---@return table|nil fields { defs = { [global] = { [field] = true } }, reads = { {global, field} },
---                       opaque = { [global] = true }, dynamic = { [global] = true } } — see FIELD
local function scan(relPath)
    local src = readAll(ROOT .. '\\' .. relPath:gsub('/', '\\'))
    if not src then return nil end
    writeAll(TMP, (src:gsub('`', 'Q')))
    -- The whole command in one more pair of quotes: cmd.exe strips the outer pair when a command
    -- starts with a quoted path, which otherwise breaks both paths and lists nothing.
    local pipe = assert(io.popen('""' .. LUAC .. '" -l -l -p "' .. TMP .. '" 2>&1"'))
    local defs, priv, privSeen = {}, {}, {}
    local fields = { defs = {}, reads = {}, opaque = {}, dynamic = {} }
    local readSeen = {}
    local reg = {}    -- register -> global name it holds, right now
    local pend = {}   -- register -> { [key] = true }: the keys set on the table a NEWTABLE just made there
    local alt = {}    -- register -> true: that NEWTABLE is the `x or {}` fallback, so the value may be x
    local kstr = {}   -- register -> the string constant LOADK just put there
    local envr = {}   -- register -> true: it holds _ENV (GETUPVAL), so indexing it is a global
    local prevOp = nil
    local function defField(g, k)
        local set = fields.defs[g]
        if not set then set = {}; fields.defs[g] = set end
        set[k] = true
    end
    local function readField(g, k)
        local id = g .. '.' .. k
        if not readSeen[id] then
            readSeen[id] = true
            fields.reads[#fields.reads + 1] = { global = g, field = k }
        end
    end
    for line in pipe:lines() do
        if line:match('^main <') or line:match('^function <') then
            reg, pend, alt, kstr, envr, prevOp = {}, {}, {}, {}, {}, nil
        else
            local op, ops = line:match('^%s*%d+%s+%[%d+%]%s+(%u[%u%d]*)%s+(%-?%d[%-%dk ]*)')
            local a, b, c, ck
            if ops then a, b, c, ck = ops:match('^(%-?%d+)%s*(%-?%d*)%s*(%-?%d*)(k?)') end
            if op then
                local name = line:match('; _ENV "([^"]+)"')
                local key = line:match(';%s+"([^"]+)"')
                local rawOp = op

                -- PAST 255 CONSTANTS a file can no longer name a key inside the instruction: it
                -- loads the name into a register (LOADK) and uses GETTABLE/SETTABLE, and globals are
                -- reached the same way through _ENV (GETUPVAL). Whip's biggest files are past that
                -- line, so read those as the field or global access they are.
                if op == 'GETTABLE' and kstr[c] then
                    if envr[b] then op, name = 'GETTABUP', kstr[c] else op, key = 'GETFIELD', kstr[c] end
                elseif op == 'SETTABLE' and kstr[b] then
                    if envr[a] then op, name = 'SETTABUP', kstr[b] else op, key = 'SETFIELD', kstr[b] end
                elseif op == 'SELF' and ck == '' and kstr[c] then
                    key = kstr[c]
                end
                if not KEEPS_A[rawOp] then kstr[a] = nil; envr[a] = nil end
                if rawOp == 'LOADK' and key then kstr[a] = key end
                if rawOp == 'GETUPVAL' and line:match(';%s+_ENV%s*$') then envr[a] = true end

                if op == 'SETTABUP' and name then
                    defs[name] = true
                    -- FIELD: a table built right here (`X = { a = 1 }`) gives X its constructor's keys,
                    -- and the register now stands for X, so later `local`-style writes count too.
                    -- Anything else — a call's result, another table, nil, `x or {}` — has fields this
                    -- cannot know.
                    if ck == '' and c ~= '' and pend[c] and not alt[c] then
                        for k in pairs(pend[c]) do defField(name, k) end
                        defField(name, '')           -- a known table, even with no fields yet
                        reg[c] = name
                    else
                        fields.opaque[name] = true
                    end
                elseif op == 'SETFIELD' and key and reg[a] == '_G' then
                    -- `_G.X = v` defines a global as surely as `X = v` does, but compiles to a field
                    -- write on the table `_G` names, so it is counted here.
                    defs[key] = true
                    goto continue
                elseif op == 'GETTABUP' and name then
                    reg[a] = name
                    pend[a] = nil
                elseif (op == 'GETFIELD' or op == 'SETFIELD') and key then
                    -- GETFIELD A B C: the table is B. SETFIELD A B C: the table is A.
                    local tableReg = op == 'GETFIELD' and b or a
                    local g = reg[tableReg]
                    if op == 'SETFIELD' then
                        if pend[a] then pend[a][key] = true end
                        if g then defField(g, key) end
                    elseif g then
                        readField(g, key)
                    end
                    if g and key:sub(1, 1) == '_' then
                        local how = op == 'GETFIELD' and 'reads' or 'writes'
                        local id = g .. '.' .. key .. ' ' .. how
                        if not privSeen[id] then
                            privSeen[id] = true
                            priv[#priv + 1] = { global = g, field = key, how = how }
                        end
                    end
                    if op == 'GETFIELD' then reg[a] = nil; pend[a] = nil; alt[a] = nil end
                    prevOp = rawOp
                    goto continue
                elseif op == 'SELF' then
                    -- `G:method()` reads G.method. (A and A+1 are overwritten; the register
                    -- bookkeeping below clears A, as it always has.)
                    if key and reg[b] then readField(reg[b], key) end
                elseif op == 'NEWTABLE' then
                    reg[a] = nil
                    pend[a] = {}
                    -- Straight after a jump it is the fallback of `x or {}`: the value may be x.
                    alt[a] = (prevOp == 'JMP') or nil
                    prevOp = rawOp
                    goto continue
                elseif (op == 'SETTABLE' or op == 'SETI') and reg[a] then
                    -- `G[k] = v`: fields made at runtime, so no read of G can be judged.
                    fields.dynamic[reg[a]] = true
                elseif op == 'CALL' and (reg[a] == 'setmetatable' or reg[a] == 'rawset') then
                    -- setmetatable(G, { __index = ... }) answers fields nobody wrote.
                    local g = reg[tostring(tonumber(a) + 1)]
                    if g then fields.opaque[g] = true end
                end
                if not KEEPS_A[op] and not (op == 'GETTABUP' and name) then
                    reg[a] = nil
                    pend[a] = nil
                    alt[a] = nil
                end
                prevOp = rawOp
            end
        end
        ::continue::
    end
    pipe:close()
    os.remove(TMP)
    return defs, priv, fields
end

-- ============================================
-- The picture, as sorted lines
-- ============================================

local function measure()
    local lists = manifestLists()
    local lines, counts = {}, {}
    for _, side in ipairs({ 'server', 'client' }) do
        local files = sideFiles(lists, side)
        local definedIn, scans = {}, {}
        for _, f in ipairs(files) do
            local defs, priv, fields = scan(f)
            if defs and priv and fields then
                scans[#scans + 1] = { file = f, priv = priv, fields = fields }
                for name in pairs(defs) do
                    definedIn[name] = definedIn[name] or {}
                    table.insert(definedIn[name], f)
                end
            else
                io.stderr:write('missing: ' .. f .. '\n')
            end
        end
        local nGlobals, nMulti, nPriv = 0, 0, 0
        local exempt = {}   -- [file] = reaches not listed, because the file is in PRIVATE_EXEMPT
        for name, where in pairs(definedIn) do
            table.sort(where)
            lines[#lines + 1] = ('GLOBAL  %s %s  %s'):format(side, name, table.concat(where, ','))
            nGlobals = nGlobals + 1
            if #where > 1 then nMulti = nMulti + 1 end
        end
        for _, s in ipairs(scans) do
            for _, p in ipairs(s.priv) do
                local owners = definedIn[p.global]
                local owned = false
                for _, o in ipairs(owners or {}) do if o == s.file then owned = true end end
                -- Only a module defined in whip_core: another resource's or a native's table is
                -- not a boundary this can speak for.
                if owners and not owned then
                    if PRIVATE_EXEMPT[s.file] then
                        exempt[s.file] = (exempt[s.file] or 0) + 1
                    else
                        lines[#lines + 1] = ('PRIVATE %s %s %s %s.%s'):format(side, s.file, p.how, p.global, p.field)
                        nPriv = nPriv + 1
                    end
                end
            end
        end

        -- FIELD: `Module.x` read on this side where no file on this side ever defines Module.x. With
        -- loose globals a misspelt name was a nil global, which the global-read check catches before
        -- anything runs; once calls go through module tables (`Panels.sessionFor`), a misspelt field
        -- is only nil when that line runs. This is the same catch for fields. Only whip_core's own
        -- tables, and only those whose fields can be known (see scan: opaque, dynamic).
        local fieldDefs, opaque, dynamic = {}, {}, {}
        for _, s in ipairs(scans) do
            for g, set in pairs(s.fields.defs) do
                fieldDefs[g] = fieldDefs[g] or {}
                for k in pairs(set) do fieldDefs[g][k] = true end
            end
            for g in pairs(s.fields.opaque) do opaque[g] = true end
            for g in pairs(s.fields.dynamic) do dynamic[g] = true end
        end
        local nField = 0
        for _, s in ipairs(scans) do
            for _, r in ipairs(s.fields.reads) do
                local g = r.global
                if definedIn[g] and g ~= '_G' and not opaque[g] and not dynamic[g] and not FIELD_SKIP[g]
                        and not (fieldDefs[g] and fieldDefs[g][r.field]) then
                    lines[#lines + 1] = ('FIELD   %s %s reads %s.%s'):format(side, s.file, g, r.field)
                    nField = nField + 1
                end
            end
        end
        counts[side] = { files = #files, globals = nGlobals, multi = nMulti, private = nPriv, exempt = exempt,
                         fields = nField }
    end
    table.sort(lines)
    return lines, counts
end

local function toSet(lines)
    local s = {}
    for _, l in ipairs(lines) do s[l] = true end
    return s
end

local mode = arg[1] or 'report'
local lines, counts = measure()

if mode == 'baseline' then
    writeAll(BASELINE, '# whip_core globals baseline — dev/globalcheck.lua. Regenerate with\n'
        .. '# `lua globalcheck.lua baseline` when a change REMOVES entries; never to wave a new one in.\n'
        .. table.concat(lines, '\n') .. '\n')
    print(('wrote %s (%d lines)'):format(BASELINE, #lines))
    os.exit(0)
end

for _, side in ipairs({ 'server', 'client' }) do
    local c = counts[side]
    print(('%s: %d files, %d globals defined (%d by more than one file), %d private reaches across files, %d reads of a field nothing defines')
        :format(side, c.files, c.globals, c.multi, c.private, c.fields))
    for file, n in pairs(c.exempt) do
        print(('  + %d more in %s, exempt: %s'):format(n, file, PRIVATE_EXEMPT[file]))
    end
end

if mode == 'report' then
    for _, l in ipairs(lines) do print(l) end
    os.exit(0)
end

if mode == 'check' then
    local src = readAll(BASELINE)
    if not src then print('no baseline — run `lua globalcheck.lua baseline` first'); os.exit(1) end
    local base = {}
    for l in src:gmatch('[^\r\n]+') do if l:sub(1, 1) ~= '#' then base[#base + 1] = l end end
    local baseSet, nowSet = toSet(base), toSet(lines)

    -- THE LOCK FIRST: a boundary break fails whatever the baseline says.
    local broken, stale = {}, {}
    for _, l in ipairs(lines) do
        if isBreak(l) and not ALLOWED_BREAKS[l] then broken[#broken + 1] = l end
    end
    for l in pairs(ALLOWED_BREAKS) do if not nowSet[l] then stale[#stale + 1] = l end end
    table.sort(stale)

    local new, gone = {}, {}
    for _, l in ipairs(lines) do
        if not baseSet[l] and not (isBreak(l) and not ALLOWED_BREAKS[l]) then new[#new + 1] = l end
    end
    for _, l in ipairs(base) do if not nowSet[l] then gone[#gone + 1] = l end end
    if #gone > 0 then
        print(('\n%d baseline line(s) no longer true — progress; run `lua globalcheck.lua baseline`:'):format(#gone))
        for _, l in ipairs(gone) do print('  - ' .. l) end
    end
    if #stale > 0 then
        print(('\n%d ALLOWED_BREAKS %s no longer %s anything — fixed; take %s out:')
            :format(#stale, #stale == 1 and 'entry' or 'entries', #stale == 1 and 'matches' or 'match',
                #stale == 1 and 'it' or 'them'))
        for _, l in ipairs(stale) do print('  - ' .. l) end
    end
    local failed = false
    if #broken > 0 then
        print(('\nBOUNDARY BROKEN (%d) — a module\'s private state reached from another file, one global defined by several, or a field nothing defines:'):format(#broken))
        for _, l in ipairs(broken) do print('  ! ' .. l) end
        print('\nPRIVATE / GLOBAL: give the owning module an accessor (Vehicles.getDef, Stores.viewedBy), or one')
        print('owner with a setter (SetActiveVehicleStorage), or a registry (DevTools.setRefresh).')
        print('FIELD: a misspelt name, or a read of something that was renamed or removed — it is always nil.')
        print('ALLOWED_BREAKS and FIELD_SKIP are for a reason, not a shortcut.')
        failed = true
    end
    if #new > 0 then
        print(('\nNEW (%d) — a global that did not exist before:'):format(#new))
        for _, l in ipairs(new) do print('  + ' .. l) end
        print('\nMake it a local, or an accessor on the module that owns it. A deliberate new framework')
        print('function goes in with `lua globalcheck.lua baseline`, and the commit says why.')
        failed = true
    end
    if failed then os.exit(1) end
    print('\nOK — nothing new, and no boundary broken beyond ALLOWED_BREAKS.')
    os.exit(0)
end

print('usage: lua globalcheck.lua report | check | baseline')
os.exit(2)
