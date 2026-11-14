-- ============================================
-- Database health — can whip reach the database?
-- ============================================
-- While the database cannot be reached, players are locked out of their items (no
-- inventory screen, no use, move, give, drop, pick up or item action), even though memory would
-- save it all later. A safety check, so nothing a player does in an outage can be lost to a crash.
--
-- DOWN only when the database does not work: a database error followed by a SELECT 1 that fails
-- twice (db_guard asks after every error), or the heartbeat's own SELECT 1 failing twice. Never
-- because it is slow: a slow database still answers, and only db_guard's 65 s of silence fails a
-- call. UP on the first SELECT 1 that answers: everything owed is saved, then items unlock.
-- Every player item action asks DbHealth.refusal() (events_inventory.lua, inventory.lua); the
-- client is told with whip_core:client:dbHealth and locks its screens (client/inventory.lua).

-- started: whip_core's start has reached the database (DbHealth.waitForDatabase, below).
DbHealth = { up = true, started = false }

local LOCKED = "Your items are locked: the server can't save right now. Try again in a moment."

local probing = false

--- Is the database there? Two SELECT 1s a second apart, so one dropped connection is not an outage.
--- nil while another check is already running.
---@return boolean|nil
local function probe()
    if probing then return nil end
    probing = true
    local ok = pcall(MySQL.scalar.await, 'SELECT 1')
    if not ok then
        Wait(1000)
        ok = pcall(MySQL.scalar.await, 'SELECT 1')
    end
    probing = false
    return ok
end

local function goDown(why)
    if not DbHealth.up then return end
    DbHealth.up = false
    DbHealth.since = GetGameTimer()
    print(('^1[whip_core:db] THE DATABASE CANNOT BE REACHED (%s). Players are locked out of their items until it is back.^0')
        :format(tostring(why)))
    TriggerClientEvent('whip_core:client:dbHealth', -1, false)
end

