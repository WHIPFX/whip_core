-- ============================================
-- Director — takes: a car's recorded drives
-- ============================================
--
-- A TAKE is a drive recorded in the Director (its car's page: Record a take; client/director_takes.lua),
-- frame by frame as shared/take_track.lua keeps it, and played back exactly when a run plays it (Play Take, or
-- a car's Play a Take task): speed, steering, wheels, brakes, lights, horn, siren, a crash.
--
--   kept      in director_takes (server/director/store.lua), beside the scenario: the car's def.takes names
--             each by id ({ id, label, ms, made }). A take taken off a car stays in the table (an older
--             revision may still name it) until no scenario's draft or switched-on revision names it and it is
--             older than the run history: then it goes at a boot (DirectorTakes.prune)
--   saved     from the builder's game, as a latent event (whip_core:server:takeSave), packed (TakeTrack.pack): a
--             builder's only, checked (TakeTrack.check) and written before its id is given back; one per drive
--             (its token), however many times Save is pressed
--   cached    once read, here: a run loads its scenario's takes as it starts (DirectorTakes.preload), so a card
--             that plays one never waits for the database
--   sent      to the game that plays it, when that game asks (whip_core:server:takeWant: every one it is missing,
--             in one ask), as latent events off that game's line, a few at a time, none dropped (To the game that
--             plays one, below); that game says it has it only once it does (server/actors.lua's ack). Only a take
--             in use (a car of a run going now, or of a scenario that is on, names it) unless the asker is a builder
--             (the editor's other cars, a take being looked at)
--   older     a take saved in format 2 is read as format 3 (TakeTrack.upgrade): its row is left as it is
--   let go    from the cache CACHE_IDLE_MS after it was last wanted, when nothing in use names it (a sweep)

DirectorTakes = {}

local MAX_KEYS   = 20000        -- samples in one take, at most (three minutes of crashing at 100 fps)
local MAX_MS     = 4 * 60 * 1000
local SEND_BPS   = 500000
local CACHE_IDLE_MS = 10 * 60 * 1000
local cache = {}                -- [id] = { id, samples, lengthMs, model, start = { x, y, z, heading }, packed?, usedAt }
local loading = {}              -- [id] = true while it is read

--- Every take id a car's takes name: each take's, and its trailers' own tracks (its `tow`: client/director_takes.lua).
local function idsOfCar(w, into)
    if not (type(w) == 'table' and w.kind == 'vehicle' and type(w.def) == 'table' and type(w.def.takes) == 'table') then return end
    for _, t in ipairs(w.def.takes) do
        local id = type(t) == 'table' and math.tointeger(tonumber(t.id)) or nil
        if id then into[id] = true end
        local tracks = type(t) == 'table' and type(t.tow) == 'table' and type(t.tow.tracks) == 'table' and t.tow.tracks or nil
        for _, tid in pairs(tracks or {}) do
            tid = math.tointeger(tonumber(tid))
            if tid then into[tid] = true end
        end
    end
end

--- The take ids a graph's cars name: { [id] = true }, worked out once a graph (a revision never changes).
local function namedBy(graph)
    if type(graph) ~= 'table' then return {} end
    if graph.takeIds then return graph.takeIds end
    local ids = {}
    for _, w in pairs(graph.world or {}) do idsOfCar(w, ids) end
    graph.takeIds = ids
    return ids
end

--- Is take `id` one of this car's own now (its page's Scripted Driving Events)? One removed from the car is never
--- played, though its row is kept (an older revision may still name it).
function DirectorTakes.onCar(w, id)
    id = math.tointeger(tonumber(id))
    if not id or type(w) ~= 'table' or type(w.def) ~= 'table' or type(w.def.takes) ~= 'table' then return false end
    for _, t in ipairs(w.def.takes) do
        if type(t) == 'table' and math.tointeger(tonumber(t.id)) == id then return true end
    end
    return false
end

--- Is this take in use: named by a car of a run going now, or of a scenario that is on (any of its variants)?
local function inUse(id)
    for _, run in ipairs(DirectorRuntime.list()) do
        if namedBy(run.graph)[id] then return true end
    end
    for _, sc in pairs(Director.active or {}) do
        if namedBy(sc.graph)[id] then return true end
        for _, v in ipairs(sc.variants or {}) do
            if namedBy(v.graph)[id] then return true end
        end
    end
    return false
end

local q = DirectorKit.query

--- Every take id a scenario document names (each variant's cars, their trailers' tracks), into `into`.
function DirectorTakes.idsOfDoc(doc, into)
    for _, v in ipairs(type(doc) == 'table' and DirectorGraph.variantsOf(doc) or {}) do
        for _, w in ipairs(type(v.doc.world) == 'table' and v.doc.world or {}) do idsOfCar(w, into) end
    end
    return into
end

--- TAKES NOBODY NAMES GO, at boot (DirectorStore.loadAll): one named by no scenario's draft or switched-on revision
--- (`keep`), older than `days` (the run history's time), is deleted. An older revision brought back from History may
--- have named one: its card then plays without it, and says so (its driving event is gone). Waits: a thread.
---@param keep table  { [id] = true }
---@param days integer
function DirectorTakes.prune(keep, days)
    local rows, err = q(('SELECT `id` FROM `director_takes` WHERE `createdAt` < NOW() - INTERVAL %d DAY'):format(math.floor(days)))
    if not rows then print(('[whip_core:director] old takes could not be read: %s'):format(tostring(err))) return end
    local gone = {}
    for _, r in ipairs(rows) do
        local id = math.tointeger(tonumber(r.id))
        if id and not keep[id] then gone[#gone + 1] = id end
    end
    local n = 0
    for i = 1, #gone, 200 do
        local part = table.move(gone, i, math.min(#gone, i + 199), 1, {})
        local _, derr = q('DELETE FROM `director_takes` WHERE `id` IN (' .. string.rep('?', #part, ',') .. ')', part)
        if derr then print(('[whip_core:director] old takes could not be deleted: %s'):format(tostring(derr))) break end
        for _, id in ipairs(part) do cache[id] = nil end
        n = n + #part
    end
    if n > 0 then print(('[whip_core:director] %d recorded drive(s) no scenario names any more, older than %d days: deleted'):format(n, days)) end
end

--- Where a take starts: its first sample's spot and heading.
local function startOf(samples)
    local qx, qy, qz, qw = samples[5], samples[6], samples[7], samples[8]
    return { x = samples[2], y = samples[3], z = samples[4], heading = TakeTrack.heading(qx, qy, qz, qw) }
end

local function remember(id, samples, model)
    local t = { id = id, samples = samples, lengthMs = TakeTrack.length(samples), model = model, start = startOf(samples),
                usedAt = GetGameTimer() }
    cache[id] = t
    return t
end

--- One take's row, checked and cached. One saved in an older format is read as today's (TakeTrack.upgrade: a format 2
--- take's wheels counted on and the drive thinned again, a third of the samples or so), a few hundred samples a
--- server frame; the row itself is left as it is.
local function read(id)
    local rows, err = q('SELECT `data`, `model` FROM `director_takes` WHERE `id` = ?', { id })
    if not rows then return nil, err end
    local row = rows[1]
    if not row then return nil, ('take %d is not in the database'):format(id) end
    local ok, data = pcall(json.decode, row.data)
    local samples = ok and type(data) == 'table' and data.samples or nil
    local good, why = TakeTrack.check(samples, MAX_KEYS)
    if not good then return nil, ('take %d: %s'):format(id, why) end
    samples = TakeTrack.upgrade(samples, data.format, function() Wait(0) end)
    return remember(id, samples, row.model)
end

--- A take, read from the database the first time (it waits: a thread or ctx:call), or nil and why.
function DirectorTakes.load(id)
    id = math.tointeger(tonumber(id))
    if not id then return nil, 'not a take' end
    if cache[id] then
        cache[id].usedAt = GetGameTimer()
        return cache[id]
    end
    if loading[id] then
        -- (Up to 15 s: an older long take is thinned again as it is read.)
        for _ = 1, 150 do
            Wait(100)
            if cache[id] then return cache[id] end
            if not loading[id] then break end
        end
        return cache[id], cache[id] == nil and 'it could not be read' or nil
    end
    loading[id] = true
    local t, why = read(id)
    loading[id] = nil
    return t, why
end

--- A take already read, or nil (never waits).
function DirectorTakes.get(id)
    id = math.tointeger(tonumber(id))
    local t = id and cache[id] or nil
    if t then t.usedAt = GetGameTimer() end
    return t
end

-- Takes nothing in use names, not wanted for CACHE_IDLE_MS, let go (a take of several MB each, read again if asked)
Every('director-takes', 60000, function()
    local now = GetGameTimer()
    for id, t in pairs(cache) do
        if now - (t.usedAt or 0) > CACHE_IDLE_MS and not inUse(id) then cache[id] = nil end
    end
    return 60000
end)

--- The takes a scenario's cars name, read in a thread of their own (a run starting: main.lua).
function DirectorTakes.preload(graph)
    local ids = {}
    for id in pairs(namedBy(graph)) do
        if not cache[id] then ids[#ids + 1] = id end
    end
    table.sort(ids)
    if #ids == 0 then return end
    CreateThread(function()
        for _, id in ipairs(ids) do
            local t, why = DirectorTakes.load(id)
            if not t then print(('[whip_core:director] a take could not be read: %s'):format(tostring(why))) end
        end
    end)
end

--- A take's drive as a line on a map (the /whip Scenarios page's): { x1, y1, x2, y2, ... }, where the car is every
--- 200 ms of it on the curve playback follows, a point under 1.5 m from the last one kept left out (a car standing
--- still is one point), 1500 points at most. Worked out once a take, and kept with it.
function DirectorTakes.path(take)
    if take.path then return take.path end
    local keys, K = take.samples, TakeTrack.STRIDE
    local n = #keys // K
    local len = take.lengthMs or TakeTrack.length(keys)
    local out, s, cur, t, lx, ly = {}, {}, 0, 0, nil, nil
    while true do
        cur = TakeTrack.at(keys, n, t, cur, s, K)
        local x, y = s[2], s[3]
        if not lx or (x - lx) * (x - lx) + (y - ly) * (y - ly) >= 2.25 or t >= len then
            out[#out + 1] = math.floor(x * 10 + 0.5) / 10
            out[#out + 1] = math.floor(y * 10 + 0.5) / 10
            lx, ly = x, y
            if #out >= 3000 then break end
        end
        if t >= len then break end
        t = math.min(len, t + 200)
    end
    take.path = out
    return out
end

--- A take's trailers, as its car's page keeps them (client/director_takes.lua): { tracks = { [trailer's world id] =
--- its own take }, events = { { t, w, on } } in order of t }, or nil. Read from the graph a run plays.
function DirectorTakes.towOf(graph, takeId)
    takeId = math.tointeger(tonumber(takeId))
    if not takeId or type(graph) ~= 'table' then return nil end
    for _, w in pairs(graph.world or {}) do
        if w.kind == 'vehicle' and type(w.def) == 'table' and type(w.def.takes) == 'table' then
            for _, t in ipairs(w.def.takes) do
                if type(t) == 'table' and math.tointeger(tonumber(t.id)) == takeId then
                    local tow = type(t.tow) == 'table' and t.tow or nil
                    if not tow or type(tow.tracks) ~= 'table' then return nil end
                    local tracks, events = {}, {}
                    for wid, tid in pairs(tow.tracks) do
                        tid = math.tointeger(tonumber(tid))
                        if type(wid) == 'string' and tid then tracks[wid] = tid end
                    end
                    for _, e in ipairs(type(tow.events) == 'table' and tow.events or {}) do
                        if type(e) == 'table' and tonumber(e.t) and type(e.w) == 'string' and tracks[e.w] then
                            events[#events + 1] = { t = math.max(0, tonumber(e.t)), w = e.w, on = e.on == true }
                        end
                    end
                    table.sort(events, function(a, b) return a.t < b.t end)
                    return next(tracks) and { tracks = tracks, events = events } or nil
                end
            end
        end
    end
    return nil
end

--- A car's takes as its page lists them ({ id, label, ms, made }), checked: what Check and the cards read.
function DirectorTakes.of(w)
    local out = {}
    local list = type(w) == 'table' and type(w.def) == 'table' and w.def.takes or nil
    for _, t in ipairs(type(list) == 'table' and list or {}) do
        local id = type(t) == 'table' and math.tointeger(tonumber(t.id)) or nil
        if id then out[#out + 1] = { id = id, label = type(t.label) == 'string' and t.label or ('Driving event ' .. id), ms = tonumber(t.ms) } end
    end
    return out
end

-- ============================================
-- From the builder's game
-- ============================================

--- One drive's save, by its token (the builder's game makes one per drive): a Save pressed again while the first is
--- still on its way, or after its answer was missed, gets the same take back instead of a second copy.
local TOKEN_KEEP_MS = 30 * 60 * 1000
local byToken = {}   -- [source .. ':' .. token] = { id, ms, at } once written; { busy = true } while it is

--- A recorded take: kept, and its id given back (whip_core:client:takeSaved: token, id, ms, why). The samples come
--- packed (TakeTrack.pack: the client's save, about a quarter of the size).
SecureEvent('whip_core:server:takeSave', {
    permission = 'director.build', whileDead = true, rateLimit = 2000, burst = 3,
    params = { {'token', 'string', 32}, {'key', 'key', 64}, {'worldId', 'key', 64}, {'model', 'string', 64}, {'packed', 'any'} },
}, function(source, player, token, key, worldId, model, packed)
    local function answer(id, ms, why) TriggerClientEvent('whip_core:client:takeSaved', source, token, id or false, ms or 0, why) end
    if not tostring(token):match('^%x+$') then return end
    local now = GetGameTimer()
    for k, v in pairs(byToken) do if v.at and now - v.at > TOKEN_KEEP_MS then byToken[k] = nil end end
    local tk = source .. ':' .. token
    local done = byToken[tk]
    if done then
        if done.busy then
            -- (The first one is still being written: its answer goes to this player as well.)
            CreateThread(function()
                for _ = 1, 100 do
                    Wait(100)
                    local d = byToken[tk]
                    if not d or not d.busy then break end
                end
                local d = byToken[tk]
                if d and d.id then answer(d.id, d.ms, nil) end
            end)
            return
        end
        return answer(done.id, done.ms, nil)
    end
    if not DirectorStore.get(key) then return answer(nil, nil, 'that scenario is not saved yet: Save it first') end
    if not tostring(model):match('^[%w_]+$') then return answer(nil, nil, 'that is not a car model') end
    local samples = TakeTrack.unpack(packed)
    local ok, why = TakeTrack.check(samples, MAX_KEYS)
    if not ok then return answer(nil, nil, 'the driving event is broken: ' .. tostring(why)) end
    local ms = TakeTrack.length(samples)
    if ms < 500 or ms > MAX_MS then return answer(nil, nil, ('a driving event is half a second to %d minutes long'):format(MAX_MS // 60000)) end
    byToken[tk] = { busy = true }
    local data = json.encode({ format = TakeTrack.FORMAT, fields = TakeTrack.FIELDS, samples = samples })
    local okDb, insertId = pcall(MySQL.insert.await,
        [[INSERT INTO `director_takes` (`scenarioKey`, `worldId`, `model`, `lengthMs`, `samples`, `data`, `madeBy`, `madeByName`)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)]],
        { key, worldId, model:lower(), math.floor(ms), #samples // TakeTrack.STRIDE, data, player and player.charId or nil,
          player and player.fullName or nil })
    local id = okDb and math.tointeger(tonumber(insertId)) or nil
    if not id then
        byToken[tk] = nil
        print(('[whip_core:director] a take for %s / %s could not be saved: %s'):format(key, worldId, tostring(insertId)))
        return answer(nil, nil, 'the database did not take it: try Save again')
    end
    byToken[tk] = { id = id, ms = math.floor(ms), at = GetGameTimer() }
    remember(id, samples, model:lower())
    answer(id, math.floor(ms), nil)
end)

--- A drive its builder let go before the save's answer came (F11, F4, a death: client/director_takes.lua): the take
--- written for it is deleted, as nothing will ever name it. Only their own token's, while it is remembered.
SecureEvent('whip_core:server:takeForget', {
    permission = 'director.build', whileDead = true, rateLimit = 1000, burst = 3,
    params = { {'token', 'string', 32} },
}, function(source, _, token)
    local tk = source .. ':' .. tostring(token)
    local d = byToken[tk]
    if not (d and d.id) then return end
    byToken[tk] = nil
    cache[d.id] = nil
    local id = d.id
    CreateThread(function()
        local _, err = q('DELETE FROM `director_takes` WHERE `id` = ?', { id })
        if err then print(('[whip_core:director] an unused take %d could not be deleted: %s'):format(id, tostring(err))) end
    end)
end)

-- ============================================
-- To the game that plays one
-- ============================================

-- A game asks for every take it is missing in one ask (whip_core:server:takeWant, a list), and none is dropped: each
-- goes on that game's line, and the line is sent a few at a time (SENDING_MAX on their way at once, so a convoy of a
-- dozen does not pile a dozen copies up in the server's memory at once), the next as soon as the game says it has one
-- (whip_core:server:takeGot) or, failing that, once one should have drained. A take on the line or on its way is not
-- added again, so asking twice costs nothing.
-- A TAKE SENT IS NOT SENT AGAIN to that game for its drain time plus RESEND_GAP_MS (`sent`), whatever the game says:
-- its takeGot frees a place on the way (the next may go), never that guard, so no game can have the server queue copy
-- after copy of one take. An honest game asks again only after its own re-ask wait or once it let the take go.
local SENDING_MAX = 4
local WANT_MAX = 64
local RESEND_GAP_MS = 10000
local sending = {}   -- [source] = { [id] = until (GetGameTimer): on its way }
local sent = {}      -- [source] = { [id] = not before (GetGameTimer): when it may be sent to that game again }
local line = {}      -- [source] = { id, id, ...; has = { [id] = true } }
local pumping = {}   -- [source] = true while its line is worked through

--- How many takes are on their way to this game now (one that should have drained by now let go of).
local function onTheirWay(source)
    local mine = sending[source]
    if not mine then return 0 end
    local now, n = GetGameTimer(), 0
    for k, untilAt in pairs(mine) do
        if untilAt <= now then mine[k] = nil else n = n + 1 end
    end
    return n
end

--- One take to a game, packed as it is saved (TakeTrack.pack, worked out once a take); on its way until it should have
--- drained: about 3 bytes a packed value (small deltas), plus slack for a slow link.
local function send(source, t)
    t.packed = t.packed or TakeTrack.pack(t.samples)
    t.usedAt = GetGameTimer()
    local mine = sending[source] or {}
    sending[source] = mine
    local drained = GetGameTimer() + math.floor(#t.packed.d * 3 / SEND_BPS * 1000) + 2000
    mine[t.id] = drained
    sent[source] = sent[source] or {}
    sent[source][t.id] = drained + RESEND_GAP_MS
    TriggerLatentClientEvent('whip_core:client:take', source, SEND_BPS, t.id, t.packed)
end

--- A game's line worked through, a few on their way at once, each read first if it is not yet (a thread).
local function pump(source)
    if pumping[source] then return end
    pumping[source] = true
    CreateThread(function()
        while line[source] and #line[source] > 0 and GetPlayerName(source) do
            if onTheirWay(source) >= SENDING_MAX then
                Wait(100)
            else
                local l = line[source]
                local id = table.remove(l, 1)
                l.has[id] = nil
                local t, why = DirectorTakes.load(id)
                -- (Gone while it was read: their line went with them.)
                if line[source] ~= l then break end
                if t then send(source, t)
                else print(('[whip_core:director] take %d could not be sent: %s'):format(id, tostring(why))) end
            end
        end
        pumping[source] = nil
    end)
end

AddEventHandler('playerDropped', function()
    sending[source], sent[source], line[source] = nil, nil, nil
end)

SecureEvent('whip_core:server:takeWant', {
    whileDead = true, rateLimit = 500, burst = 6,
    params = { { 'ids', 'list', { 'id', 'id' }, WANT_MAX } },
}, function(source, _, ids)
    local l = line[source] or { has = {} }
    line[source] = l
    local mine, before, now, builder = sending[source], sent[source], GetGameTimer(), nil
    for _, id in ipairs(ids) do
        if not l.has[id] and not (mine and mine[id] and mine[id] > now) and not (before and before[id] and before[id] > now) then
            -- Only a take in use, unless they build (the editor's other cars, a take looked at): no game makes the
            -- server read the whole table into memory and stream it back
            if builder == nil then builder = Permissions.has(source, 'director.build') end
            if builder or inUse(id) then
                l[#l + 1] = id
                l.has[id] = true
            end
        end
    end
    pump(source)
end)

--- A game has a take (client/actors.lua): the next on its line may go. (Only a take on its way to that game; it is
--- still not sent to it again before its `sent` time.)
SecureEvent('whip_core:server:takeGot', {
    whileDead = true, rateLimit = 50, burst = 20,
    params = { { 'id', 'id' } },
}, function(source, _, id)
    local mine = sending[source]
    if mine and mine[id] then mine[id] = nil end
end)
