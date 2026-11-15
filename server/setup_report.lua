-- ============================================
-- The setup report — server/setup_report.lua
-- ============================================
--
-- One block in the server console once a start has settled: what whip found about this server, and for each problem
-- the line that fixes it, then "Framework loaded successfully!" when nothing needs fixing. For a server owner setting
-- whip up; `whipsetup` in the server console prints the report again.
--
-- PRINTED SETTLE_MS AFTER THE LAST RESOURCE STARTED since whip_core was ready (whip_core:onReady fires for every start
-- while it is up), so whatever was ensured with whip has started by then: a pack that starts after whip_core is not
-- reported missing. At most CAP_MS after whip_core was ready. A start that halted prints its halt instead.

local SETTLE_MS, CAP_MS = 5000, 60000

--- The oldest Legacy game build whip's car, prop and clothing lists are made for.
local MIN_LEGACY_BUILD = 3407
--- The build the Legacy recipe sets, which the report suggests when sv_enforceGameBuild is missing.
local LEGACY_BUILD = 3889

--- Resources that do a job whip does itself: running beside whip, each fights it.
local CLASHES = {
    { 'spawnmanager', 'whip spawns players itself, and spawnmanager spawning them too (basic-gamemode turns that on)'
        .. ' fights whip\'s spawn and death' },
    { 'basic-gamemode', 'it turns spawnmanager\'s spawning on' },
}
local FRAMEWORKS = { 'es_extended', 'qb-core', 'qbx_core', 'ox_core', 'vrp', 'ND_Core' }
-- Another inventory or target beside whip's: two hold a player's items, two draw prompts on the same keys.
local OTHER_INVENTORIES = { 'ox_inventory', 'qb-inventory', 'ps-inventory', 'qs-inventory', 'lj-inventory' }
local OTHER_TARGETS = { 'ox_target', 'qb-target', 'qtarget' }
local OTHER_VOICES = { 'pma-voice', 'saltychat', 'tokovoip_script', 'mumble-voip', 'yaca-voice' }

local function running(res)
    local s = GetResourceState(res)
    return s == 'started' or s == 'starting'
end

local function versionOf(res)
    local v = GetResourceMetadata(res, 'version', 0)
    return v and v ~= '' and v or nil
end

