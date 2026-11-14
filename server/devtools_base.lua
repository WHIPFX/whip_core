-- ============================================
-- Dev tools — the part of the admin tools the rest of whip_core touches
-- ============================================
--
-- Who has each tool open, how a tool's view is refreshed from somewhere else, and who may use the
-- tools at all. The tools themselves are server/devtools.lua and server/vehicle_manager.lua.

DevTools = {}

--- Who has each tool open: [toolKey] = { [source] = true }. One table, so playerDropped can clean
--- them all at once.
DevTools.viewers = {
    vm   = {},   -- Vehicle Manager
    gm   = {},   -- Garage Manager
    gim  = {},   -- Ground Item Manager
    ib   = {},   -- Item Browser
    pm   = {},   -- Phone Manager
    jm   = {},   -- Job Manager
    sm   = {},   -- Shop Manager
    tw   = {},   -- Time & Weather
    pmgr = {},   -- Player Manager
    sn   = {},   -- Sentinel (server/sentinel.lua fans detections to these viewers)
    sp   = {},   -- Reveal Players (server/dev_players.lua)
    gd   = {},   -- Ground Items Debug (server/dev_ground.lua)
    banks = {},  -- Banks (server/bank_admin.lua)
}

-- ---- Refreshes ----
-- A tool's refresh — "send everyone who has it open the new data" — lives with the tool, in
-- devtools.lua, while the changes it follows happen elsewhere: an item dropped (events_inventory),
-- a garage edited (events_vehicles), a job changed (jobs.lua). The tool registers its refresh here
-- under its viewers key, and everything else asks for it by that key.
local refreshers = {}

--- Register a dev tool's refresh. Once, from the file that builds that tool.
---@param key string  its viewers key: 'gim', 'gm', 'ib', 'jm'
---@param fn function
function DevTools.setRefresh(key, fn)
    refreshers[key] = fn
end

--- Tell whoever has this dev tool open that its data changed. Does nothing when no refresh is
--- registered under the key.
---@param key string
function DevTools.refresh(key)
    local fn = refreshers[key]
    if fn then fn() end
end

-- ---- Permission gate: whip.devtools AND developer mode ----
--
-- Holding whip.devtools is not using it: an account with dev tools turns developer
-- mode on in /w first; until then it is treated exactly as an account without them, everywhere. On, the
-- player wears the `developer` stat ("Developer Access Enabled") in their HUD, where anyone watching the
-- stream sees it, and the switch is logged. Off — the switch, the right taken back, a drop — every tool
-- and overlay goes off with it and the stat comes off.
--
-- Every whip.devtools question comes here: isAllowed, or hasAce / aceRefusal for a check written against
-- any ACE (SecureEvent's `ace`, an action's or a door's `require.ace`). A bare IsPlayerAceAllowed(src,
-- 'whip.devtools') answers only "may turn developer mode on" — isEligible — and is right only for that:
-- who may give or take dev tools, and the staff alerts (a save stall, an identity clash).
--
-- PER SESSION: off at every join, and off for everyone when whip_core restarts. A character swap keeps it
-- (the account holds the right), and the stat goes onto the next character.

local _devOn = {}   -- [source] = true while developer mode is on

--- What a player is told when a dev tool refuses them only because developer mode is off.
DevTools.OFF_REASON = 'Developer mode is off: turn it on in /w'

--- Holds whip.devtools, so may turn developer mode on. NOT "may use dev tools": that is isAllowed.
---
--- A real boolean: IsPlayerAceAllowed answers 1 or false on whip's Lua, never true. Both answers
--- here are true or false, for callers that compare.
---@param source number
---@return boolean
function DevTools.isEligible(source)
    return IsPlayerAceAllowed(source, 'whip.devtools') and true or false
end

---@param source number
---@return boolean
function DevTools.isOn(source)
    return _devOn[source] == true
end

--- May this player use dev tools now: whip.devtools, with developer mode on. The console always may.
---@param source number
---@return boolean
function DevTools.isAllowed(source)
    if source == 0 then return true end
    return _devOn[source] == true and IsPlayerAceAllowed(source, 'whip.devtools') and true or false
end