--- "name: count; …" for the counts above zero.
local function describe(list)
    local parts = {}
    for _, w in ipairs(list) do
        if w.count > 0 then parts[#parts + 1] = ('%s: %d'):format(w.name, w.count) end
    end
    return table.concat(parts, '; ')
end

--- The database answers again. Everything waiting is saved FIRST (the same save a shutdown runs, so
--- nothing waits on a retry timer that backed off in the outage), then items unlock and the console
--- says what was saved. Gone again during that save: stays locked, and the heartbeat tries again.
local function goUp()
    if DbHealth.up then return end
    local downFor = (GetGameTimer() - (DbHealth.since or GetGameTimer())) // 1000
    local before, waiting = FinalSave.waiting()
    local unsaved, took = FinalSave.run(15000, false)
    if probe() == false then return end

    DbHealth.up = true
    TriggerClientEvent('whip_core:client:dbHealth', -1, true)
    local after, left = FinalSave.waiting()
    local list = describe(before)
    print(('^2[whip_core:db] BACK TO NORMAL: the database answered again after %d s. Saved %d change(s) that were waiting%s in %.1f s, and unlocked players\' items.^0')
        :format(downFor, math.max(waiting - left, 0), list ~= '' and (' (' .. list .. ')') or '', took / 1000))
    if left > 0 or #unsaved > 0 then
        print(('^3[whip_core:db] still waiting, retried as usual: %s^0')
            :format(describe(after) ~= '' and describe(after) or table.concat(unsaved, ', ')))
    end
end

--- A database call failed: check whether the database itself is gone. Called by db_guard after any
--- error; returns at once (the check runs in its own thread).
---@param why string|nil
function DbHealth.suspect(why)
    if not DbHealth.started or not DbHealth.up or probing then return end
    CreateThread(function()
        if probe() == false then goDown(why or 'a database call failed') end
    end)
end

--- Why a player's item action is refused while the database is down; nil while it is up.
---@return string|nil
function DbHealth.refusal()
    if DbHealth.up then return nil end
    return LOCKED
end

-- ============================================
-- At start: is the database there at all?
-- ============================================
-- The first thing whip_core's start does (player_lifecycle.lua), before it builds a table. oxmysql keeps trying to
-- connect, every 30 s, and until it has, every query waits without a word. So whip_core asks oxmysql first and,
-- while there is no connection, says in its own words what to check.

--- The oldest database whip runs on: CHECK rules (the bank balance that cannot go below zero) are kept from
--- MariaDB 10.2.1 and MySQL 8.0.16, and JSON_EXTRACT is in MariaDB from 10.2.3.
local MINIMUM = { MariaDB = { 10, 2, 3 }, MySQL = { 8, 0, 16 } }

--- '10.11.6-MariaDB-1:10.11.6+maria~ubu2204' or '8.0.35' → 'MariaDB' or 'MySQL', and the version, or nil.
---@param v string
local function readVersion(v)
    local a, b, c = tostring(v):match('^(%d+)%.(%d+)%.(%d+)')
    if not a then return nil end
    return tostring(v):find('MariaDB', 1, true) and 'MariaDB' or 'MySQL', { tonumber(a), tonumber(b), tonumber(c) }
end

--- Below the minimum: the words for the setup report and the console, or nil.
---@param kind string
---@param ver number[]
---@return string|nil
local function tooOld(kind, ver)
    local min = MINIMUM[kind]
    for i = 1, 3 do
        if ver[i] ~= min[i] then
            if ver[i] > min[i] then return nil end
            return ('%s %d.%d.%d is older than whip needs (%s %d.%d.%d or newer)')
                :format(kind, ver[1], ver[2], ver[3], kind, min[1], min[2], min[3])
        end
    end
    return nil
end

--- The database server, once whip_core has reached it: { text = '10.11.6-MariaDB', kind, problem = words|nil }.
DbHealth.server = nil

--- Wait until oxmysql has the database. Answers true; or false and why, when it never can without a restart
--- (no connection string). While it waits, it says so every 30 s.
---@return boolean ok
---@return string|nil why
function DbHealth.waitForDatabase()
    -- oxmysql reads the connection string once, as it starts: missing, nothing short of a restart connects.
    if GetConvar('mysql_connection_string', '') == '' then
        print('^1[whip_core:db] mysql_connection_string is not set. Add this line to server.cfg, above "ensure oxmysql",'
            .. ' with your database\'s user, password and name, then restart the server:^0')
        print('^1[whip_core:db]     set mysql_connection_string "mysql://user:password@localhost/whip"^0')
        return false, 'mysql_connection_string is not set in server.cfg'
    end

    local p, connected = promise.new(), false
    CreateThread(function()
        local ok = pcall(MySQL.ready.await)
        p:resolve(ok)
    end)
    local function sayWaiting(after)
        if connected then return end
        print(('^3[whip_core:db] waited %d s for the database: oxmysql cannot connect (its lines above say why, and it'
            .. ' tries again every 30 s). Check mysql_connection_string in server.cfg: the address, user, password and'
            .. ' database name, and that MySQL or MariaDB is running. Players are told the server is still starting.^0')
            :format(after))
        SetTimeout(30000, function() sayWaiting(after + 30) end)
    end
    SetTimeout(10000, function() sayWaiting(10) end)
    local ok = Citizen.Await(p)
    connected = true
    if not ok then return false, 'oxmysql could not be asked for the database' end

    local okV, v = pcall(MySQL.scalar.await, 'SELECT VERSION()')
    local kind, ver = readVersion(okV and v or '')
    DbHealth.server = { text = okV and tostring(v) or '?', kind = kind, problem = kind and ver and tooOld(kind, ver) or nil }
    if DbHealth.server.problem then print(('^1[whip_core:db] %s.^0'):format(DbHealth.server.problem)) end
    DbHealth.started = true
    return true
end

-- The heartbeat: notices an outage within seconds even when nothing is being saved, and the return. Not before start
-- has reached the database: a database never reached is the start's to say (above), not an outage.
Every('database health', 5000, function()
    if not DbHealth.started then return end
    local ok = probe()
    if ok == true and not DbHealth.up then goUp() end
    if ok == false and DbHealth.up then goDown('SELECT 1 failed') end
    return DbHealth.up and 5000 or 2000
end)
-- (Nobody needs telling on join: a character cannot load while the database is down.)
