-- ============================================
-- Systems — switched-on systems on the server: lifecycle, the dispatcher, the commands
-- ============================================
--
-- The lifecycle:
--   on        an admin (or the boot, for one that was on) switches a revision on: its document is read
--             and compiled, its POWERS must be approved for that revision, what it remembers is
--             read, and the walker starts it with a new GENERATION and a fresh tag
--             `system:<short id>:<generation>` (a released tag cannot be reused)
--   swap      switching on another revision is off, then on: a pulse in the middle is cancelled and
--             its payments refunded (the walker's receipts), never kept
--   off       every pulse is cancelled, its tag released for every owner (Registry.releaseTagEverywhere)
--   faulted   the walker switched it off (too many errors): stored with the reason, so it stays off
--             across a restart until an admin switches it on; online admins are told
--   whip_core stopping: every system is switched off (CoreStop); a system that was on is still on in
--             the store, so the next start brings it back
--
-- The dispatcher: whip's moments reach systems from core's OWN hooks (Character.onLife,
-- Vehicles.onLife, Zones.onTrack), never public events a resource could fire. Each says the depth of
-- the card running when it fired (R.currentDepth), so a system that sets itself off is a loop.
--
-- The commands: /systems alone opens the editor (server/systems/hub.lua, client/systems_editor.lua);
-- /systems <command> works from the console too: the shipped examples (server/systems/examples/<name>.json)
-- and a way to switch any system off when an editor cannot. systems.admin (and whip.devtools) for
-- everything that changes the world; systems.build to read the list and the log.

Systems = { off = nil, active = {}, tests = {} }   -- tests: [src] = the editor's Test (server/systems/hub.lua)

local R = SystemsRuntime
local CORE = GetCurrentResourceName()

local function say(fmt, ...) print(('[whip_core:systems] ' .. fmt):format(...)) end

-- ============================================
-- Permissions
-- ============================================

Permissions.register(CORE, 'systems.build', {
    label = 'Systems builder',
    description = 'See every system and its log; make, edit and test systems',
    grantedBy = 'systems.admin',
})
Permissions.register(CORE, 'systems.admin', {
    label = 'Systems admin',
    description = 'A builder who can also switch systems on and off, and approve what they may do (money, items)',
    implies = { 'systems.build' },
    grantedBy = 'systems.admin',
})

local function may(src, perm) return src == 0 or Permissions.has(src, perm) end

-- ============================================
-- The walker's Ports
-- ============================================

--- A player value for a server id: { source, session }, or nil (not on a character).
local function playerValue(src)
    local p = src and Players[src]
    if not p or not p.charId or p.closing then return nil end
    return { source = src, session = p.session }
end
Systems.playerValue = playerValue

local function pass()
    local ok, res = pcall(R.pass)
    if not ok then say('^1the scheduler pass failed: %s^0', tostring(res)) return 1000 end
    return res
end

-- Two ways a pass runs, as the Director's: the loop (below), and at once when work arrives (wake). A
-- woken pass's answer (a timer due in 300 ms) is kept too: past the loop's own next pass it waits for
-- that, sooner it gets a pass of its own. The loop sleeps up to a second (walk.lua IDLE_MS).
local loopDue = 0
local function loopPass()
    local ms = pass()
    loopDue = GetGameTimer() + ms
    return ms
end
local function wokenPass()
    local ms = pass()
    if GetGameTimer() + ms < loopDue then SetTimeout(ms, wokenPass) end
end

--- What each running instance made per player (a tag of its own): released at that player's logout.
local playerTags = {}   -- [src] = { [tag] = true }

R.setPorts({
    wake = function() SetTimeout(0, wokenPass) end,
    session = function(src)
        local p = Players[src]
        if not p or not p.charId or p.closing then return nil end
        return p.session
    end,
    -- nil unless the value is from the player's CURRENT session (walk.lua's Port contract).
    charOf = function(pv)
        local p = type(pv) == 'table' and Players[pv.source] or nil
        if not p or not p.charId or p.closing or p.session ~= pv.session then return nil end
        return p.charId
    end,
    players = function()
        local out = {}
        for src in pairs(Players) do
            local pv = playerValue(src)
            if pv then out[#out + 1] = pv end
        end
        table.sort(out, function(a, b) return a.source < b.source end)
        return out
    end,
    remember = function(inst, _, key, name, value)
        local id = inst.meta and inst.meta.systemId
        if not id or inst.test then return end
        local ok, why = SystemStore.rememberValue(id, key, name, value)
        if not ok then say('%s: %s could not be remembered: %s', inst.key, name, tostring(why)) end
    end,
    onStop = function(inst, outcome, why)
        if inst.tag then Registry.releaseTagEverywhere(inst.tag) end
        for _, tags in pairs(playerTags) do
            for tag in pairs(tags) do
                if tag:sub(1, #inst.tag + 1) == inst.tag .. ':' then Registry.releaseTagEverywhere(tag); tags[tag] = nil end
            end
        end
        local entry = Systems.active[inst.key]
        if entry and entry.inst == inst then Systems.active[inst.key] = nil end
        -- A Test's end is its editor's to say (server/systems/hub.lua), never stored. What it handed out
        -- goes back (test_items.lua: stopped, F5, a new Test, a fault: every end comes through here).
        if inst.test then
            if SystemsTestItems then SystemsTestItems.testEnded(inst.tag, inst.only) end
            if Systems.testStopped then Systems.testStopped(inst, outcome, why) end
            return
        end
        if outcome == 'faulted' then
            -- Stored, so it stays off until an admin switches it on again; admins online are told.
            CreateThread(function() SystemStore.setStatus(inst.key, 'faulted', nil, why, nil) end)
            for src in pairs(Players) do
                if Permissions.has(src, 'systems.admin') then
                    NotifyPlayer(src, ('System %s switched itself off: %s'):format(tostring(inst.meta.name or inst.key), tostring(why)), 'error', 10000)
                end
            end
            say('^1%s switched itself off: %s^0', inst.key, tostring(why))
        end
    end,
})

Every('systems', 1000, loopPass)

--- A tag of a system's own for things it makes for one player: released at that player's logout (and
--- with the system's, at switch-off). `inst` is the instance, or its tag (a card's ctx:tag()).
function Systems.tagFor(inst, src)
    local p = Players[src]
    local base = type(inst) == 'table' and inst.tag or inst
    if type(base) ~= 'string' or base == '' or not p then return nil end
    local tag = ('%s:%s'):format(base, tostring(p.session))
    local tags = playerTags[src]
    if not tags then tags = {}; playerTags[src] = tags end
    tags[tag] = true
    return tag
end

-- ============================================
-- Switching on and off
-- ============================================

local genSeq = os.time() * 1000   -- from the clock, never 1 again after a restart (session ids' rule)

--- A new generation (a switch-on, or an editor's Test): never one handed out before.
function Systems.nextGen()
    genSeq = genSeq + 1
    return genSeq
end

--- What a switched-on instance's cards keep STANDING while it is on (a Point Used card's prompt):
--- made now under its tag, so switching it off (Ports.onStop: releaseTagEverywhere) takes them away.
--- Each card's `standing(api)` is handed:
---   props    its fields, defaults filled in
---   tag      the instance's tag: what it makes carries it
---   test     true for an editor's Test; `tester` then says whose (what it makes is for them alone)
---   isTesting   isTesting(src): is this player testing a draft of this system (the live copy leaves
---            them be: a point can say so instead of doing nothing)
---   emit     emit(name, payload): its moment, to its own trigger (the payload says which instance and
---            card, so another system's card, or another copy of this one, never hears it)
---   meta     { shortId, owner }: what C.name builds a system's names from
---   listening   listening(): is this copy on and hearing its trigger (a use of its item can say so)
function Systems.makeStanding(inst)
    for nodeId, node in pairs(inst.graph.nodes) do
        local def = node.def
        if def.standing then
            local id, key = inst.id, inst.key
            local m = inst.meta or {}
            local api = {
                props = SystemCards.withDefaults(def, node.props), tag = inst.tag, test = inst.test, tester = inst.only,
                meta = { shortId = m.shortId, owner = m.owner },
                listening = function() return inst.status == 'on' end,
                isTesting = function(src) return R.isTesting(key, src) end,
                emit = function(name, payload)
                    payload = type(payload) == 'table' and payload or {}
                    payload.inst, payload.node = id, nodeId
                    R.emit(name, payload, { depth = R.currentDepth() })
                end,
            }
            local ok, err = pcall(def.standing, api)
            if not ok then
                R.note(inst, 'error', nodeId, 'it could not be put in the world: ' .. tostring(err))
            elseif type(err) == 'string' then
                R.note(inst, 'warn', nodeId, err)   -- standing() said why it put nothing up
            end
        end
    end
end

--- Do a revision's powers have an admin's approval FOR THAT REVISION? `needed` is every power its
--- cards have: as saved, and as its cards say now (a card that gained a power in an
--- update would otherwise run unapproved).
local function approved(needed, approvedPowers)
    if needed == '' then return true end
    local ok = {}
    for p in tostring(approvedPowers or ''):gmatch('[^,]+') do ok[p] = true end
    for p in needed:gmatch('[^,]+') do if not ok[p] then return false end end
    return true
end

--- Two power lists ('items,money') as one, sorted, no repeats.
local function powersUnion(a, b)
    local set, list = {}, {}
    for _, s in ipairs({ a or '', b or '' }) do for p in s:gmatch('[^,]+') do set[p] = true end end
    for p in pairs(set) do list[#list + 1] = p end
    table.sort(list)
    return table.concat(list, ',')
end

--- Switch a stored system on at `rev` (default: the revision that was on, else its draft). WAITS (it
--- reads the revision and what it remembers). Answers true, or false and why.
---@param by number|nil  the player switching it (nil: the server, at boot)
function Systems.switchOn(key, rev, by)
    if Systems.off then return false, 'the Systems Creator is off: ' .. Systems.off end
    local row = SystemStore.get(key)
    if not row then return false, 'no system called ' .. tostring(key) end
    local doc, gotRev, powers, approvedPowers = SystemStore.revision(key, rev or row.activeRev or row.draftRev)
    if not doc then return false, gotRev or 'that revision cannot be read' end
    local needed = powersUnion(powers, SystemStore.powersOf(doc))
    if not approved(needed, approvedPowers) then
        return false, ('revision %d may move %s: a systems admin approves it first (/systems approve %s)'):format(gotRev, needed:gsub(',', ' and '), key)
    end
    local graph, problems = SystemGraph.compile(doc, 'server')
    if not graph then
        local first
        for _, p in ipairs(problems or {}) do if p.severity == 'error' then first = first or ((p.node and ('card ' .. p.node .. ': ') or '') .. p.message) end end
        return false, 'its check failed: ' .. tostring(first)
    end
    local state, swhy = SystemStore.loadState(row.id)
    if not state then return false, 'what it remembers could not be read: ' .. tostring(swhy) end
    -- AFTER THE WAITS, ASKED AGAIN (house rule): switched by someone else meanwhile?
    local now = SystemStore.get(key)
    if not now then return false, 'it was deleted meanwhile' end
    local prev = Systems.active[key]
    if prev then R.stop(prev.inst.id, 'switched on again at revision ' .. gotRev) end
    local gen = Systems.nextGen()
    local inst = R.start(graph, {
        key = key, gen = gen, tag = ('system:%s:%d'):format(row.shortId, gen), vars = state,
        meta = { systemId = row.id, shortId = row.shortId, name = doc.name or row.name, rev = gotRev, owner = 'system:' .. row.shortId },
        -- Its cards light in the editor of whoever has it open (server/systems/hub.lua; free when nobody does).
        onTrace = function(e, i) if Systems.livePulse then Systems.livePulse(i, e) end end,
    })
    Systems.active[key] = { inst = inst, rev = gotRev }
    Systems.makeStanding(inst)
    local okS, sw = SystemStore.setStatus(key, 'on', gotRev, nil, by)
    if not okS then say('^3%s is on, but the store could not say so: %s^0', key, tostring(sw)) end
    say('%s is on at revision %d', key, gotRev)
    return true
end

--- Switch a system off (an admin). Answers true, or false and why.
function Systems.switchOff(key, why, by)
    local entry = Systems.active[key]
    if entry then R.stop(entry.inst.id, why or 'switched off') end
    Systems.active[key] = nil
    local row = SystemStore.get(key)
    if not row then return entry ~= nil, entry == nil and ('no system called ' .. tostring(key)) or nil end
    return SystemStore.setStatus(key, 'off', nil, why, by)
end

CoreStop.add(5, 'systems: switch them off', function() R.stopAll('whip_core stopping') end)

-- ============================================
-- The dispatcher: core's hooks to the systems
-- ============================================

local function emit(name, payload)
    -- Nothing on and nothing being tested: nobody listens (a Test runs with no system on).
    if not next(Systems.active) and not next(Systems.tests) then return end
    R.emit(name, payload, { depth = R.currentDepth() })
end

Character.onLife('loaded', function(e)
    local pv = e and playerValue(e.source)
    if pv then emit('player.joined', { player = pv, name = Players[e.source] and Players[e.source].fullName or e.name }) end
end)

--- A player who is LEAVING (logging out, dropping): still told of as who they were, so "gets out of a
--- car" and "leaves an area" happen on the way out. Nothing can be done to them (ctx:source refuses a
--- session that is closing).
local function leavingValue(src)
    local p = src and Players[src]
    if not p or not p.session then return nil end
    return { source = src, session = p.session }
end

Character.onLife('logout', function(e)
    if not (e and e.source) then return end
    local p = e.player or Players[e.source]
    -- Gone from every system FIRST (their pulses going now are cancelled, payments refunded), then
    -- "When a player leaves": a pulse started after the leave is not cancelled by it.
    R.playerGone(e.source, e.charId or (p and p.charId))
    if p and p.session then emit('player.left', { player = { source = e.source, session = p.session }, why = e.why or 'logout' }) end
    for tag in pairs(playerTags[e.source] or {}) do Registry.releaseTagEverywhere(tag) end
    playerTags[e.source] = nil
end)

for kind, name in pairs({ entered = 'vehicle.entered', exited = 'vehicle.exited' }) do
    Vehicles.onLife(kind, function(e)
        if type(e) ~= 'table' then return end
        local pv = playerValue(e.source) or (kind == 'exited' and leavingValue(e.source)) or nil
        if pv then emit(name, { player = pv, vehicle = e.vehicleId, seat = e.seat, plate = e.plate }) end
    end)
end

-- Gone for good: its per-car values go (nothing is REMEMBERED per car: compile.lua refuses it).
for _, kind in ipairs({ 'deleted', 'released' }) do
    Vehicles.onLife(kind, function(e)
        local id = type(e) == 'table' and e.vehicleId
        if id then R.vehicleGone(id) end
    end)
end

Zones.onTrack(function(kind, p)
    if type(p) ~= 'table' then return end
    local pv = playerValue(p.source) or (kind == 'exited' and leavingValue(p.source)) or nil
    if pv then emit(kind == 'entered' and 'area.entered' or 'area.left', { player = pv, zoneId = p.zoneId, key = p.key }) end
end)

-- DOWN AND UP AGAIN (Character.onLife 'died' / 'revived'). The killer is the server's own finding.
Character.onLife('died', function(e)
    local pv = type(e) == 'table' and playerValue(e.source)
    if pv then emit('player.down', { player = pv, killer = e.killer and playerValue(e.killer) or nil }) end
end)
Character.onLife('revived', function(e)
    local pv = type(e) == 'table' and playerValue(e.source)
    if pv then emit('player.revived', { player = pv, how = e.how }) end
end)

-- HURT: their health went DOWN (Stats.onChange: every set, and the vitals report combat damage comes
-- by). Heard in combat many times a second, so nothing is done unless a system listens.
Stats.onChange('health', 'systems', function(e)
    if type(e) ~= 'table' or not R.listening('player.hurt') then return end
    local v, old = tonumber(e.value), tonumber(e.old)
    if not v or not old or v >= old then return end
    local pv = playerValue(e.source)
    if pv then emit('player.hurt', { player = pv, health = v, lost = old - v }) end
end)

-- AN NPC killed or hurt (Npcs.onLife): whip_core's own (a system's are; each card hears only its
-- own system's, by the tag). The killer or attacker is the server's own finding.
for kind, name in pairs({ killed = 'npc.killed', damaged = 'npc.damaged' }) do
    Npcs.onLife(kind, function(e)
        if type(e) ~= 'table' or e.owner ~= 'whip_core' or not R.listening(name) then return end
        local by = kind == 'killed' and e.killer or e.attacker
        emit(name, { npc = e.npcId, tag = e.tag, player = by and playerValue(by) or nil })
    end)
end

-- THE ENGINE: the vehicle stat `engine` (1 running, 0 off), which the server sets only for a driver
-- with the key in the ignition (vehicle_stats.lua). With its driver, when it has one.
VehicleStats.onChange('engine', 'systems', function(e)
    if type(e) ~= 'table' or not e.vehicleId or not R.listening('car.engine') then return end
    local on = tonumber(e.value) == 1
    if on == (tonumber(e.old) == 1) then return end
    local driver
    local ent = Vehicles.getEntity(e.vehicleId)
    local ped = ent and GetPedInVehicleSeat(ent, -1)
    if ped and ped ~= 0 then
        for src in pairs(Players) do
            if GetPlayerPed(src) == ped then driver = playerValue(src) break end
        end
    end
    emit('car.engine', { vehicle = e.vehicleId, on = on, player = driver })
end)

-- The line watcher: "When a car crosses a line" (a speed camera). Four times a second, only while a
-- system listens: every driven car's last two positions as the server has them (from the driver's own
-- sync). A server zone is swept once a second, about 50 m at 180 km/h, so a camera is a line.
--   THE SPEED is the car's own (GetEntitySpeed, what /sysspeed shows), not distance over time: the
--   server's position only moves when the driver's sync arrives, so a gap made the distance of two
--   samples look like one (100 km/h read as 300 at a high ping).
--   A SAMPLE THAT DID NOT MOVE is not kept, so the next one measures from the last real position.
--   The distance over time only says whether it was a TELEPORT (no line is crossed by one).
local lastAt = {}   -- [src] = { x, y, z, t, ent }
Every('systems lines', 250, function()
    if not R.listening('car.moved') then
        if next(lastAt) then lastAt = {} end
        return 5000   -- a camera switched on starts being watched within this
    end
    local now = GetGameTimer()
    local seen = {}
    for src in pairs(Players) do
        local pv = playerValue(src)
        local ped = pv and GetPlayerPed(src)
        local ent = ped and ped ~= 0 and GetVehiclePedIsIn(ped, false) or 0
        if ent ~= 0 and GetPedInVehicleSeat(ent, -1) == ped then
            seen[src] = true
            local c = GetEntityCoords(ent)
            local last = lastAt[src]
            local moved = true
            -- A sample over a second old is a fresh start, not one stretch of driving: a car that sat
            -- still (or was moved by a script) and is now somewhere else crossed nothing on the way.
            if last and now - last.t > 1000 then last = nil end
            if last and last.ent == ent and now > last.t then
                local dx, dy, dz = c.x - last.x, c.y - last.y, c.z - last.z
                local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
                moved = dist > 0.05
                local overall = dist / ((now - last.t) / 1000) * 3.6
                if moved and overall < 600 then
                    emit('car.moved', { player = pv, ent = ent, kmh = (GetEntitySpeed(ent) or 0) * 3.6,
                        from = { x = last.x, y = last.y }, to = { x = c.x, y = c.y } })
                end
            end
            if moved then lastAt[src] = { x = c.x, y = c.y, z = c.z, t = now, ent = ent } end
        end
    end
    for src in pairs(lastAt) do if not seen[src] then lastAt[src] = nil end end
    return 250
end)

-- ============================================
-- Boot
-- ============================================

CoreStart.add('the Systems Creator', function()
    if not SystemStore.ensureTables() then
        Systems.off = 'its tables could not be made'
        say('^1the Systems Creator is off: %s^0', Systems.off)
        return
    end
    local ok, why = SystemStore.loadAll()
    if not ok then
        Systems.off = 'its systems could not be read: ' .. tostring(why)
        say('^1the Systems Creator is off: %s^0', Systems.off)
        return
    end
    for _, s in ipairs(SystemStore.list()) do
        if s.status == 'on' then
            local okOn, res = Systems.switchOn(s.key, s.activeRev, nil)
            if not okOn then say('^3system %s did not come back on: %s^0', s.key, tostring(res)) end
        end
    end
end)

-- ============================================
-- /systems
-- ============================================
--
--   /systems list                  every system, on or off, and why
--   /systems spot <name>           where you stand is that spot (an example's "spot:<name>" places)
--   /systems load <example>        server/systems/examples/<example>.json into the store (a new system,
--                                  or a new revision of it), its powers approved, switched on (admin)
--   /systems approve <key>         its draft's powers (money, items) approved, so it may be switched on
--   /systems on <key> [rev]        switched on (admin); stays on across restarts
--   /systems off <key>             switched off (admin); the console works too, if an editor ever cannot
--   /systems log <key>             its last lines (builders)
--   /sysspeed                      ten seconds of what the server sees of your car's speed (dev): to set
--                                  beside your HUD's, at your ping, before trusting Car Speed

local spots = {}

local function reply(src, msg, kind)
    if src == 0 then say('%s', msg) else NotifyPlayer(src, msg, kind or 'info', 8000) end
end

--- An example's document with its "spot:<name>" places filled from /systems spot.
local function readExample(name)
    if type(name) ~= 'string' or not name:match('^[%w_%-]+$') then return nil, 'an example name is letters, digits, _ and -' end
    local raw = LoadResourceFile(CORE, ('server/systems/examples/%s.json'):format(name))
    if not raw then return nil, 'no example called ' .. name end
    local ok, doc = pcall(json.decode, raw)
    if not ok or type(doc) ~= 'table' then return nil, name .. '.json cannot be read' end
    for _, n in ipairs(type(doc.nodes) == 'table' and doc.nodes or {}) do
        for k, v in pairs(type(n.props) == 'table' and n.props or {}) do
            if type(v) == 'string' and v:match('^spot:') then
                local s = spots[v:sub(6)]
                if not s then return nil, ('stand where "%s" goes and type /systems spot %s first'):format(v:sub(6), v:sub(6)) end
                n.props[k] = { x = s.x, y = s.y, z = s.z }
            end
        end
    end
    return doc
end

local function list(src)
    local rows = SystemStore.list()
    if #rows == 0 then return reply(src, 'No systems yet: /systems load speedcam') end
    for _, s in ipairs(rows) do
        local live = Systems.active[s.key]
        local line = ('%s "%s": %s%s, draft r%d%s'):format(s.key, s.name, live and ('ON r' .. live.rev) or s.status,
            s.reason and (' (' .. s.reason .. ')') or '', s.draftRev, s.approvedRev and (', approved r' .. s.approvedRev .. ' for ' .. tostring(s.approvedPowers)) or '')
        say('%s', line)
        if src ~= 0 then NotifyPlayer(src, line, 'info', 8000) end
    end
end

RegisterCommand('systems', function(src, args)
    local sub, a = args[1], args[2]
    if not may(src, 'systems.build') then return end
    -- /systems alone: the Systems Creator's own screen (client/systems_editor.lua), for its builders. An
    -- experimental feature: only while it is on (Config.Experimental, /whip → Settings → Experimental features).
    if sub == nil and src ~= 0 then
        if not (type(Config.Experimental) == 'table' and Config.Experimental.systemsCreator == true) then
            -- Short: the HUD capsule shows one line (about 45 letters), and the whole of the old sentence ended in "…"
            return reply(src, 'Systems Creator is off: Settings → Experimental')
        end
        TriggerClientEvent('whip_core:client:systemsOpen', src)
        return
    end
    if sub == nil or sub == 'help' then
        return reply(src, '/systems list | spot <name> | load <example> | approve <key> | on <key> [rev] | off <key> | log <key>')
    end
    if sub == 'list' then return list(src) end
    if sub == 'log' and a then
        local entry = Systems.active[a]
        if not entry then return reply(src, a .. ' is not on', 'error') end
        local rep = R.report(entry.inst)
        for i = math.max(1, #rep.log - 19), #rep.log do
            local l = rep.log[i]
            say('%s [%s] %s%s', a, l.level, l.node and ('card ' .. l.node .. ': ') or '', l.msg)
        end
        return reply(src, ('%s: %d pulses going, %d errors in the last minute, dropped %d (busy) %d (budget) — the log is in the server console')
            :format(a, rep.pulses, rep.lastMinute.errors, rep.dropped.busy, rep.dropped.budget))
    end
    -- Everything below changes the world: admins.
    if not may(src, 'systems.admin') then return reply(src, 'Systems admins only', 'error') end
    if Systems.off then return reply(src, 'The Systems Creator is off: ' .. Systems.off, 'error') end
    if not SystemStore.ready then return reply(src, 'The Systems Creator is still starting: try again in a moment', 'error') end
    if sub == 'spot' and a and src ~= 0 then
        if not a:match('^[%w_%-]+$') then return reply(src, 'a spot name is letters, digits, _ and -', 'error') end
        local c = GetEntityCoords(GetPlayerPed(src))
        spots[a] = { x = c.x, y = c.y, z = c.z }
        return reply(src, ('Spot "%s" is here'):format(a), 'success')
    elseif sub == 'load' and a then
        CreateThread(function()
            local doc, why = readExample(a)
            if not doc then return reply(src, why, 'error') end
            local graph, problems = SystemGraph.compile(doc, 'server')
            if not graph then
                for _, p in ipairs(problems or {}) do
                    if p.severity == 'error' then say('%s: %s%s', a, p.node and ('card ' .. p.node .. ': ') or '', p.message) end
                end
                return reply(src, a .. ' did not pass its check: see the server console', 'error')
            end
            local by = src ~= 0 and src or nil
            local row = SystemStore.get(a)
            local rev
            if row then
                local saved, swhy = SystemStore.save(a, row.draftRev, doc, by, 'loaded from the example file')
                if not saved then return reply(src, swhy, 'error') end
                rev = saved
            else
                local made, cwhy = SystemStore.create(a, doc.name or a, doc, by)
                if not made then return reply(src, cwhy, 'error') end
                rev = made.draftRev
            end
            -- Loading an example is an admin choosing it: its powers are approved for this revision.
            local powers = SystemStore.powersOf(doc)
            if powers ~= '' then SystemStore.approve(a, rev, powers, by) end
            local ok, owhy = Systems.switchOn(a, rev, by)
            reply(src, ok and (('%s is on at revision %d%s'):format(a, rev, powers ~= '' and (' (it may move ' .. powers:gsub(',', ' and ') .. ')') or ''))
                or tostring(owhy), ok and 'success' or 'error')
        end)
    elseif sub == 'approve' and a then
        CreateThread(function()
            local row = SystemStore.get(a)
            if not row then return reply(src, 'no system called ' .. a, 'error') end
            local doc, rev, powers = SystemStore.revision(a, row.draftRev)
            if not doc then return reply(src, tostring(rev), 'error') end
            local ok, why = SystemStore.approve(a, rev, powers, src ~= 0 and src or nil)
            reply(src, ok and (('%s revision %d approved%s'):format(a, rev, powers ~= '' and (' to move ' .. powers:gsub(',', ' and ')) or ' (it moves nothing)')) or tostring(why),
                ok and 'success' or 'error')
        end)
    elseif sub == 'on' and a then
        CreateThread(function()
            local ok, why = Systems.switchOn(a, tonumber(args[3]), src ~= 0 and src or nil)
            reply(src, ok and (a .. ' is on') or tostring(why), ok and 'success' or 'error')
        end)
    elseif sub == 'off' and a then
        CreateThread(function()
            local ok, why = Systems.switchOff(a, 'switched off by an admin', src ~= 0 and src or nil)
            reply(src, ok and (a .. ' is off') or tostring(why), ok and 'success' or 'error')
        end)
    else
        reply(src, '/systems list | spot <name> | load <example> | approve <key> | on <key> [rev] | off <key> | log <key>', 'error')
    end
end, false)
