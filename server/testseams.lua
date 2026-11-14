-- ============================================
-- Test seams — deliberate, gated hooks for whip_test
-- ============================================
--
-- Fault injection (a database read or write made to fail), load (phantom players, a rate-limit
-- bypass), and reads of internal state a test asserts on. The failure paths are where defects hide,
-- and they can't be tested without a way to MAKE them fail.
--
-- Safety:
--   1. Every seam is inert unless Config.EnableTestSeams is true.
--   2. There is no network path: exports only, server-to-server, guarded by seamsEnabled().
--   3. An armed fault is ONE-SHOT and self-expires, so a crashed test can't leave the server broken.
--
-- Delete this file and its fxmanifest line to strip the capability entirely.
-- ============================================

TestSeams = {}

-- How long an armed fault stays armed before disarming itself.
local FAULT_TTL_MS = 10000

local _armed = nil   -- { mode = string, expires = number }

--- Until when per-source rate limiting is suspended for a load test (a GetGameTimer value), or nil
--- — nil in every normal server. Set only by the __TestRateLimitBypass export (the LOAD-TEST SEAMS
--- below); RateLimit (server/helpers.lua) asks TestSeams.rateLimitBypassed.
local rateLimitBypassUntil = nil

--- Is rate limiting suspended for a load test right now? Clears itself once the time is up, so the
--- limiter goes back to normal without anyone having to remember.
---@return boolean
function TestSeams.rateLimitBypassed()
    if not rateLimitBypassUntil then return false end
    -- Test faults switched off (they can be, live, in /whip → Settings): the bypass ends at once.
    if Config.EnableTestSeams ~= true then
        rateLimitBypassUntil = nil
        return false
    end
    if GetGameTimer() < rateLimitBypassUntil then return true end
    rateLimitBypassUntil = nil
    return false
end

--- Is the seam system available at all?
---@return boolean
local function seamsEnabled()
    return Config.EnableTestSeams == true
end

--- Arm a one-shot fault. The NEXT operation matching `mode` fails, then the fault disarms.
---@param mode string|nil  'inventory_read' | 'container_read' | 'vehicle_read' | 'transaction'; nil disarms
---@return boolean armed
function TestSeams.arm(mode)
    if not seamsEnabled() then return false end

    if mode == nil then
        -- Only announce a disarm that disarmed something (teardowns call this on every run).
        if _armed then
            print('[whip_core:seams] disarmed')
        end
        _armed = nil
        return true
    end

    _armed = { mode = mode, expires = GetGameTimer() + FAULT_TTL_MS }
    print(('[whip_core:seams] ARMED "%s" — next matching operation will fail (expires in %dms)')
        :format(mode, FAULT_TTL_MS))
    return true
end

--- Should the caller pretend this operation failed?
--- Consumes the fault, so it fires exactly once.
---@param mode string
---@return boolean
function TestSeams.shouldFail(mode)
    if not seamsEnabled() or not _armed then return false end

    if GetGameTimer() > _armed.expires then
        _armed = nil
        return false
    end

    if _armed.mode ~= mode then return false end

    _armed = nil
    print(('[whip_core:seams] injecting failure for "%s"'):format(mode))
    return true
end

--- Currently armed mode, for assertions.
---@return string|nil
function TestSeams.armed()
    if not _armed then return nil end
    if GetGameTimer() > _armed.expires then
        _armed = nil
        return nil
    end
    return _armed.mode
end

-- ============================================
-- Exports (server-to-server only, guarded by seamsEnabled())
-- ============================================

exports('__TestSetDbFaultMode', function(mode)
    if not seamsEnabled() then
        print('[whip_core:seams] refused — Config.EnableTestSeams is not true')
        return false
    end
    return TestSeams.arm(mode)
end)

exports('__TestGetDbFaultMode', function()
    return TestSeams.armed()
end)

--- Call Inventory.load directly so a test can observe its CONTRACT rather than its effects.
---
--- The distinction that matters: nil means "the read failed", an empty table would mean
--- "this character owns nothing". Conflating those is what deleted inventories, so a test
--- has to be able to see which one came back.
---@param charId number
---@return table|nil
exports('__TestLoadInventory', function(charId)
    if not seamsEnabled() then return nil end
    return Inventory.load(charId)
end)

--- The most recent outcome SecureEvent recorded for an event, if it was a rejection, with its reason:
--- "refused for the reason I expected", not just "nothing happened". Reads the marker
--- (SecureEvents.lastStatus, the last outcome whatever it was), not the refusal ring: a walk of that
--- would report a long-superseded refusal as current.
---@param eventName string
---@return string|nil reason  nil unless the most recent outcome was a rejection
exports('__TestLastReject', function(eventName)
    if not seamsEnabled() then return nil end
    if not SecureEvents then return nil end

    local last = SecureEvents.lastStatus(eventName)
    if not last or last.status ~= 'rejected' then return nil end

    return last.reason or '(no reason recorded)'
end)