--- Why `source` may not use `ace` now, or nil when they may. whip.devtools also needs developer mode on;
--- any other ACE is FiveM's answer alone.
---@param source number
---@param ace string
---@return string|nil
function DevTools.aceRefusal(source, ace)
    if not IsPlayerAceAllowed(source, ace) then return 'ACE denied: ' .. tostring(ace) end
    if ace == 'whip.devtools' and source ~= 0 and _devOn[source] ~= true then return DevTools.OFF_REASON end
    return nil
end

---@param source number
---@param ace string
---@return boolean
function DevTools.hasAce(source, ace)
    return DevTools.aceRefusal(source, ace) == nil
end

--- [source] = when they were last told developer mode is off, so a screen firing several events at
--- once says it once.
local _offSaid = {}

--- Tell an admin a dev tool refused them because developer mode is off — the one refusal they can fix
--- themselves. At most once every 3 seconds.
---@param source number
function DevTools.sayOff(source)
    if source == 0 then return end
    local now = GetGameTimer()
    if _offSaid[source] and now - _offSaid[source] < 3000 then return end
    _offSaid[source] = now
    ShowError(source, DevTools.OFF_REASON)
end

--- Run after a player's developer mode changes: fn(source, on). For what was decided once from their
--- ACE and sent to their game (an admin-only point or prompt), which has to be decided again.
local _modeHooks = {}

---@param fn fun(source: number, on: boolean)
function DevTools.onModeChange(fn)
    _modeHooks[#_modeHooks + 1] = fn
end

--- Where a player stands, for the log row, or nil.
local function standing(source)
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return nil end
    return GetEntityCoords(ped)
end

--- Turn developer mode on or off. `why` is said in the log ('switch', 'taken back', 'dropped').
---@param source number
---@param on boolean
---@param why string|nil
---@return boolean ok, string|nil err
function DevTools.setMode(source, on, why)
    on = on == true
    if on and not DevTools.isEligible(source) then return false, 'You do not have dev tools' end
    if (_devOn[source] == true) == on then return true end
    _devOn[source] = on or nil

    if not on then
        -- Out of every tool's audience: no more live data, whichever tool it was.
        for _, set in pairs(DevTools.viewers) do set[source] = nil end
    end
    -- The HUD's mark. A player on the character screen has no stats; Character 'loaded' puts it on.
    Stats.showDeveloper(source, on)
    TriggerClientEvent('whip_core:client:devMode', source, on)
    for _, fn in ipairs(_modeHooks) do
        local ok, err = pcall(fn, source, on)
        if not ok then print(('[whip_core:dev] a developer mode hook failed: %s'):format(tostring(err))) end
    end

    -- LOGGED: the console, and the activity log under the character (where they stood, so it can be found).
    local p = Players[source]
    local who = ('%s (%s, id %d)'):format(p and p.fullName or 'no character', GetPlayerName(source) or '?', source)
    local said = ('developer mode %s%s'):format(on and 'ON' or 'OFF', why and why ~= 'switch' and (' (' .. why .. ')') or '')
    print(('^3[whip_core:dev] %s: %s^0'):format(who, said))
    local at = standing(source)
    Log.write(p and p.charId or nil, on and 'dev_mode_on' or 'dev_mode_off', {
        detail = ('%s, account %s'):format(said, GetPlayerName(source) or '?'),
        x = at and at.x, y = at and at.y, z = at and at.z,
    })
    return true
end

-- A new character wears the mark too: stats are the character's, and the right is the account's.
Character.onLife('loaded', function(e)
    local src = e and e.source
    if src and _devOn[src] then Stats.showDeveloper(src, true) end
end)

-- The mark switched on or off in /whip Config (HudDeveloperMark): everyone in developer mode now, at once.
Settings.onChange('HudDeveloperMark', function()
    for src in pairs(_devOn) do
        if Players[src] then Stats.showDeveloper(src, true) end
    end
end)

-- ============================================
-- The first admin
-- ============================================
-- whip's admin tools are the whip.devtools ACE, from server.cfg. A player without it who asks for them (/w, /whip) is
-- told so in game, and the server console gets the line that makes them an admin, once per player per visit: an
-- owner joins, types /w, and copies the line, with no licence to look up.

local _hinted = {}   -- [source] = true: the console has had this player's line

--- `source` was refused the admin tools: print the line that would make them an admin.
---@param source number
function DevTools.askedForTools(source)
    if source == 0 or DevTools.isEligible(source) then return end
    if _hinted[source] then return end
    _hinted[source] = true
    local license = GetPlayerIdentifierByType(source, 'license')
    if not license then return end
    print(('^3[whip_core] %s (id %d) asked for the admin tools, and is not an admin. To make them one, type this line'
        .. ' in this console (it works at once), and add it to server.cfg to keep it:^0'):format(GetPlayerName(source) or '?', source))
    print(('^3[whip_core]     add_ace identifier.%s whip.devtools allow^0'):format(license))
end

--- /w, for a player it refused (tools/core.lua): the console line. The server checks for itself.
SecureEvent('whip_core:devtools:refusedW', {
    requirePlayer = false, whileDead = true, rateLimit = 2000,
}, function(source)
    DevTools.askedForTools(source)
end)

AddEventHandler('playerDropped', function()
    local src = source
    _hinted[src] = nil
    if _devOn[src] then
        -- Said, so the console never shows a session left on.
        _devOn[src] = nil
        print(('^3[whip_core:dev] %s (id %d): developer mode OFF (left the server)^0'):format(GetPlayerName(src) or '?', src))
    end
    _offSaid[src] = nil
    -- Every tool's audience, the ones player_lifecycle's drop names one by one and any added since.
    for _, set in pairs(DevTools.viewers) do set[src] = nil end
end)

--- "Do I have dev tools, and is developer mode on?" — what /w opens to. No ACE gate: anyone may ask
--- about themselves; a player without dev tools is told so and the menu stays shut.
SecureCallback('whip_core:devtools:access', {
    rateLimit = 500,
    burst = 4,   -- the login ask, /w, and a switch's check can all land together
    whileDead = true,
    requirePlayer = false,
}, function(source)
    local eligible = DevTools.isEligible(source) == true
    return { eligible = eligible, on = DevTools.isOn(source) }
end)

--- The /w switch, dead or not, with a character or not. The default rate (ten at once) is all it holds
--- to: the client turns everything off itself, and asks again if the server's off did not land.
SecureCallback('whip_core:devtools:setMode', {
    whileDead = true,
    requirePlayer = false,
    params = { {'on', 'bool'} },
}, function(source, _, on)
    local ok, err = DevTools.setMode(source, on, 'switch')
    if not ok then return false, err end
    return true
end)

--- For satellites: may this player use dev tools now (whip.devtools, developer mode on)? A satellite
--- asking IsPlayerAceAllowed(src, 'whip.devtools') itself skips developer mode; ask this.
exports('HasDevTools', function(source)
    return DevTools.isAllowed(tonumber(source) or -1)
end)

--- For tools: turn a player's developer mode on or off as their /w switch does (a tool acting for a player who is
--- not at the game: whip_devlink keeps it on across whip_core restarts). On only for a player with dev tools; logged
--- with the resource that asked.
exports('SetDeveloperMode', function(source, on)
    local by = GetInvokingResource() or 'a resource'
    return DevTools.setMode(tonumber(source) or -1, on == true, by)
end)