--- Is version `have` at least `want`? ('1.0' is 1.0.0; lib/satellite.lua's Whip.versionAtLeast is the same.)
local function versionAtLeast(have, want)
    local a, b = {}, {}
    for n in tostring(have):gmatch('%d+') do a[#a + 1] = tonumber(n) end
    for n in tostring(want):gmatch('%d+') do b[#b + 1] = tonumber(n) end
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x ~= y then return x > y end
    end
    return true
end

--- Every resource the server knows, by name.
local function allResources()
    local out = {}
    for i = 0, GetNumResources() - 1 do
        local res = GetResourceByFindIndex(i)
        if res then out[#out + 1] = res end
    end
    table.sort(out)
    return out
end

--- How many of whip's four marks the oxmysql build carries: those of WHIPFX's oxmysql, or of a build patched by hand with
--- dev/oxmysql-p001.diff (a lost connection fails at once).
local function oxmysqlPatched()
    local src = LoadResourceFile('oxmysql', 'dist/build.js')
    if not src then return false end
    local marks, at = 0, 1
    while true do
        local _, e = src:find('whip P-001 patch', at, true)
        if not e then break end
        marks, at = marks + 1, e + 1
    end
    return marks >= 4
end

--- What the server's own version string says it is: 'legacy', 'enhanced', or nil when it cannot tell.
--- Legacy's FXServer reads "FXServer-master SERVER v1.0.0.17000 win32"; Enhanced's "FXServer-early-access b169 win32".
local function serverLooksLike()
    local v = GetConvar('version', '')
    if v:find('v1%.0%.0%.%d+') then return 'legacy' end
    if v:find(' b%d+') then return 'enhanced' end
    return nil
end

--- The report's lines: { level = 'ok' | 'fix' | 'note', text }.
local function gather()
    local lines = {}
    local function add(level, fmt, ...) lines[#lines + 1] = { level = level, text = fmt:format(...) } end

    -- OneSync: server-side entities, positions and every `near` check.
    if GetConvar('onesync', 'off') ~= 'off' or GetConvar('onesync_enabled', 'false') == 'true' then
        add('ok', 'OneSync on')
    else
        add('fix', 'OneSync is off, and whip needs it. In txAdmin: Settings, FXServer, OneSync: On. Or "set onesync on"'
            .. ' in server.cfg. Then restart the server')
    end

    -- Which GTA V, and its build.
    local looks = serverLooksLike()
    if looks and looks ~= GamePlatform.name then
        add('fix', 'This server looks like %s (%s), but whip_platform says %s. Add to server.cfg: setr whip_platform %s',
            looks == 'enhanced' and 'FiveM for GTA V Enhanced' or 'FiveM for GTA V Legacy', GetConvar('version', ''),
            GamePlatform.name, looks)
    end
    if GamePlatform.enhanced then
        add('ok', 'GTA V Enhanced (whip_platform enhanced)')
    else
        local build = tonumber(GetConvar('sv_enforceGameBuild', ''))
        if not build then
            add('fix', 'No sv_enforceGameBuild: players get FiveM\'s default game build, without the cars, props and clothes'
                .. ' whip\'s lists name. Add to server.cfg: sv_enforceGameBuild %d (or a newer build)', LEGACY_BUILD)
        elseif build < MIN_LEGACY_BUILD then
            add('fix', 'sv_enforceGameBuild is %d: whip\'s lists are made for %d or newer. Raise it in server.cfg', build,
                MIN_LEGACY_BUILD)
        else
            add('ok', 'GTA V Legacy, game build %d', build)
        end
    end

    -- The database, and oxmysql.
    local db, ox = DbHealth.server, versionOf('oxmysql') or '?'
    if db and db.problem then
        add('fix', '%s. Update the database server', db.problem)
    else
        -- MySQL's own version string is the number alone ('8.0.35'); MariaDB's says MariaDB.
        local text = db and db.text or '?'
        if db and db.kind and not text:find(db.kind, 1, true) then text = db.kind .. ' ' .. text end
        local patched = oxmysqlPatched()
        add('ok', 'Database %s, oxmysql %s%s', text, ox, patched and ' (with whip\'s patch)' or '')
        -- Stock oxmysql works; the patch is what keeps a query from waiting for ever while the database is down.
        if not patched and GetResourceState('oxmysql') ~= 'missing' then
            add('note', 'oxmysql has not got whip\'s patch: while the database is down a query can wait for ever'
                .. ' (whip gives up on it after 65 s). WHIPFX\'s oxmysql has it: github.com/WHIPFX/oxmysql/releases')
        end
    end

    -- The asset packs: pictures, videos, the map.
    local missing, stopped = {}, {}
    local packs = WhipAssets.resources()
    for _, res in ipairs(packs) do
        local s = GetResourceState(res)
        if s == 'missing' then missing[#missing + 1] = res
        elseif s ~= 'started' and s ~= 'starting' then stopped[#stopped + 1] = res end
    end
    if #missing > 0 then
        add('fix', 'Not in the resources folder: %s. Players miss the pictures and videos in them: put them in your resources'
            .. ' folder (a server made by WHIP\'s recipe keeps them in [assets]/[media])', table.concat(missing, ', '))
    end
    if #stopped > 0 then
        add('fix', 'In the resources folder but not started: %s. Start them with "ensure <name>" for each, or with the'
            .. ' ensure of the folder they are in ("ensure [assets]" in a server made by WHIP\'s recipe)',
            table.concat(stopped, ', '))
    end
    if #missing == 0 and #stopped == 0 then
        add('ok', 'Pictures and videos: %s', table.concat(packs, ', '))
    end

    -- The satellites, and the property packs.
    local sats, idle, homes = {}, {}, {}
    for _, res in ipairs(allResources()) do
        if res ~= GetCurrentResourceName() and Satellites.dependsOnCore(res) then
            local v = versionOf(res)
            if running(res) then sats[#sats + 1] = v and (res .. ' ' .. v) or res
            else idle[#idle + 1] = res end
        elseif running(res) and (GetNumResourceMetadata(res, 'whip_property_pack') or 0) > 0 then
            homes[#homes + 1] = res
        end
    end
    add('ok', 'whip_core %s with %d satellite%s%s', versionOf(GetCurrentResourceName()) or '?', #sats,
        #sats == 1 and '' or 's', #sats > 0 and (': ' .. table.concat(sats, ', ')) or '')
    if #homes > 0 then add('ok', 'Property packs: %s', table.concat(homes, ', ')) end
    if #idle > 0 then add('note', 'In the resources folder, not started: %s', table.concat(idle, ', ')) end

    -- Newer releases on GitHub (server/updates.lua), from its last answers: the first check runs after this report.
    if Updates then Updates.reportLines(add) end

    -- What whip each resource says it needs (whip_requires '1.0' in its fxmanifest.lua).
    local coreVersion = versionOf(GetCurrentResourceName()) or '0'
    for _, res in ipairs(allResources()) do
        local need = GetResourceMetadata(res, 'whip_requires', 0)
        if need and need ~= '' and not versionAtLeast(coreVersion, need) then
            add('fix', '%s needs whip_core %s or newer, and this is %s: update whip_core', res, need, coreVersion)
        end
    end

    -- Built for the other GTA V: a pack with models comes as <name> (Legacy) and <name>_enhanced (Enhanced).
    for _, res in ipairs(allResources()) do
        if running(res) then
            local legacyName = res:match('^(.+)_enhanced$')
            if legacyName and GamePlatform.legacy then
                add('fix', '%s is built for GTA V Enhanced, and this server is Legacy: take it out%s', res,
                    GetResourceState(legacyName) ~= 'missing' and (', and run ' .. legacyName) or '')
            elseif not legacyName and GamePlatform.enhanced and GetResourceState(res .. '_enhanced') ~= 'missing' then
                add('fix', '%s is the GTA V Legacy build: take it out, and run %s_enhanced', res, res)
            end
        end
    end

    -- One loading screen.
    for _, res in ipairs(allResources()) do
        if res ~= 'whip_loadingscreen' and running(res) and running('whip_loadingscreen')
            and (GetNumResourceMetadata(res, 'loadscreen') or 0) > 0 then
            add('fix', '%s is a second loading screen beside whip_loadingscreen: take one out', res)
        end
    end

    -- A custom inventory UI (docs/nui-inventory.md): when it cannot load, players get whip's own and only their F8 says.
    local ui = GetConvar('whip_inventory_renderer', '')
    if ui == '' then ui = Config.InventoryRenderer or '' end
    if ui ~= '' then
        if not running(ui) then
            add('fix', 'The inventory UI is set to %s, which is not running: players get whip\'s own. Ensure it, or'
                .. ' clear Config.InventoryRenderer / whip_inventory_renderer', ui)
        elseif not LoadResourceFile(ui, 'renderer.js') then
            add('fix', '%s has no renderer.js: players get whip\'s own inventory UI (docs/nui-inventory.md)', ui)
        else
            add('ok', 'Inventory UI: %s', ui)
        end
    end

    -- Voice.
    local voice = VoiceSystem.get()
    local others = {}
    for _, res in ipairs(OTHER_VOICES) do if running(res) then others[#others + 1] = res end end
    if voice then
        add('ok', 'Voice: %s', voice.resource)
        for _, res in ipairs(others) do
            add('fix', '%s is running beside %s: two voice systems. Remove "ensure %s" from server.cfg', res, voice.resource, res)
        end
    elseif #others > 0 then
        add('note', 'Voice: %s. whip\'s phone calls and radio need whip_voice', table.concat(others, ', '))
    else
        add('note', 'No voice: players cannot talk. whip_voice is WHIP\'s voice: add "ensure whip_voice", and it runs its'
            .. ' own voice server (whip_voice/docs/SETUP.md)')
    end

    -- What fights whip.
    if running('chat') and running('whip_chat') then
        add('fix', 'chat is running beside whip_chat: two chat boxes on one key. Remove "ensure chat" from server.cfg')
    end
    for _, c in ipairs(CLASHES) do
        if running(c[1]) then add('fix', '%s is running: %s. Remove "ensure %s" from server.cfg', c[1], c[2], c[1]) end
    end
    for _, res in ipairs(FRAMEWORKS) do
        if running(res) then
            add('fix', '%s is another framework: whip is a whole framework, and is not made to run beside one. Remove'
                .. ' "ensure %s" from server.cfg', res, res)
        end
    end
    for _, res in ipairs(OTHER_INVENTORIES) do
        if running(res) then
            add('fix', '%s is another inventory: whip has its own, and two would each hold a player\'s items. Remove'
                .. ' "ensure %s", and register its items with whip (RegisterItem; docs: Coming from QBCore, ESX or ox)',
                res, res)
        end
    end
    for _, res in ipairs(OTHER_TARGETS) do
        if running(res) then
            add('fix', '%s is another target system: whip\'s prompts are AddAction, and two draw on the same keys.'
                .. ' Remove "ensure %s", and move its targets to AddAction (docs: Coming from QBCore, ESX or ox)', res, res)
        end
    end

    -- Test seams (config.lua): a test server's.
    if Config.EnableTestSeams == true then
        add('note', 'Test seams are on (set whip_test_seams true): whip_test can fake database failures. A test server only')
    end

    -- What another resource asked to register and was refused, so far (Registry.sayRefused said each as it came).
    local refused = Registry.refusals()
    for i = 1, math.min(#refused, 8) do
        add('fix', 'Refused for %s: %s', refused[i].owner, refused[i].why)
    end
    if #refused > 8 then add('fix', '... and %d more refusals: the console lines above say each', #refused - 8) end
    return lines
end

local MARK = { ok = '^2  ok  ^0', fix = '^1  FIX ^0', note = '^3  note^0' }

--- Print the report. Answers how many lines need fixing, or nil when the report itself failed.
---@return integer|nil fixes
local function printReport()
    local ok, lines = pcall(gather)
    if not ok then
        print(('^1[whip] the setup report failed: %s^0'):format(tostring(lines)))
        return nil
    end
    local fixes, notes = 0, 0
    print('[whip] ==================== whip setup ====================')
    for _, l in ipairs(lines) do
        if l.level == 'fix' then fixes = fixes + 1 elseif l.level == 'note' then notes = notes + 1 end
        print(('[whip] %s %s'):format(MARK[l.level], l.text))
    end
    print(('[whip] %s, %d note%s. Type whipsetup in this console to see this again.')
        :format(fixes == 0 and '^2Nothing to fix^0' or ('^1' .. fixes .. ' to fix^0'), notes, notes == 1 and '' or 's'))
    print('[whip] =====================================================')
    return fixes
end

--- After the start's report, only when it found nothing to fix.
local function printLoaded()
    print('[whip_core] ============================================')
    print(('[whip_core] whip_core Beta %s — public release')
        :format(GetResourceMetadata(GetCurrentResourceName(), 'version', 0) or '?'))
    print('[whip_core] Framework loaded successfully!')
    print('[whip_core] ============================================')
end

-- Once per start, when the starts have settled (see the top).
local printed, timer, firstAt = false, nil, nil
AddEventHandler('whip_core:onReady', function()
    if printed then return end
    firstAt = firstAt or GetGameTimer()
    if timer then ClearTimeout(timer) end
    local wait = math.max(0, math.min(SETTLE_MS, firstAt + CAP_MS - GetGameTimer()))
    timer = SetTimeout(wait, function()
        timer = nil
        if printed then return end
        printed = true
        if printReport() == 0 then printLoaded() end
    end)
end)

-- Again, from the server console only.
RegisterCommand('whipsetup', function(source)
    if source ~= 0 then return end
    if not CoreReady then
        print('[whip] whip_core has not finished starting: the lines above say why')
        return
    end
    printReport()
end, true)

-- ============================================
-- whiperrors, whipsupport: what went wrong, by resource
-- ============================================
--
-- whip keeps the last errors on each side, filed under the resource they came from (shared/error_tap.lua). These two
-- print the server's, so a server owner can tell whip's fault from a resource's, and send a seller the lot.

--- The server's error log, grouped by resource: each with its count and its latest lines.
---@param only string|nil  one resource's
---@param perResource integer  lines shown for each
local function printErrors(only, perResource)
    local logged = ErrorTap.read({ max = 200 })
    local by, order = {}, {}
    for _, e in ipairs(logged and logged.entries or {}) do
        local res = tostring(e.resource or '?')
        if not only or res == only then
            if not by[res] then by[res] = {}; order[#order + 1] = res end
            table.insert(by[res], e)
        end
    end
    if #order == 0 then
        print(only and ('[whip] no errors from %s on the server'):format(only) or '[whip] no errors on the server')
        return
    end
    table.sort(order, function(a, b) return #by[a] > #by[b] end)
    for _, res in ipairs(order) do
        local list, total = by[res], 0
        for _, e in ipairs(list) do total = total + (e.count or 1) end
        print(('[whip] ^1%s^0: %d error%s'):format(res, total, total == 1 and '' or 's'))
        for i = math.max(1, #list - perResource + 1), #list do
            local e = list[i]
            local text = tostring(e.text):gsub('\n.*', '')   -- the first line; the console has the rest
            print(('[whip]     %s%s'):format(text:sub(1, 300), (e.count or 1) > 1 and (' (x%d)'):format(e.count) or ''))
        end
    end
end

-- /w → Resources (tools/resources_page.lua): the server's half, per resource. What it registered (a count per
-- registry), its latest errors, and its refusals. Developer mode only.
SecureCallback('whip_core:devtools:resources', {
    rateLimit = 1000,
    whileDead = true,
}, function(source)
    if not DevTools.isAllowed(source) then return false, 'Turn developer mode on (/w)' end
    local regs, errors, refused = {}, {}, {}
    for _, r in ipairs(Registry.list()) do
        local owner = tostring(r.owner)
        regs[owner] = regs[owner] or {}
        regs[owner][r.registry] = (regs[owner][r.registry] or 0) + 1
    end
    for _, e in ipairs((ErrorTap.read({ max = 200 }) or {}).entries or {}) do
        local owner = tostring(e.resource or '?')
        local list = errors[owner] or {}
        errors[owner] = list
        list[#list + 1] = { text = (tostring(e.text):gsub('\n.*', '')):sub(1, 200), count = e.count or 1 }
        if #list > 5 then table.remove(list, 1) end
    end
    for _, r in ipairs(Registry.refusals()) do
        local list = refused[r.owner] or {}
        refused[r.owner] = list
        if #list < 10 then list[#list + 1] = r.why:sub(1, 200) end
    end
    return { regs = regs, errors = errors, refused = refused }
end)

-- whiperrors [resource]: the server console only.
RegisterCommand('whiperrors', function(source, args)
    if source ~= 0 then return end
    printErrors(args[1], 5)
end, true)

-- whipsupport: everything a seller needs in one block to paste: the setup report (versions, what is missing, what
-- fights whip) and the server's recent errors by resource. The server console only.
RegisterCommand('whipsupport', function(source)
    if source ~= 0 then return end
    print('[whip] ====== copy from here: whip support report ======')
    print(('[whip] server: %s'):format(GetConvar('version', '?')))
    if CoreReady then printReport() else print('[whip] whip_core has not finished starting') end
    printErrors(nil, 3)
    print('[whip] ====== to here =================================')
end, true)