--- Force a save now and report honestly whether it committed.
---
--- A seam rather than a public export: nothing in normal operation needs to ask for a save,
--- because every mutation already saves. Only a test needs to drive the save path directly
--- and read its result.
---@param source number
---@return boolean
exports('__TestSaveInventory', function(source)
    if not seamsEnabled() then return false end
    local player = Players[source]
    if not player or not player.inventory then return false end
    return Inventory.syncAndSave(source, player) and true or false
end)

--- Force a container save now and report whether it committed.
---@param containerId number
---@return boolean
exports('__TestSaveContainer', function(containerId)
    if not seamsEnabled() then return false end
    return Containers.saveInventory(containerId) and true or false
end)

--- What did the LAST inventory save actually write? The size of the write is the point of the
--- incremental save, and "the row is on disk" can't show it.
---@return table|nil { charId, queries, replaceRows, deleteRows }
exports('__TestLastWrite', function()
    if not seamsEnabled() then return nil end
    return Inventory._lastWrite
end)

--- Discard the recorded last write, so a test can tell "nothing was written" from
--- "something was written before this test started".
exports('__TestClearLastWrite', function()
    if not seamsEnabled() then return false end
    Inventory._lastWrite = nil
    return true
end)

-- ============================================
-- Write-behind scheduling seams
-- ============================================
--
-- The scheduler's job is to DELAY writes, which a test that only reads the database can't see.
-- These seams expose the queue itself.

--- How many units are waiting to be written.
---@return number
exports('__TestDirtyCount', function()
    if not seamsEnabled() then return -1 end

    -- Character rows count too: FlushPersistence reports this number when it can't get everything
    -- to disk.
    local owed = Stores.dirtyCount() or 0
    if PlayerRows then
        for _ in pairs(PlayerRows._dirty or {})    do owed = owed + 1 end
        for _ in pairs(PlayerRows._dirtyPos or {}) do owed = owed + 1 end
        for _ in pairs(PlayerRows._soon or {})     do owed = owed + 1 end
    end
    return owed
end)

--- Mark a player's inventory dirty without writing it.
---@param source number
---@return boolean
exports('__TestMarkPlayerDirty', function(source)
    if not seamsEnabled() then return false end
    local store = Stores.player(source, 'player')
    if not store then return false end
    Stores.markDirty(store)
    return true
end)

--- Flush a player's unit and stop tracking it, as a cache teardown would.
---@param source number
---@return boolean
exports('__TestTeardownPlayer', function(source)
    if not seamsEnabled() then return false end
    local store = Stores.player(source, 'player')
    if not store then return false end
    return Stores.teardown(store) and true or false
end)

--- Drop a unit from the queue WITHOUT writing it.
---@param unit string
---@return boolean
exports('__TestForget', function(unit)
    if not seamsEnabled() then return false end
    Stores.forget(unit)
    return true
end)

--- Is this unit stuck: five or more failed saves in a row, as /whipsaves lists them?
---@param unit string
---@return boolean
exports('__TestIsStuck', function(unit)
    if not seamsEnabled() then return false end
    for _, s in ipairs(Stores.stuckUnits()) do
        if s.unit == unit then return true end
    end
    return false
end)

--- Forget a player's save snapshot, so the next build emits a full rewrite.
---
--- Manufactures a genuine pending write without mutating anything, so a flush test has real work to
--- assert on.
---@param source number
---@return boolean
exports('__TestInvalidateSnapshot', function(source)
    if not seamsEnabled() then return false end
    local player = Players[source]
    if not player or not player.inventory then return false end
    Inventory.invalidateSnapshot(player.inventory)
    return true
end)

--- Load a container's contents into memory, as opening it would.
---
--- A container store cannot be resolved until its cache is present — that is deliberate, so
--- a failed load can never read as "this stash is empty" — which means a test about unloading
--- has to be able to load first.
---@param containerId number
---@return boolean
exports('__TestLoadContainer', function(containerId)
    if not seamsEnabled() then return false end
    return Containers.loadInventory(containerId) and true or false
end)

--- Mark a container dirty and manufacture a genuine pending write for it.
---
--- Invalidating the snapshot makes the write real: without it the query set is empty.
---@param containerId number
---@return boolean
exports('__TestMarkContainerDirty', function(containerId)
    if not seamsEnabled() then return false end
    local store = Stores.container(containerId)
    if not store then return false end
    Containers.invalidateSnapshot(containerId)
    Stores.markDirty(store)
    return true
end)

--- Unload a container's cache, returning whether it actually unloaded.
---@param containerId number
---@return boolean
exports('__TestUnloadContainer', function(containerId)
    if not seamsEnabled() then return false end
    return Containers.unloadInventory(containerId) and true or false
end)