--- Send to every viewer of a dev tool who STILL holds the permission: an admin demoted while a panel
--- is open must stop receiving live data (every player's events, Sentinel detections, the player list
--- with licences). Every push asks again, and a viewer who fails is dropped from the set. The close
--- events take no ACE: leaving is never refused.
---@param viewers table  [source] = true
---@param fn fun(src: number)
---@param ace string|nil  the permission the tool is gated on (default whip.devtools)
function DevTools.eachViewer(viewers, fn, ace)
    ace = ace or 'whip.devtools'
    for src in pairs(viewers) do
        if DevTools.hasAce(src, ace) then
            fn(src)
        else
            viewers[src] = nil
            -- Lost by any road (the console, txAdmin): their tools go off as well. With
            -- developer mode on, that is developer mode going off; with it off, the tools are off already.
            if ace == 'whip.devtools' and _devOn[src] then
                DevTools.setMode(src, false, 'dev tools lost')
                TriggerClientEvent('whip_core:client:devtoolsRevoked', src)
            end
        end
    end
end

RegisterCommand('w', function() end, true)

--- "May I open the dev tools?" — true for a holder of whip.devtools; anyone else is refused, and a
--- refused callback answers `false, 'ACE denied: whip.devtools'`. Test it as `== true`.
--- whip_core:-prefixed like every whip_core callback; satellites ask it too.
SecureCallback('whip_core:devtools:checkAccess', {
    ace = 'whip.devtools',
    requirePlayer = false,
}, function()
    return true
end)