--- Is a container's inventory currently held in memory?
---
--- Lets a test tell "unload refused and kept the contents" from "unload dropped them",
--- which is the whole difference between the safe and the data-losing behaviour.
---@param containerId number
---@return boolean
exports('__TestContainerCached', function(containerId)
    if not seamsEnabled() then return false end
    return Containers.invCache[containerId] ~= nil
end)

-- ============================================
-- Viewers — asking about a NAMED store
-- ============================================
--
-- A player can be inside several stores at once, so these ask about the store the test means.

--- Does this player currently have this store open?
---@param src number
---@param storeId string  e.g. 'container:42', 'vehicle:7:trunk', 'panel:my_bench'
---@return boolean
exports('__TestIsViewer', function(src, storeId)
    if not seamsEnabled() then return false end
    return Stores.isViewer(src, storeId)
end)

--- How many people have this store open. Zero is a meaningful answer — it is what proves a close
--- released, and what proves an unload was allowed to happen.
---@param storeId string
---@return number
exports('__TestViewerCount', function(storeId)
    if not seamsEnabled() then return 0 end
    return Stores.viewerCount(storeId)
end)

--- Every store this player currently has open, as a sorted list of store ids.
---
--- For diagnosing a cascade: a test that fails partway leaves what it opened open, and the next
--- test's open is refused for a reason that points elsewhere. Naming what is open makes it obvious.
---@param src number
---@return table  array of store ids, sorted for a stable message
exports('__TestViewsOf', function(src)
    if not seamsEnabled() then return {} end

    local open = Stores._viewing and Stores._viewing[src]
    if not open then return {} end

    local ids = {}
    for storeId in pairs(open) do ids[#ids + 1] = storeId end
    table.sort(ids)
    return ids
end)

--- Drop every store view this player holds, unconditionally.
---
--- The cleanup half of __TestViewsOf, so one module's failure doesn't fail every module after it. Not
--- through the client's close path (a round trip that fails when the client is confused): this is
--- the between-modules reset, forcing the server-side truth.
---@param src number
---@return number released  how many views were dropped
exports('__TestReleaseViews', function(src)
    if not seamsEnabled() then return 0 end

    local open = Stores._viewing and Stores._viewing[src]
    if not open then return 0 end

    local n = 0
    for _ in pairs(open) do n = n + 1 end

    if Stores.releaseAllViews then Stores.releaseAllViews(src) end
    return n
end)

--- Open a shop for a player, as a shop point's E does once its own checks have passed (Shops.openFor). For
--- whip_test's shop screen tests. Answers true, or false and why.
---@param source number|string|nil
---@param shopId number
---@return boolean ok
---@return string|nil why
exports('__TestOpenShop', function(source, shopId)
    if not seamsEnabled() then return false, 'test seams are off' end
    source = tonumber(source)
    local player = source and Players[source]
    if not source or not player then return false, 'not loaded' end
    return Shops.openFor(source, player, tonumber(shopId))
end)

--- Route a player's save through Stores.save, so the durability routing itself can be tested: a
--- write-through kind must commit before returning, a write-behind kind must only enqueue.
---@param source number
---@return boolean
exports('__TestStoreSave', function(source)
    if not seamsEnabled() then return false end
    local store = Stores.player(source, 'player')
    if not store then return false end
    return Stores.save(store) and true or false
end)

--- Commit a player's inventory immediately, making exactly ONE transaction attempt.
---
--- Distinct from __TestFlushPersistence, which drains the whole queue and honours the
--- quarantine backoff. A test arming a ONE-SHOT fault needs a single, unconditional attempt:
--- anything that retries would consume the fault on the first try and then succeed, leaving
--- the test measuring an operation that never actually failed.
---@param source number
---@return boolean
exports('__TestFlushPlayerNow', function(source)
    if not seamsEnabled() then return false end
    local store = Stores.player(source, 'player')
    if not store then return false end
    return Stores.flushNow(store) and true or false
end)

--- Suspend or resume the background flush threads — the Stores one AND the character-row one
--- (player.lua reads the same flag).
---
--- Required by any test asserting a write did NOT happen: the thread commits once a second,
--- so without this the test is racing a writer it usually loses to quietly — the row lands
--- and the test reports the write as permitted when it was only early.
---@param paused boolean
---@return boolean
exports('__TestPauseFlushThread', function(paused)
    if not seamsEnabled() then return false end
    Stores._flushPaused = paused and true or false
    return true
end)

--- Commit ONE container immediately, making exactly one transaction attempt.
--- The container counterpart of __TestFlushPlayerNow; see there for why one attempt matters.
---@param containerId number
---@return boolean
exports('__TestFlushContainerNow', function(containerId)
    if not seamsEnabled() then return false end
    local store = Stores.container(containerId)
    if not store then return false end
    return Stores.flushNow(store) and true or false
end)

--- Run Stores.saveAll over two stores that are BOTH deferred.
---@param source number
---@return boolean
exports('__TestSaveAllDeferred', function(source)
    if not seamsEnabled() then return false end
    local a = Stores.player(source, 'player')
    -- Two DIFFERENT stores on the same unit, which is what saveAll has to batch.
    local b = Stores.player(source, 'accessory')
    if not a or not b then return false end
    return Stores.saveAll({ a, b }) and true or false
end)

--- Run Stores.saveAll over a player store and a container store — TWO DIFFERENT UNITS (a transaction
--- group needs two; __TestSaveAllDeferred's share one). The mixed-durability test flips container to
--- writeThrough around the call: a write-through participant commits at once, so the deferred half
--- must not wait, or a crash would put an item in both places.
---@param source number
---@param containerId number
---@return boolean
exports('__TestSaveAllMixed', function(source, containerId)
    if not seamsEnabled() then return false end
    local p = Stores.player(source, 'player')
    local c = Stores.container(containerId)
    if not p or not c then return false end
    return Stores.saveAll({ p, c }) and true or false
end)

--- Abandon a unit the way five failed flushes would: out of the write queue, still grouped (one that
--- left its group would let its partner be written alone, and the item land on disk twice). Reached
--- honestly, it takes minutes of faulted flushes.
---@param unit string
---@return boolean
exports('__TestAbandonUnit', function(unit)
    if not seamsEnabled() then return false end
    if type(unit) ~= 'string' then return false end

    Stores._dirty[unit] = nil
    Stores._quarantine[unit] = nil
    return true
end)

--- Pin a unit as having a commit in flight, without running one.
---
--- The guard that stops two overlapping saves duplicating an item: a unit marked in flight is not
--- written by anything else until it is released (a test can't schedule the real race).
---@param unit string
---@param on boolean
---@return boolean
exports('__TestSetInflight', function(unit, on)
    if not seamsEnabled() then return false end
    if type(unit) ~= 'string' then return false end

    Stores._inflight[unit] = on and true or nil
    return true
end)

---@param unit string
---@return boolean
exports('__TestIsInflight', function(unit)
    if not seamsEnabled() then return false end
    return Stores._inflight[unit] == true
end)

--- Is this unit currently owed to the database?
---@param unit string
---@return boolean
exports('__TestIsDirty', function(unit)
    if not seamsEnabled() then return false end
    return Stores._dirty[unit] ~= nil
end)

--- Which units must be written in the same transaction as this one (Stores._linked / Stores._groups)?
--- A batch that HAPPENS to hold both halves of a move is not one REQUIRED to. Sorted; a unit in no
--- group answers with just itself.
---@param unit string
---@return string[]
exports('__TestGroupUnits', function(unit)
    if not seamsEnabled() then return {} end
    if type(unit) ~= 'string' then return {} end

    local gid = Stores._linked and Stores._linked[unit]
    if not gid then return { unit } end

    local g = Stores._groups and Stores._groups[gid]
    if not g then return { unit } end

    local out = {}
    for u in pairs(g) do out[#out + 1] = u end
    table.sort(out)
    return out
end)

--- Flip a kind's durability, returning the previous value so a test can restore it.
---
--- Returning the old mode, not taking a "restore" flag: the test restores exactly what was there.
---@param kindId string
---@param mode string  'writeThrough' | 'writeBehind'
---@return string|nil previous
exports('__TestSetDurability', function(kindId, mode)
    if not seamsEnabled() then return nil end
    local kind = Stores.getKind(kindId)
    if not kind then return nil end
    if mode ~= 'writeThrough' and mode ~= 'writeBehind' then return nil end

    local previous = kind.durability
    kind.durability = mode
    return previous
end)

--- Which stats DECLARE that they persist, straight from the registry.
---
--- So a test can check the `statuses` column holds exactly the persisting stats without hardcoding
--- them. Reads _registry rather than calling getForSave, so the persist FILTER is what is checked.
---@return table|nil  [name] = true for every stat whose value belongs in `statuses`
exports('__TestPersistedStatNames', function()
    if not seamsEnabled() then return nil end
    if not Stats or not Stats._registry then return nil end

    local names = {}
    for name, config in pairs(Stats._registry) do
        -- Must mirror getForSave's own predicate: vitals live in their own columns.
        if (config.type == 'need' or config.type == 'custom') and config.persist then
            names[name] = true
        end
    end
    return names
end)

--- Take a test's vehicle stat listener off again. OnVehicleStatChange has no unregister (a listener
--- goes when its resource stops), and whip_test keeps running: a '*' listener left behind would be
--- entered on every stat change on the server until a restart.
---@param name string  the stat name, or '*'
---@param id string    the id it was registered under
---@return boolean removed
exports('__TestRemoveVehicleStatListener', function(name, id)
    if not seamsEnabled() then return false end
    local list = VehicleStats and VehicleStats._statListeners and VehicleStats._statListeners[name]
    local key = ('%s:%s'):format(GetInvokingResource() or '', tostring(id))
    if not list or not list[key] then return false end
    list[key] = nil
    if next(list) == nil then VehicleStats._statListeners[name] = nil end
    return true
end)

--- Force everything pending to disk and return only once it has landed.
---
--- Persistence is write-behind for most kinds, so this is NOT a no-op: it drains the dirty
--- set through Stores.flushAll and reports whether anything is still owed afterwards. A
--- false return means quarantined or backing off, not merely slow.
---@return boolean
exports('__TestFlushPersistence', function()
    if not seamsEnabled() then return false end

    -- Every write-behind path, in order — character positions and rows (PlayerRows), vehicle stats and
    -- positions, then the stores — saying which step failed. Stops at the first failure: the steps
    -- write the same engine units (a player's row, position and pockets are one), so the next step
    -- would retry the faulted write.
    local function flushEverything()
        local steps = {
            { 'position',        PlayerRows and PlayerRows.flushPositions },
            { 'characterRow',    PlayerRows and PlayerRows.flush },
            { 'vehicleStats',    VehicleStats and VehicleStats.flush },
            { 'vehiclePosition', Vehicles and Vehicles.flushPositions },
            -- force: ignore the quarantine backoff, or a unit whose last flush failed reads to a test
            -- as writes silently not landing.
            { 'stores',          Stores and Stores.flushAll and function() return Stores.flushAll({ force = true }) end },
        }
        for _, step in ipairs(steps) do
            if step[2] and not step[2]() then
                print(('[whip_core:seams] flush incomplete — %s failed (the steps after it were not run)'):format(step[1]))
                return false
            end
        end
        return true
    end

    -- A failure here is the answer, not retried: a test armed a one-shot fault and expects false.
    if not flushEverything() then return false end

    -- Then wait for writes somebody else started: the background threads take work off the dirty
    -- lists before they await, so a commit already in flight is invisible to the flush above
    -- (Stores._txInFlight). Bounded: a database that never answers must fail the test, not hang it.
    local deadline = GetGameTimer() + 5000
    while (Stores._txInFlight or 0) > 0 and GetGameTimer() < deadline do Wait(20) end
    if (Stores._txInFlight or 0) > 0 then
        print(('[whip_core:seams] flush incomplete — %d transaction(s) still with the database after 5s')
            :format(Stores._txInFlight))
        return false
    end

    -- And once more, for anything one of those writes put back on a queue because it failed.
    return flushEverything()
end)

-- ============================================
-- Raw-query faults
-- ============================================
--
-- The fault above reaches only Stores.runTransaction; many writes (Shops.update, Jobs.update, ...) go
-- straight to oxmysql and promise "the row first, then memory". This fails the next raw write whose
-- SQL contains a pattern, without touching the code under test: while armed, MySQL.query/update/
-- insert.await are wrapped in this resource's Lua state,
-- and the first matching call throws — which the callers' own pcall turns into exactly the
-- (false, err) a real database error gives. The originals go back the moment it fires or expires.

local RAW_METHODS = { 'query', 'update', 'insert' }
local _rawOriginals = nil   -- [method] = the real await, while a raw fault is armed
local _rawFault     = nil   -- { pattern, expires }

local function disarmRawFault()
    if _rawOriginals then
        for method, fn in pairs(_rawOriginals) do MySQL[method].await = fn end
    end
    _rawOriginals, _rawFault = nil, nil
end

--- Fail the NEXT raw query/update/insert whose SQL contains `pattern` (plain text, not a Lua pattern).
--- One-shot, and disarms itself after the same 10 seconds as the transaction fault. nil disarms.
---@param pattern string|nil  e.g. 'UPDATE `shops`'
---@return boolean armed
exports('__TestFailNextQuery', function(pattern)
    if not seamsEnabled() then return false end
    disarmRawFault()
    if type(pattern) ~= 'string' or pattern == '' then return true end

    _rawFault = { pattern = pattern, expires = GetGameTimer() + FAULT_TTL_MS }
    _rawOriginals = {}
    for _, method in ipairs(RAW_METHODS) do
        local real = MySQL[method].await --[[@as fun(query: string, params: table|nil): any]]   -- query, update and insert alike
        _rawOriginals[method] = real
        MySQL[method].await = function(query, params)
            local f = _rawFault
            if f and GetGameTimer() > f.expires then
                disarmRawFault()
            elseif f and type(query) == 'string' and query:find(f.pattern, 1, true) then
                disarmRawFault()
                print(('[whip_core:seams] injecting failure for raw query matching "%s"'):format(f.pattern))
                error('injected fault: ' .. f.pattern, 0)
            end
            return real(query, params)
        end
    end
    print(('[whip_core:seams] ARMED raw-query fault for "%s" (expires in %dms)'):format(pattern, FAULT_TTL_MS))
    return true
end)

--- Is a raw-query fault still armed? For asserting that it fired.
---@return string|nil pattern
exports('__TestRawFaultArmed', function()
    if not seamsEnabled() or not _rawFault then return nil end
    if GetGameTimer() > _rawFault.expires then
        disarmRawFault()
        return nil
    end
    return _rawFault.pattern
end)

--- Are the seams switched on at all?
---
--- Every other seam's "off" answer (false, nil, -1) is also a real answer, so the runner asks this once.
---@return boolean
exports('__TestSeamsEnabled', function()
    return seamsEnabled()
end)

--- How many outcomes SecureEvent has recorded for an event, or nil if no such event is registered.
---
--- Read before and after, it tells the runner when the server has finished with a request: the count
--- moves when the handler returns or the event is refused.
---
--- A handler that calls RecordEventRejection moves the count at that point, which is the refusal.
--- For a callback, pass 'cb:<name>'.
---@param eventName string
---@return number|nil
exports('__TestEventSeq', function(eventName)
    if not seamsEnabled() then return nil end
    if not SecureEvents or not SecureEvents.isRegistered(eventName) then return nil end
    local last = SecureEvents.lastStatus(eventName)
    return last and last.n or 0
end)

--- Flip ONLY the server's dead flag on a player.
---
--- For testing the framework's dead-player gate (secure.lua, refusedWhileDead) without killing
--- anyone. It deliberately does not touch the ped, the death screen, health or the statebag:
--- MarkPlayerDead does all of those, and a test would then have to wait out the respawn timer and
--- revive the tester to put them back. The gate reads `player.isDead` and nothing else.
---@param source number
---@param dead boolean
---@return boolean|nil previous  the flag before the change; nil when there is no such player
exports('__TestSetDeadFlag', function(source, dead)
    if not seamsEnabled() then return nil end
    local player = Players[source]
    if not player then return nil end
    local previous = player.isDead == true
    player.isDead = dead and true or false
    return previous
end)

--- The server-wide switches a test can leave flipped, for the runner's between-module leak check.
---
--- An armed fault, a paused flush thread or a flipped durability left behind breaks every later module.
---@param source number|nil
---@return table
exports('__TestHarnessState', function(source)
    if not seamsEnabled() then return {} end

    -- 900000 is PHANTOM_BASE, which is a local further down this file and so not visible here.
    local phantoms = 0
    for src in pairs(Players) do
        if src > 900000 then phantoms = phantoms + 1 end
    end

    local playerKind   = Stores.getKind('player')
    local containerKind = Stores.getKind('container')
    local player        = source and Players[source] or nil

    return {
        faultArmed      = TestSeams.armed(),
        rawFaultArmed   = (_rawFault and GetGameTimer() <= _rawFault.expires) and _rawFault.pattern or nil,
        flushPaused     = Stores._flushPaused == true,
        playerDurability    = playerKind and playerKind.durability or nil,
        containerDurability = containerKind and containerKind.durability or nil,
        rateLimitBypass = rateLimitBypassUntil ~= nil and GetGameTimer() < rateLimitBypassUntil,
        phantoms        = phantoms,
        dead            = player and player.isDead == true or false,
    }
end)

-- ============================================
-- Load-test seams
-- ============================================
--
-- Everything above injects FAULTS so failure paths can be tested. These two inject LOAD, so that
-- the cost of two hundred players can be measured by one. Same gating, same fail-safe design:
-- inert without Config.EnableTestSeams, and both self-expire so a crashed test cannot leave the
-- server altered.

--- Reserved source ids for phantom players.
---
--- FiveM issues sources from 1 upwards and never anywhere near this, so a phantom can never
--- collide with, mask, or be mistaken for a connected player.
local PHANTOM_BASE = 900000

--- How long a rate-limit bypass survives without being renewed.
---
--- Short on purpose. The load test renews it every few seconds while running, so a crash, a
--- disconnect or a stopped resource restores normal rate limiting within seconds rather than
--- leaving the server defenceless until someone remembers.
local BYPASS_TTL_MS = 10000

--- Suspend per-source rate limiting for BYPASS_TTL_MS.
---
--- A load test is one player pretending to be two hundred, and every event it fires shares that
--- one source's rate-limit buckets. Without this the limiter rejects almost everything and the run
--- measures the limiter rather than the framework.
---
--- Call repeatedly to hold it open; stop calling and it lapses on its own.
---@param on boolean
---@return boolean active
exports('__TestRateLimitBypass', function(on)
    if not seamsEnabled() then return false end

    if on then
        rateLimitBypassUntil = GetGameTimer() + BYPASS_TTL_MS
        return true
    end

    rateLimitBypassUntil = nil
    return false
end)

local _announced = {}   -- [src] = true for a phantom whose loaded was announced

--- Create or clear phantom players.
---
--- A phantom is an entry in `Players` (and `Stats._cache`) with no character behind it. Every
--- per-player loop in whip — the stats tick, the stats sync, the periodic save walk — iterates
--- `Players` and will do real work for each one, which is exactly the cost we cannot otherwise
--- observe without two hundred humans.
---
--- What this does not measure: phantoms are skipped by SafeSavePlayer, so the
--- database cost of two hundred players saving is NOT covered here. That is measured separately
--- and honestly by the load test's own database burst, against its own table. Anything reading
--- GetPlayerPed(src) also gets 0 for a phantom and exits early, so proximity work under-reports.
--- Phantoms measure Lua loop cost. They do not measure everything.
---
--- `announce`: whip_core:player:loaded fires for each (and whip_core:player:logout when they go), with
--- `phantom = true`, so a satellite's per-player work runs for them too (a load test's `announce` dial). Only the
--- public events: whip_core's own login hooks (a give kept for login, blips) are not run for a phantom.
---@param n number  how many to create; 0 clears them
---@param announce boolean|nil
---@return number active
exports('__TestPhantoms', function(n, announce)
    n = math.max(0, math.min(tonumber(n) or 0, 1024))
    -- The ones announced hear their logout first, whatever comes next.
    for src in pairs(_announced) do
        local p = Players[src]
        if p and p.phantom then
            WhipEmit('whip_core:player:logout', { source = src, charId = p.charId, player = p:lightSheet(), why = 'phantom', phantom = true })
        end
        _announced[src] = nil
    end
    -- Clearing (0) works with test faults off too: a load test that died before they were switched
    -- off must still be able to take its phantoms away.
    if not seamsEnabled() and n > 0 then return 0 end

    -- WhipPlayer is a runtime reference (this file loads before server/player.lua). Fail loudly
    -- rather than quietly build plain tables (setmetatable(t, nil) is legal).
    if n > 0 and not WhipPlayer then
        print('[whip_core:seams] cannot create phantoms — WhipPlayer is not loaded')
        return 0
    end

    -- Clear whatever is there first, so this is idempotent and a smaller number really shrinks.
    for src in pairs(Players) do
        if src > PHANTOM_BASE then
            Players[src] = nil
            -- All of it — the change log, decay timers and recent sets too, not only the cache.
            if Stats and Stats.cleanupPlayer then Stats.cleanupPlayer(src) end
        end
    end

    for i = 1, n do
        local src = PHANTOM_BASE + i
        -- A real WhipPlayer (its class metatable), not a plain table: every method resolves, and the
        -- ones that read the world answer empty for a source with no ped. `phantom` marks them, so
        -- the paths that WRITE (SafeSavePlayer, the position save) skip them.
        Players[src] = setmetatable({
            source   = src,
            charId   = -(PHANTOM_BASE + i),   -- negative: cannot collide with a real charId
            userId   = -(PHANTOM_BASE + i),
            fullName = ('Phantom %d'):format(i),
            phantom  = true,
            metadata = {},
            position = vector4(0.0, 0.0, 70.0, 0.0),
        }, WhipPlayer)

        -- Give the stats tick something to walk, through initPlayer: the shape a real player gets.
        if Stats and Stats.initPlayer then
            Stats.initPlayer(src, { statuses = {} })
        end
        if announce == true then
            local p = Players[src]
            _announced[src] = true
            WhipEmit('whip_core:player:loaded', { source = src, charId = p.charId, name = p.fullName, newCharacter = false,
                player = p:lightSheet(), phantom = true })
        end
    end

    local count = 0
    for src in pairs(Players) do
        if src > PHANTOM_BASE then count = count + 1 end
    end
    return count
end)

--- Test faults switched off while running (/whip → Settings): nothing armed may linger. The rate
--- limit bypass ends, armed faults already refuse (shouldFail asks seamsEnabled first), and any
--- phantom players a load test left behind leave `Players`.
Settings.onChange('EnableTestSeams', function(on)
    if on then return end
    rateLimitBypassUntil = nil
    for src in pairs(Players) do
        if src > PHANTOM_BASE then
            Players[src] = nil
            if Stats and Stats.cleanupPlayer then Stats.cleanupPlayer(src) end
        end
    end
end)

--- How many phantoms are currently in `Players`. Used by the load test's abort path to confirm
--- the world was actually put back.
---@return number
exports('__TestPhantomCount', function()
    if not seamsEnabled() then return 0 end
    local count = 0
    for src in pairs(Players) do
        if src > PHANTOM_BASE then count = count + 1 end
    end
    return count
end)

--- Clear phantoms if the resource stops mid-test. Belt and braces — the load test clears them on
--- its own abort path, but a resource restart does not run that path.
CoreStop.add(10, 'test seams', function()   -- a step of whip_core's stop (server/lifecycle.lua)
    rateLimitBypassUntil = nil
end)

--- Delete a vehicle whip created, row and all, so a load test doesn't leave its cars in `vehicles`.
--- Through Vehicles.delete, so the cache, storage and write-behind queue are released together.
---@param vehicleId number|string|nil
---@return boolean
exports('__TestDeleteVehicle', function(vehicleId)
    if not seamsEnabled() then return false end
    vehicleId = tonumber(vehicleId)
    if not vehicleId then return false end
    return Vehicles.delete(vehicleId) and true or false
end)

--- What a client's exit report of `props` would be told it held back, for this car (nil for nothing).
--- Vehicles.mergeClientProperties is pure — nothing is saved here.
---@param vehicleId number
---@param props table
---@return string[]|nil held
exports('__TestHeldBack', function(vehicleId, props)
    if not seamsEnabled() then return nil end
    local _, held = Vehicles.mergeClientProperties(tonumber(vehicleId), props)
    return held
end)

--- The player a street car is counted against for the per-player cap (events_vehicles.lua), or nil.
--- Nothing public reads the count.
---@param vehicleId number
---@return number|nil source
exports('__TestStreetCarHolder', function(vehicleId)
    if not seamsEnabled() then return nil end
    local def = Vehicles.getDef(tonumber(vehicleId) or -1)
    return def and def.session and def.adoptedBy or nil
end)

--- Remove a registered player stat (Stats.unregister): a load test registers throwaway stats to
--- multiply the per-player tick, and takes them out mid-run without stopping a resource.
---@param name string
---@return boolean removed
exports('__TestUnregisterStat', function(name)
    if not seamsEnabled() then return false end
    if type(name) ~= 'string' or not Stats or not Stats._registry then return false end
    if not Stats._registry[name] then return false end

    Stats.unregister(name)

    -- Take the per-player residue with it too — the tick no longer walks an unregistered
    -- stat's decay timers, but a value nothing will ever read has no business staying cached.
    for src, cache in pairs(Stats._cache or {}) do
        cache[name] = nil
        if Stats._lastDecay and Stats._lastDecay[src] then
            Stats._lastDecay[src][name] = nil
        end
    end
    return true
end)

--- Write (or, with a nil value, clear) vehicle data AS IF another resource did it.
---
--- Vehicle data keys belong to the resource that wrote them, and a test run has only whip_test
--- to call from. This stands in for "a second satellite", so the tests can check that one
--- resource cannot overwrite, clear or ClearAll another's keys.
---@param vehicleId number
---@param key string
---@param value any
---@param resource string  the resource to pretend to be
---@return boolean ok
---@return string|nil err
exports('__TestSetVehicleDataAs', function(vehicleId, key, value, resource)
    if not seamsEnabled() then return false, 'test seams are off' end
    if type(resource) ~= 'string' or resource == '' then return false, 'no resource named' end
    return VehicleData.set(vehicleId, key, value, resource)
end)

--- Is a key that fits this car in its ignition?
---
--- For SpawnTempVehicle's `keyInIgnition` test. There is no public read of the ignition —
--- a satellite asks about keys through a player (HasVehicleKey) — and the ignition of a temp car
--- lives only in memory, so there is no row for a test to read either.
---@param vehicleId number|string|nil
---@return boolean|nil  nil with the seams off
exports('__TestKeyInIgnition', function(vehicleId)
    if not seamsEnabled() then return nil end
    vehicleId = tonumber(vehicleId)
    if not vehicleId or not Vehicles.getDef(vehicleId) then return false end
    return Vehicles.hasKeyInIgnition(vehicleId) and true or false
end)

--- Run what deleting a character releases — homes, keys, jobs, stashes — for a character the test
--- has ALREADY soft-deleted in the database.
---
--- The release runs from Character.onLife hooks the delete path calls (the public event is news only),
--- so a test needs this to reach them. It refuses a character that is not deleted, so it cannot strip
--- a live one.
---@param charId number|string|nil
---@return boolean ran
---@return string|nil why
exports('__TestRunCharacterDeleted', function(charId)
    if not seamsEnabled() then return false, 'test seams are off' end
    charId = tonumber(charId)
    if not charId then return false, 'no charId' end
    local ok, deleted = pcall(MySQL.scalar.await,
        'SELECT `deleted` IS NOT NULL FROM `characters` WHERE `charId` = ?', { charId })
    if not ok or not DbBool(deleted) then return false, 'that character is not deleted' end
    Character.runHooks('deleted', { charId = charId })
    return true
end)
