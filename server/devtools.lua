-- ============================================
-- Dev Tool Events — server/devtools.lua
-- The /w admin panel's server half: its events, each gated on the whip.devtools ace. Loaded
-- late in the manifest, so every module's globals (GroundSync, ...) exist.
-- Public exports do not belong here; they live with the module that owns them.
-- ============================================

-- ============================================
-- Player Manager (Admin Tool)
-- ============================================

--- The ban and admin-note tables. A function, so start-up builds them in its ordered list
--- (player_lifecycle.lua).
---@return boolean ok
function EnsureAdminTables()
    -- The four identifier indexes serve the ban check every connecting player goes through.
    local okBans = CreateTable('bans', [[CREATE TABLE IF NOT EXISTS `bans` (
        `banId` INT UNSIGNED NOT NULL AUTO_INCREMENT, `userId` INT UNSIGNED NOT NULL,
        `license` VARCHAR(60) DEFAULT NULL, `steam` VARCHAR(25) DEFAULT NULL,
        `discord` VARCHAR(25) DEFAULT NULL, `fivem` VARCHAR(15) DEFAULT NULL,
        `reason` VARCHAR(500) NOT NULL DEFAULT 'No reason provided',
        `duration` INT DEFAULT NULL, `bannedAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        `expiresAt` TIMESTAMP NULL DEFAULT NULL, `bannedBy` INT UNSIGNED DEFAULT NULL,
        `bannedByName` VARCHAR(60) DEFAULT NULL, `unbannedAt` TIMESTAMP NULL DEFAULT NULL,
        `unbannedBy` INT UNSIGNED DEFAULT NULL, `unbannedByName` VARCHAR(60) DEFAULT NULL,
        `active` TINYINT(1) NOT NULL DEFAULT 1,
        PRIMARY KEY (`banId`), INDEX `idx_ban_user` (`userId`), INDEX `idx_ban_active` (`active`),
        INDEX `idx_ban_license` (`license`), INDEX `idx_ban_discord` (`discord`),
        INDEX `idx_ban_fivem` (`fivem`), INDEX `idx_ban_steam` (`steam`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    local okNotes = CreateTable('admin_notes', [[CREATE TABLE IF NOT EXISTS `admin_notes` (
        `noteId` INT UNSIGNED NOT NULL AUTO_INCREMENT, `userId` INT UNSIGNED NOT NULL,
        `note` TEXT NOT NULL, `createdBy` INT UNSIGNED DEFAULT NULL,
        `createdByName` VARCHAR(60) DEFAULT NULL, `createdAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`noteId`), INDEX `idx_note_user` (`userId`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    return okBans and okNotes
end

--- Mark the bans whose time is up as no longer active, so the ban history reads right. Start-up's
--- housekeeping step runs it (player_lifecycle.lua); the connect check already ignores an expired
--- ban either way.
function ExpireBans()
    local ok, err = pcall(MySQL.update.await,
        "UPDATE `bans` SET `active` = 0 WHERE `active` = 1 AND `expiresAt` IS NOT NULL AND `expiresAt` <= NOW()")
    if not ok then print('[whip_core:admin] could not retire expired bans: ' .. tostring(err)) end
end

--- [userId] = the account's sessions with a character in, by server id: one walk of Players.
---@return table<number, table[]>
local function pmSessionsByUser()
    local out = {}
    for _, p in pairs(Players) do
        if p.userId then
            local list = out[p.userId]
            if not list then list = {}; out[p.userId] = list end
            list[#list + 1] = p
        end
    end
    for _, list in pairs(out) do table.sort(list, function(a, b) return a.source < b.source end) end
    return out
end

local function pmGetAllUsers()
    local rows = MySQL.query.await([[
        SELECT u.userId, u.license, u.steam, u.discord, u.fivem, u.name, u.lastSeen, u.createdAt,
        (SELECT GROUP_CONCAT(CONCAT(c.firstName, ' ', c.lastName) SEPARATOR ', ')
         FROM characters c WHERE c.userId = u.userId AND c.deleted IS NULL) as characterNames,
        (SELECT c.charId FROM characters c WHERE c.userId = u.userId AND c.deleted IS NULL
         ORDER BY c.lastPlayed DESC LIMIT 1) as faceCharId,
        (SELECT COUNT(*) FROM bans b WHERE b.userId = u.userId AND b.active = 1
         AND (b.expiresAt IS NULL OR b.expiresAt > NOW())) as activeBans
        FROM users u ORDER BY u.lastSeen DESC
        LIMIT 1000
    ]])
    -- LIMIT 1000, most recently seen first (a live server has years of accounts). Anyone online was
    -- seen at connect, so they are at the top.
    if not rows then return {} end
    -- A ROW A SESSION. One account can have two characters in at once (two clients on one PC share a
    -- license, so they are one user), and each is its own row: its server id, the character it plays,
    -- `sessions` how many the account has in, sent only with Config.PlayerManagerSessionWarn on (the
    -- page's warning is its only use). An account with none is one offline row.
    local warnSessions = Config.PlayerManagerSessionWarn == true
    local sessions = pmSessionsByUser()
    local out = {}
    for _, row in ipairs(rows) do
        local list = sessions[row.userId]
        if not list then
            row.online = false
            out[#out + 1] = row
        else
            for _, p in ipairs(list) do
                local r = {}
                for k, v in pairs(row) do r[k] = v end
                r.online      = true
                r.source      = p.source
                r.currentChar = p.fullName
                r.sessions    = warnSessions and #list or nil
                -- Whose face the list shows (server/portraits.lua): the character being played, else the last.
                if p.charId then r.faceCharId = p.charId end
                out[#out + 1] = r
            end
        end
    end
    return out
end

-- ---- Dev tools until the server restarts ----
--
-- A permanent admin gives a player dev tools from that player's page. It is FiveM's own permission,
-- not a whip flag: the license joins TEMP_GROUP, so every whip.devtools check anywhere (core,
-- satellites, tps_monitor) sees it at once. server.cfg gives that group whip.devtools and /w, not
-- the console, and lets whip_core run add_principal / remove_principal. FiveM does not save a
-- principal added at runtime, so the restart is what takes it away.

local TEMP_GROUP = 'group.whip_devtools'

--- [license] = { userId, name, by }: who has dev tools from the panel, and who gave them.
local tempDevtools = {}

--- Were this player's dev tools given from the panel (until the restart)? Permissions.mayGrant asks it
--- too: a grant is saved, so a temporary admin must not hand one out.
---@param src number
---@return boolean
function DevTools.isTemporary(src)
    local id = GetPlayerIdentifierByType(src, 'license')
    local license = id and id:match('^license:(%x+)$')
    return license ~= nil and tempDevtools[license] ~= nil
end

--- True when the player's whip.devtools comes from server.cfg. Only they may give or take.
---@param src number
---@return boolean
local function isPermanentAdmin(src)
    if not IsPlayerAceAllowed(src, 'whip.devtools') then return false end
    return not DevTools.isTemporary(src)
end

--- 'temporary' (given from the panel), 'permanent' (server.cfg) or nil. Every identifier is asked
--- when they are offline: server.cfg may name a player by steam rather than license.
---@param user table  a `users` row
---@param onlineSource number|nil
---@return string|nil
local function devtoolsStatus(user, onlineSource)
    if user.license and tempDevtools[user.license] then return 'temporary' end
    if onlineSource then
        return IsPlayerAceAllowed(onlineSource, 'whip.devtools') and 'permanent' or nil
    end
    for _, kind in ipairs({ 'license', 'steam', 'discord', 'fivem' }) do
        local value = user[kind]
        if value and value ~= ''
            and IsPrincipalAceAllowed(('identifier.%s:%s'):format(kind, value), 'whip.devtools') then
            return 'permanent'
        end
    end
    return nil
end

--- Every session of this user, a character loaded or not (at character select, logged out to dodge).
--- The ban drops them all; dev tools taken back reach them all.
---@param userId number
---@return number[] sources
local function sessionsOf(userId)
    local sessions = {}
    for src, p in pairs(Players) do
        if p.userId == userId then sessions[#sessions + 1] = src end
    end
    for src, pending in pairs(PendingPlayers) do
        if pending.userId == userId then sessions[#sessions + 1] = src end
    end
    return sessions
end

-- whip_core forgets who it gave them to when it stops, so it takes them back rather than leave
-- access nobody can see or take away.
CoreStop.add(10, 'temporary dev tools: take back', function()
    for license in pairs(tempDevtools) do
        ExecuteCommand(('remove_principal identifier.license:%s %s'):format(license, TEMP_GROUP))
    end
end)

---@param userId number
---@param viewer number|nil  the admin asking; decides canGiveDevtools
local function pmGetUserDetail(userId, viewer, session)
    local user = MySQL.single.await('SELECT * FROM `users` WHERE `userId` = ?', { userId })
    if not user then return nil end

    -- Online status: the session asked for (a row is a session), else the account's first; the others
    -- it has in are named in `otherSessions`.
    local onlineSource, onlinePlayer = nil, nil
    local mine = pmSessionsByUser()[userId] or {}
    for _, p in ipairs(mine) do
        if p.source == session then onlineSource, onlinePlayer = p.source, p end
    end
    if not onlinePlayer and mine[1] then onlineSource, onlinePlayer = mine[1].source, mine[1] end
    local otherSessions = {}
    for _, p in ipairs(mine) do
        if p ~= onlinePlayer then
            otherSessions[#otherSessions + 1] = { source = p.source, charId = p.charId, name = p.fullName }
        end
    end

    -- Characters. Cash is an item, so it is summed from the inventory and aliased as `cash` for the
    -- UI (html/js/player-manager.js), as fuel is below.
    local chars = MySQL.query.await(
        [[SELECT c.charId, c.firstName, c.lastName, DATE_FORMAT(c.dateOfBirth, '%Y-%m-%d') AS dob, c.gender,
                 (SELECT COALESCE(SUM(i.`amount`), 0) FROM `character_inventory` i
                   WHERE i.`charId` = c.`charId` AND i.`item` = 'cash') AS cash,
                 c.health, c.armour, c.isDead, c.lastPlayed, c.createdAt
            FROM `characters` c
           WHERE c.`userId` = ? AND c.`deleted` IS NULL ORDER BY c.charId]],
        { userId }
    ) or {}

    -- Vehicles across all characters, a card each: from whip's own record (Vehicles.context, the Vehicles page's
    -- read), so a card has the car's name, whether it is in the world, its garage's name and its fuel. Newest first.
    local charIds = {}
    for _, c in ipairs(chars) do charIds[#charIds + 1] = c.charId end
    local vehicles = {}
    for _, charId in ipairs(charIds) do
        for _, vehicleId in ipairs(Vehicles.ownedIds(charId)) do
            local v = Vehicles.context(vehicleId)
            if v then
                local garage = v.garage and Garages.get(v.garage)
                vehicles[#vehicles + 1] = {
                    vehicleId = vehicleId, ownerCharId = charId,
                    model = v.model, display = v.displayName, plate = v.plate,
                    state = v.state, spawned = v.spawned,
                    garage = v.garage, garageName = garage and garage.name or nil,
                    fuel = v.stats and v.stats.fuel or nil,
                }
            end
        end
    end
    table.sort(vehicles, function(a, b) return a.vehicleId > b.vehicleId end)

    -- Jobs across all characters
    local jobs = {}
    if #charIds > 0 then
        local placeholders = {}
        for i = 1, #charIds do placeholders[i] = '?' end
        jobs = MySQL.query.await(
            'SELECT je.charId, je.jobId, je.roleId, j.name as jobName, jr.name as roleName, jr.level as roleLevel FROM `job_employees` je JOIN `jobs` j ON j.jobId = je.jobId LEFT JOIN `job_roles` jr ON jr.roleId = je.roleId WHERE je.charId IN (' .. table.concat(placeholders, ',') .. ')',
            charIds
        ) or {}
    end

    -- Bans
    local bans = MySQL.query.await(
        'SELECT * FROM `bans` WHERE `userId` = ? ORDER BY `bannedAt` DESC',
        { userId }
    ) or {}

    -- Notes
    local notes = MySQL.query.await(
        'SELECT * FROM `admin_notes` WHERE `userId` = ? ORDER BY `createdAt` DESC',
        { userId }
    ) or {}

    -- Current state if online: every stat (Current Stats), where they are and what they are in. The stats are the
    -- Stats cache, whip's own answer: the server natives for health and armour are the unreliable ones stats.lua
    -- exists to avoid.
    local stats, position, currentVehicle = nil, nil, nil
    if onlineSource and onlinePlayer then
        stats = Stats.adminRows(onlineSource)
        local ped = GetPlayerPed(onlineSource)
        if ped and ped ~= 0 then
            local coords = GetEntityCoords(ped)
            position = { x = coords.x, y = coords.y, z = coords.z }
            local veh = GetVehiclePedIsIn(ped, false)
            if veh and veh ~= 0 then
                currentVehicle = {
                    model = GetEntityModel(veh),
                    plate = GetVehicleNumberPlateText(veh),
                }
            end
        end
    end

    -- Every permission a resource declared (RegisterPermission), and whether this account holds it: the
    -- Permissions group's Give / Take, so a server owner grants a seller's staff role without code.
    local permissions = {}
    for _, d in ipairs(Permissions.list()) do
        permissions[#permissions + 1] = {
            name = d.name, label = d.label, description = d.description, owner = d.owner,
            held = Permissions.accountHas(user.userId, d.name) == true,
        }
    end

    return {
        userId = user.userId,
        license = user.license,
        steam = user.steam,
        discord = user.discord,
        fivem = user.fivem,
        name = user.name,
        lastSeen = user.lastSeen,
        createdAt = user.createdAt,
        online = onlineSource ~= nil,
        source = onlineSource,
        currentCharId = onlinePlayer and onlinePlayer.charId or nil,
        currentChar = onlinePlayer and onlinePlayer.fullName or nil,
        otherSessions = otherSessions,
        -- Config.PlayerManagerSessionWarn: the page's "ALSO IN" pills. Its characters table says which
        -- character is in on which server id either way.
        warnSessions = Config.PlayerManagerSessionWarn == true,
        stats = stats,
        position = position,
        currentVehicle = currentVehicle,
        characters = chars,
        vehicles = vehicles,
        jobs = jobs,
        bans = bans,
        notes = notes,
        permissions = permissions,
        devtools = devtoolsStatus(user, onlineSource),
        devtoolsBy = user.license and tempDevtools[user.license] and tempDevtools[user.license].by or nil,
        canGiveDevtools = viewer ~= nil and isPermanentAdmin(viewer),
    }
end

-- ---- told, not guessed ----
--
-- After a kick, ban, unban or note the server answers once the write is done (no guessed sleep in
-- the page): the list to everyone viewing it, the changed user's detail to the admin who changed it.

--- Push the list to everyone with the Player Manager open. After a ban or unban, and when a player
--- leaves (player_lifecycle's playerDropped) — a kick's answer, since the kicked player is still in
--- Players until then.
function BroadcastPlayerManagerList()
    if next(DevTools.viewers.pmgr) == nil then return end
    local users = pmGetAllUsers()
    -- plmRefresh, NOT pmRefresh: the Phone Manager owns pmRefresh (see plmClosed).
    DevTools.eachViewer(DevTools.viewers.pmgr, function(src)   -- still allowed
        TriggerClientEvent('whip_core:client:plmRefresh', src, { users = users })
    end)
end

--- [viewer source] = { userId, session }: the session each admin's pane shows, so a pane pushed after a
--- change stays on the same character when the account has two in.
local pmShowing = {}
AddEventHandler('playerDropped', function() pmShowing[source] = nil end)

--- Push one user's detail pane to the admin who just changed it.
---@param source number
---@param userId number
local function pushUserDetail(source, userId)
    if not userId or userId <= 0 then return end
    local showing = pmShowing[source]
    local detail = pmGetUserDetail(userId, source, showing and showing.userId == userId and showing.session or nil)
    if detail then TriggerClientEvent('whip_core:client:plmDetail', source, detail) end
end

-- Get all users (open manager). Registering as a viewer is a side effect of asking, so a re-ask
-- re-registers (harmless, the set is idempotent). Every whip_core callback name starts 'whip_core:'
-- (the reserved prefix).
SecureCallback('whip_core:pmGetAllUsers', {
    ace       = 'whip.devtools',
    -- Generous on purpose: the page renders a nil answer as an EMPTY LIST, so a rate-limited refresh
    -- would look like the server has no users.
    rateLimit = 250,
    burst     = 5,
}, function(source)
    DevTools.viewers.pmgr[source] = true
    return pmGetAllUsers()
end)

-- Get user detail. 'id', not 'int': an id is an address, rejected when malformed rather than
-- clamped onto another user ('id' accepts a numeric string, which JavaScript often sends).
-- `session` is only which of the account's characters in to show (0: its first), never acted on.
SecureCallback('whip_core:pmGetUserDetail', {
    ace       = 'whip.devtools',
    -- Burst room for the same reason as pmGetAllUsers above: a rejected detail fetch leaves
    -- the PREVIOUS user's pane on screen next to the newly selected row.
    rateLimit = 100,
    burst     = 5,
    params    = { {'userId', 'id'}, {'session', 'int', 0, 65535, 0} },
}, function(source, _, userId, session)
    pmShowing[source] = { userId = userId, session = session }
    return pmGetUserDetail(userId, source, session)
end)

-- Activity log, player timeline: every logged action across ALL of a user's characters,
-- newest first, paged backward with beforeId. Generous limit, as pmGetAllUsers.
SecureCallback('whip_core:alPlayer', {
    ace       = 'whip.devtools',
    rateLimit = 200,
    burst     = 5,
    -- userId is an address ('id'). beforeId stays 'any': it is an optional paging cursor, absent
    -- for the first page, and anything unreadable simply means "from the newest".
    params    = { {'userId', 'id'}, {'beforeId', 'any'} },
}, function(_, _, userId, beforeId)
    local rows = MySQL.query.await(
        'SELECT `charId` FROM `characters` WHERE `userId` = ?', { userId }) or {}
    local charIds = {}
    for _, r in ipairs(rows) do charIds[#charIds + 1] = r.charId end
    return Log.playerRows(charIds, tonumber(beforeId) or 0, 30)
end)

-- Activity log, item timeline: one specific instance's whole life, by the uid stamped in
-- its metadata. The panel reaches this by clicking an item on a player's timeline.
SecureCallback('whip_core:alItem', {
    ace       = 'whip.devtools',
    rateLimit = 200,
    burst     = 5,
    params    = { {'uid', 'string', 24}, {'beforeId', 'any'} },
}, function(_, _, uid, beforeId)
    return Log.itemRows(uid, tonumber(beforeId) or 0, 50)
end)

-- Character typeahead for the panel's charId boxes (WP.attachCharPicker): type a name
-- (or an id), get back up to 8 {charId, name, online} candidates. Online characters
-- surface first — the person an admin is typing about is usually on the server right
-- now, and that answer needs no SQL at all. The DB pass then fills the remainder from
-- living characters only (`deleted IS NULL` — a picker must never offer a dead char).
-- rateLimit 150 sits under the JS side's 250ms debounce, so a normal typing cadence
-- never trips it.
SecureCallback('whip_core:wpCharSearch', {
    -- Full admins, and Director admins (giving Director access picks a character). Full admins hold
    -- every permission (server/permissions.lua).
    permission = 'director.admin',
    whileDead = true,
    rateLimit = 150,
    burst     = 5,
    params    = { {'q', 'string', 60} },
}, function(_, _, q)
    local needle = q:lower()
    local results, seen = {}, {}

    for _, p in pairs(Players) do
        if p.charId and p.fullName and (p.fullName:lower():find(needle, 1, true) or tostring(p.charId) == q) then
            results[#results + 1] = { charId = p.charId, name = p.fullName, online = true }
            seen[p.charId] = true
            if #results >= 8 then return results end
        end
    end

    local ok, rows = pcall(MySQL.query.await, [[
        SELECT `charId`, `firstName`, `lastName` FROM `characters`
         WHERE `deleted` IS NULL AND (`charId` = ? OR CONCAT(`firstName`, ' ', `lastName`) LIKE ?)
         LIMIT 8
    ]], { tonumber(q) or 0, '%' .. q .. '%' })
    if ok and rows then
        for _, row in ipairs(rows) do
            if not seen[row.charId] then
                results[#results + 1] = {
                    charId = row.charId,
                    name   = ((row.firstName or '') .. ' ' .. (row.lastName or '')):gsub('^%s+', ''),
                    online = false,
                }
                if #results >= 8 then break end
            end
        end
    end
    return results
end)


-- Close manager.
--
-- plmClosed, NOT pmClosed: the Phone Manager owns that name (further down), and SecureEvent
-- registers one handler per name. The plm prefix matches the tool's own NUI actions.
-- No ACE on any *Closed event: leaving a viewer set is never refused (an admin demoted with a panel
-- open must still close it; the pushes re-check the ACE, DevTools.eachViewer). Nor while dead or at the
-- character screen (whileDead, requirePlayer = false): a close refused there left the admin a viewer for
-- the rest of the session (audit 20, SEC-2). Every close below has the same two.
SecureEvent('whip_core:server:plmClosed', {
    requirePlayer = false, whileDead = true,
    rateLimit = 500, burst = 3,
}, function(source)
    DevTools.viewers.pmgr[source] = nil
    pmShowing[source] = nil
end)

-- ---- Theme swap (dev iteration) ----
--
-- `/whip_theme <resource>` on the client lands here; the answer goes back to THAT client
-- only — a live-preview tool, not a server-wide setting (Config.Theme is the setting,
-- Themes.getActive() the runtime override on top of it — server/themes.lua).
-- '' re-applies whatever the server currently says; 'none' clears to the base look.
-- ACE-gated because it can point a client's NUI at any resource's theme.css.
SecureEvent('whip_core:server:requestThemeSwap', {
    ace = 'whip.devtools',
    rateLimit = 500,
    params = { {'resource', 'string', 64, ''} },
}, function(source, _, resource)
    if resource == '' then resource = Themes.getActive() or Config.Theme end
    if resource == 'none' then resource = nil end
    TriggerClientEvent('whip_core:client:applyTheme', source, resource)
end)

-- ---- Who may act on whom ----
--
-- Nobody kicks or bans someone of their own rank or above, nor lifts a ban that someone above them placed. The ranks:
-- an admin from server.cfg ('permanent'), someone given dev tools from the panel until the restart ('temporary'),
-- everyone else (nil). An owner kicked or banned from the panel could be locked out of their own server.

local RANK = { temporary = 1, permanent = 2 }

---@return string|nil
local function higherRank(a, b) return (RANK[b] or 0) > (RANK[a] or 0) and b or a end

--- Does the rank `actor` stand above the rank `target`?
local function outranks(actor, target) return (RANK[actor] or 0) > (RANK[target] or 0) end

--- A connected player's rank, from their own session.
---@param src number
---@return string|nil
local function rankOfSource(src)
    if not IsPlayerAceAllowed(src, 'whip.devtools') then return nil end
    return DevTools.isTemporary(src) and 'temporary' or 'permanent'
end

--- An account's rank: by its identifiers, which still answer while its session is leaving (a dropped session stays in
--- Players through its final save, and FiveM's ACE check answers false for it), and by its live sessions, which also
--- catch a server.cfg line naming an identifier the table doesn't keep (license2, xbl...).
---@param account table  a `users` row
---@return string|nil
local function accountRank(account)
    local rank = devtoolsStatus(account, nil)
    for _, src in ipairs(sessionsOf(account.userId)) do
        if GetPlayerName(src) then rank = higherRank(rank, devtoolsStatus(account, src)) end
    end
    return rank
end

-- Kick player
--
-- 'id', not 'int': the int type CLAMPS, and an id is an address (a clamped id kicks whoever holds
-- that slot). 'id' rejects instead. Same on pmTeleportTo and pmBringPlayer below.
SecureEvent('whip_core:server:pmKick', {
    rateLimit = 2000,
    ace = 'whip.devtools',
    params = { {'targetSource', 'id'}, {'reason', 'string', 200, 'Kicked by admin'} },
}, function(source, player, targetSource, reason)
    -- Anyone connected: in the world, or at the character screen (PendingPlayers), as Ban does (audit 20, SEC-5).
    if not GetPlayerName(targetSource) then
        NotifyPlayer(source, 'They are not on the server', 'error')
        return
    end
    -- Only someone below the kicking admin (Who may act on whom, above).
    local theirs = rankOfSource(targetSource)
    if not outranks(rankOfSource(source), theirs) then
        return false, theirs == 'permanent' and 'They are an admin in server.cfg: they cannot be kicked from the panel'
            or theirs == 'temporary' and 'Only an admin from server.cfg can kick someone who has dev tools'
            or 'You cannot kick yourself'
    end
    local loaded = Players[targetSource]
    local userId = (loaded or PendingPlayers[targetSource] or {}).userId
    local name = loaded and loaded.fullName or GetPlayerName(targetSource)
    -- Auto-add note. A note that did not save does not stop the kick; the admin is told.
    ---@type boolean, string|integer|nil
    local noted, noteId = false, 'no account yet (still connecting)'
    if userId then
        noted, noteId = pcall(MySQL.insert.await,
            'INSERT INTO `admin_notes` (`userId`, `note`, `createdBy`, `createdByName`) VALUES (?, ?, ?, ?)',
            { userId, 'KICKED: ' .. reason, player.charId, player.fullName }
        )
    end
    if not noted or not noteId then
        print(('[whip_core:admin] the kick note for userId %s did not save: %s'):format(tostring(userId), tostring(noteId)))
        NotifyPlayer(source, 'Kicked, but the note about it did not save', 'error')
    end
    DropPlayer(targetSource, 'Kicked: ' .. reason)
    print(('[whip_core:admin] %s kicked %s: %s'):format(player.fullName, tostring(name), reason))
end)

--- Everyone a ban on this account would turn away, and the highest dev-tools rank among them ('permanent',
--- 'temporary' or nil). The ban row keeps the account's license, steam, discord and fivem, and the connect check
--- refuses a match on any one, so another account sharing one of them (the owner's second Rockstar account, with the
--- same Discord) is shut out with it. Each account is ranked by accountRank.
---@param user table  the `users` row being banned
---@return table[] accounts, string|nil rank, string|nil own  own: the banned account's rank alone
local function banReach(user)
    local where, args = {}, {}
    for _, kind in ipairs({ 'license', 'steam', 'discord', 'fivem' }) do
        local value = user[kind]
        if value and value ~= '' then
            where[#where + 1] = ('`%s` = ?'):format(kind)
            args[#args + 1] = value
        end
    end
    local accounts = #where > 0
        and MySQL.query.await('SELECT * FROM `users` WHERE ' .. table.concat(where, ' OR '), args) or nil
    if not accounts or #accounts == 0 then accounts = { user } end

    local best, own
    for _, account in ipairs(accounts) do
        local rank = accountRank(account)
        best = higherRank(best, rank)
        if account.userId == user.userId then own = rank end
    end
    return accounts, best, own
end

-- Ban player
SecureEvent('whip_core:server:pmBan', {
    rateLimit = 2000,
    ace = 'whip.devtools',
    -- Permanent is said, not inferred from "0 seconds" (where a broken duration would land).
    params = { {'userId', 'id'}, {'reason', 'string', 500, 'No reason provided'},
               {'durationSeconds', 'int', 0, 999999999, 0}, {'permanent', 'bool', false} },
}, function(source, player, userId, reason, durationSeconds, permanent)
    if permanent then
        durationSeconds = 0
    elseif durationSeconds <= 0 then
        return false, 'A timed ban needs a duration'
    end

    -- Get user identifiers
    local user = MySQL.single.await('SELECT * FROM `users` WHERE `userId` = ?', { userId })
    if not user then return end

    -- Nobody bans someone who outranks them, nor anyone the ban would also turn away (banReach). An admin from
    -- server.cfg is never banned from the panel: the ban would lock the owner out, and only the database would let
    -- them back in. Their server.cfg line comes out first. Someone given dev tools from the panel is banned only by an
    -- admin from server.cfg, never by another admin given them the same way.
    local reach, rank, own = banReach(user)
    if rank == 'permanent' then
        return false, own == 'permanent'
            and 'They are an admin in server.cfg: take them out of it before banning them'
            or 'That ban would also turn away an admin from server.cfg, who shares an identifier with them'
    end
    if rank == 'temporary' and not isPermanentAdmin(source) then
        return false, 'Only an admin from server.cfg can ban someone who has dev tools'
    end

    local expiresAt = nil
    if durationSeconds > 0 then
        expiresAt = os.date('%Y-%m-%d %H:%M:%S', os.time() + durationSeconds)
    end

    -- Checked before anyone is dropped: with no ban row, a dropped player just reconnects.
    local saved, banId = pcall(MySQL.insert.await,
        'INSERT INTO `bans` (`userId`, `license`, `steam`, `discord`, `fivem`, `reason`, `duration`, `expiresAt`, `bannedBy`, `bannedByName`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        { userId, user.license, user.steam, user.discord, user.fivem, reason, durationSeconds > 0 and durationSeconds or nil, expiresAt, player.charId, player.fullName }
    )
    if not saved or not banId then
        print(('[whip_core:admin] the ban on userId %d did not save: %s'):format(userId, tostring(banId)))
        return false, 'The ban did not save, so nobody was dropped. Check the server console.'
    end

    -- Kick EVERY session of this user, loaded or not (one at character select too): the ban itself
    -- is only checked at connect. Collected first; dropping mutates both tables.
    for _, src in ipairs(sessionsOf(userId)) do
        DropPlayer(src, 'Banned: ' .. reason)
    end

    -- Dev tools given from the panel go with the ban, from every account it turns away. Being dropped is not enough:
    -- a ban that ends before the restart would let them back in with the tools.
    for _, account in ipairs(reach) do
        local license = type(account.license) == 'string' and account.license:match('^%x+$')
        if license and tempDevtools[license] then
            ExecuteCommand(('remove_principal identifier.license:%s %s'):format(license, TEMP_GROUP))
            tempDevtools[license] = nil
        end
    end

    print(('[whip_core:admin] %s banned userId %d: %s (duration: %s)'):format(
        player.fullName, userId, reason, durationSeconds > 0 and (durationSeconds .. 's') or 'permanent'))

    -- Refresh all PM viewers, and the banning admin's detail pane.
    BroadcastPlayerManagerList()
    pushUserDetail(source, userId)
end)

-- Unban — one ban by its id, OR every active ban for a user.
--
-- The Player Manager's actions-bar "Unban" knows the USER, not which ban row is active, so "unban
-- this user" is its own case. Ids are rejected rather than clamped ('id').
SecureEvent('whip_core:server:pmUnban', {
    rateLimit = 2000,
    ace = 'whip.devtools',
    params = { {'banId', 'id', 0}, {'userId', 'id', 0} },   -- 0 = not given
}, function(source, player, banId, userId)
    -- Not a ban that someone above this admin placed (Who may act on whom). The placer is the account behind the
    -- character that placed it, ranked now. A ban with no placer on record (none written, the character gone) counts
    -- as an admin from server.cfg's.
    local placed
    if banId > 0 then
        placed = MySQL.query.await('SELECT `bannedBy` FROM `bans` WHERE `banId` = ? AND `active` = 1', { banId })
    elseif userId > 0 then
        placed = MySQL.query.await('SELECT `bannedBy` FROM `bans` WHERE `userId` = ? AND `active` = 1', { userId })
    end
    -- (if/else, not `a and b or c`: a placer with no rank at all is a nil the shortcut would turn into 'permanent')
    local mine, asked = rankOfSource(source), {}   -- asked: [charId] = rank, or false for none
    for _, row in ipairs(placed or {}) do
        local by = tonumber(row.bannedBy)
        local placer = 'permanent'
        if by then
            if asked[by] == nil then
                local account = MySQL.single.await([[SELECT u.* FROM `characters` c JOIN `users` u ON u.`userId` = c.`userId`
                    WHERE c.`charId` = ?]], { by })
                if account then asked[by] = accountRank(account) or false else asked[by] = 'permanent' end
            end
            placer = asked[by]
        end
        if outranks(placer, mine) then
            return false, 'An admin above you placed that ban: only someone of their rank can lift it'
        end
    end

    if banId > 0 then
        local ok, err = pcall(MySQL.update.await,
            'UPDATE `bans` SET `active` = 0, `unbannedAt` = NOW(), `unbannedBy` = ?, `unbannedByName` = ? WHERE `banId` = ?',
            { player.charId, player.fullName, banId }
        )
        if not ok then
            print(('[whip_core:admin] unbanning banId #%d failed: %s'):format(banId, tostring(err)))
            return false, 'The unban did not save. Check the server console.'
        end
        print(('[whip_core:admin] %s unbanned banId #%d'):format(player.fullName, banId))
    elseif userId > 0 then
        local ok, err = pcall(MySQL.update.await,
            'UPDATE `bans` SET `active` = 0, `unbannedAt` = NOW(), `unbannedBy` = ?, `unbannedByName` = ? WHERE `userId` = ? AND `active` = 1',
            { player.charId, player.fullName, userId }
        )
        if not ok then
            print(('[whip_core:admin] lifting the bans of userId %d failed: %s'):format(userId, tostring(err)))
            return false, 'The unban did not save. Check the server console.'
        end
        print(('[whip_core:admin] %s lifted every active ban for userId %d'):format(player.fullName, userId))
    else
        RecordEventRejection('whip_core:server:pmUnban', source, 'no ban or user named')
        return
    end
    -- The list's ban count and the unbanning admin's detail pane. The panel sends the user
    -- with either kind of unban.
    BroadcastPlayerManagerList()
    pushUserDetail(source, userId)
end)

-- Give or take one of the permissions a resource declared (the Permissions group): for this admin, only one they
-- may hand out themselves (Permissions.mayGrant: a full admin may give any).
SecureEvent('whip_core:server:pmPermission', {
    rateLimit = 500,
    ace = 'whip.devtools',
    params = { {'userId', 'id'}, {'name', 'string', 64}, {'on', 'bool'} },
}, function(source, _, userId, name, on)
    if not Permissions.get(name) then return false, 'No permission called ' .. tostring(name) end
    if not Permissions.mayGrant(source, name) then return false, 'You may not hand that one out' end
    local ok, why
    if on then ok, why = Permissions.grant(userId, name, source) else ok, why = Permissions.revoke(userId, name, source) end
    if not ok then return false, why end
    pushUserDetail(source, userId)
end)

-- Add note
SecureEvent('whip_core:server:pmAddNote', {
    rateLimit = 1000,
    ace = 'whip.devtools',
    params = { {'userId', 'id'}, {'note', 'string', 2000, ''} },
}, function(source, player, userId, note)
    if note == '' then return end
    local ok, noteId = pcall(MySQL.insert.await,
        'INSERT INTO `admin_notes` (`userId`, `note`, `createdBy`, `createdByName`) VALUES (?, ?, ?, ?)',
        { userId, note, player.charId, player.fullName }
    )
    if not ok or not noteId then
        print(('[whip_core:admin] a note on userId %d did not save: %s'):format(userId, tostring(noteId)))
        return false, 'The note did not save. Check the server console.'
    end
    pushUserDetail(source, userId)   -- the pane with the note on it
end)

-- Rename a character (Josh, 1 Nov): the name only. The charId and everything kept by it stay (Character.rename).
-- The account is read from the character, not taken from the page; a note on it says who renamed whom.
SecureEvent('whip_core:server:pmRenameChar', {
    rateLimit = 1000,
    ace = 'whip.devtools',
    params = { {'charId', 'id'}, {'firstName', 'string', 40, ''}, {'lastName', 'string', 40, ''} },
}, function(source, player, charId, firstName, lastName)
    local okRow, rows = pcall(MySQL.query.await,
        'SELECT `userId` FROM `characters` WHERE `charId` = ? AND `deleted` IS NULL LIMIT 1', { charId })
    local userId = okRow and rows and rows[1] and tonumber(rows[1].userId) or nil
    if not userId then return false, 'No such character' end

    local ok, nameOrWhy, oldName = Character.rename(charId, firstName, lastName, player.fullName)
    if not ok then return false, nameOrWhy end
    if oldName ~= nameOrWhy then
        pcall(MySQL.insert.await,
            'INSERT INTO `admin_notes` (`userId`, `note`, `createdBy`, `createdByName`) VALUES (?, ?, ?, ?)',
            { userId, ('RENAMED character #%d: %s -> %s'):format(charId, oldName, nameOrWhy), player.charId, player.fullName })
        NotifyPlayer(source, ('#%d is now %s'):format(charId, nameOrWhy), 'success')
    end
    BroadcastPlayerManagerList()   -- the list shows their characters' names
    pushUserDetail(source, userId)
end)

-- Delete note. userId rides along for the answer: the detail pane it came from (0 = not given).
SecureEvent('whip_core:server:pmDeleteNote', {
    rateLimit = 1000,
    ace = 'whip.devtools',
    params = { {'noteId', 'id'}, {'userId', 'id', 0} },
}, function(source, _, noteId, userId)
    local ok, err = pcall(MySQL.query.await, 'DELETE FROM `admin_notes` WHERE `noteId` = ?', { noteId })
    if not ok then
        print(('[whip_core:admin] deleting note #%d failed: %s'):format(noteId, tostring(err)))
        return false, 'The note was not deleted. Check the server console.'
    end
    pushUserDetail(source, userId)
end)

-- A stat typed on their page (Current Stats): any registered stat but the developer mark, which Stats.set refuses.
-- Clamped to the stat's range there. The admin's pane comes back with the new value.
SecureEvent('whip_core:server:pmSetStat', {
    rateLimit = 250,
    burst = 4,
    ace = 'whip.devtools',
    params = { {'targetSource', 'id'}, {'stat', 'string', 40}, {'value', 'number'} },  -- reject-don't-clamp: see pmKick
}, function(source, player, targetSource, stat, value)
    local target = Players[targetSource]
    if not target then
        NotifyPlayer(source, 'They are not in the world', 'error')
        return
    end
    local ok, why = Stats.set(targetSource, stat, value, 'pm:admin')
    if not ok then return false, why end
    print(('[whip_core:admin] %s set %s\'s %s to %s'):format(player.fullName, tostring(target.fullName), stat,
        tostring(Stats.get(targetSource, stat))))
    pushUserDetail(source, target.userId)
end)

-- Teleport admin to player
SecureEvent('whip_core:server:pmTeleportTo', {
    rateLimit = 1000,
    ace = 'whip.devtools',
    params = { {'targetSource', 'id'} },  -- reject-don't-clamp: see pmKick
}, function(source, _, targetSource)
    local tgtPed = GetPlayerPed(targetSource)
    if not Players[targetSource] or not tgtPed or tgtPed == 0 then
        NotifyPlayer(source, 'They are not in the world', 'error')
        return
    end
    local coords = GetEntityCoords(tgtPed)
    TriggerClientEvent('whip_core:client:pmTeleport', source, coords.x, coords.y, coords.z)
end)

-- Bring player to admin
SecureEvent('whip_core:server:pmBringPlayer', {
    rateLimit = 1000,
    ace = 'whip.devtools',
    params = { {'targetSource', 'id'} },  -- reject-don't-clamp: see pmKick
}, function(source, _, targetSource)
    local srcPed = GetPlayerPed(source)
    if not srcPed or srcPed == 0 then return end
    if not Players[targetSource] then
        NotifyPlayer(source, 'They are not in the world', 'error')
        return
    end
    local coords = GetEntityCoords(srcPed)
    TriggerClientEvent('whip_core:client:pmTeleport', targetSource, coords.x, coords.y, coords.z)
end)

-- A PICTURE OF THEIR GAME, for their page (html/js/wp/playerManager.js keeps it a few minutes): what they see, whip's
-- interface (their HUD) drawn over the game, at about the pane's size; where they stood comes with it, for the map
-- beside it. One ask per player at a time: an admin asking while one is on its way gets that one too. It goes to the
-- admin slowly (a latent event), as it came from the player.
local PM_SHOT = { format = 'jpg', quality = 0.8, width = 960, ui = true }
local PM_SHOT_BPS = 1000000
local pmShooting = {}   -- [target source] = { [admin source] = true }

SecureEvent('whip_core:server:pmShot', {
    -- Opening a player's page asks, so going down the list asks often (the page waits a moment first).
    rateLimit = 250,
    burst = 4,
    ace = 'whip.devtools',
    params = { {'targetSource', 'id'} },  -- reject-don't-clamp: see pmKick
}, function(source, player, targetSource)
    local waiting = pmShooting[targetSource]
    if waiting then
        waiting[source] = true
        return
    end
    waiting = { [source] = true }
    pmShooting[targetSource] = waiting
    CreateThread(function()
        -- Caught: an error left in the slot would hold every later ask for this player.
        local ok, data, why = pcall(Screenshot.request, targetSource, PM_SHOT)
        pmShooting[targetSource] = nil
        if not ok then
            print(('[whip_core:admin] a picture of player %d failed: %s'):format(targetSource, tostring(data)))
            data, why = false, 'the picture failed'
        end
        ---@type table|false
        local pos = false
        if data then
            local target = Players[targetSource]
            print(('[whip_core:admin] %s took a picture of %s\'s game'):format(tostring(player and player.fullName),
                tostring(target and target.fullName or GetPlayerName(targetSource))))
            local ped = GetPlayerPed(targetSource)
            if ped and ped ~= 0 then
                local c = GetEntityCoords(ped)
                pos = { x = c.x, y = c.y, z = c.z }
            end
        end
        for admin in pairs(waiting) do
            if GetPlayerName(admin) and DevTools.hasAce(admin, 'whip.devtools') then
                if data then
                    TriggerLatentClientEvent('whip_core:client:plmShot', admin, PM_SHOT_BPS, targetSource, data, false, pos)
                else
                    TriggerClientEvent('whip_core:client:plmShot', admin, targetSource, false, why)
                end
            end
        end
    end)
end)

-- /w Kill Me (tools/player.lua): an admin's own client is told to drop its ped's health to zero. The death
-- that follows is an ordinary one, reported and checked against the ped like any other (MarkPlayerDead).
SecureEvent('whip_core:server:devKillMe', {
    rateLimit = 1000,
    ace = 'whip.devtools',
}, function(source, player)
    if not player then return false, 'No character loaded' end
    if player.isDead then return false, 'You are already down' end
    print(('[whip_core] %s downed themselves (/w Kill Me)'):format(tostring(player.fullName)))
    TriggerClientEvent('whip_core:client:devKillMe', source)
end)

-- /w Restore Health & Armour (tools/player.lua). Stats.set clamps to each stat's own max, so an
-- over-large value is "full" without knowing the numbers.
--
-- Dead, it revives you first, the way /whip_revive does: MarkPlayerAlive (the server's record, full
-- health, the revived hooks) and the client's revive, which stands the ped up and ends the death
-- screen before it returns. The full health and armour set after it land on the living ped.
-- (Accepted while dead: an `ace` event is an admin tool, not the character acting.)
SecureEvent('whip_core:server:devRestore', {
    rateLimit = 1000,
    ace = 'whip.devtools',
}, function(source, player)
    local revived = false
    if player and player.isDead then
        MarkPlayerAlive(source, player, 'revive:admin')
        TriggerClientEvent('whip_core:client:revive', source)
        revived = true
        print(('[whip_core] %s revived themselves (/w Restore Health & Armour)'):format(tostring(player.fullName)))
    end
    for _, name in ipairs({ 'health', 'armour' }) do
        Stats.set(source, name, 1e9, 'devtools:restore')
    end
    ShowSuccess(source, revived and 'Revived, with health and armour restored' or 'Health and armour restored')
end)

-- /w Repair Vehicle (tools/player.lua): the car the admin is in, DRIVING IT OR NOT.
-- Repair natives need network control, and a car another player drives belongs to that player's game,
-- so the server finds the car and asks the game that owns it to do the repair.
SecureEvent('whip_core:server:devRepairVehicle', {
    rateLimit = 1000,
    ace = 'whip.devtools',
}, function(source)
    local ped = GetPlayerPed(source)
    local veh = (ped and ped ~= 0) and GetVehiclePedIsIn(ped, false) or 0
    if not veh or veh == 0 or not DoesEntityExist(veh) then return false, 'You are not in a vehicle' end
    local owner = NetworkGetEntityOwner(veh)
    if type(owner) ~= 'number' or owner <= 0 then owner = source end   -- nobody holds it: the admin's game takes it
    -- A whip car's kept damage too, or its next spawn puts it back (vehicle_damage.lua).
    local vehicleId = Vehicles.getEntityVehicleId(veh)
    if vehicleId then VehicleDamage.clear(vehicleId) end
    TriggerClientEvent('whip_core:client:devRepairVehicle', owner, NetworkGetNetworkIdFromEntity(veh))
    ShowSuccess(source, 'Vehicle repaired')
end)

-- Give or take dev tools until the server restarts (TEMP_GROUP, above).
SecureEvent('whip_core:server:pmSetDevtools', {
    rateLimit = 1000,
    ace = 'whip.devtools',
    params = { {'userId', 'id'}, {'give', 'bool', false} },
}, function(source, player, userId, give)
    -- Permanent admins only: someone given dev tools here cannot hand them on.
    if not isPermanentAdmin(source) then
        return false, 'Only an admin from server.cfg can give or take dev tools'
    end
    local user = MySQL.single.await(
        'SELECT `userId`, `license`, `steam`, `discord`, `fivem`, `name` FROM `users` WHERE `userId` = ?', { userId })
    if not user then return false, 'That player is not in the database' end
    -- Hex only: the license goes into a console command.
    local license = type(user.license) == 'string' and user.license:match('^%x+$')
    if not license then return false, 'That player has no license to give dev tools to' end
    local principal = 'identifier.license:' .. license
    local who = user.name or ('userId ' .. userId)
    local online = PlayersByUserId[userId]
    local onlineSource = online and online.source

    if give then
        local status = devtoolsStatus(user, onlineSource)
        if status == 'permanent' then return false, who .. ' already has dev tools from server.cfg' end
        if status == 'temporary' then
            pushUserDetail(source, userId)
            return
        end
        ExecuteCommand(('add_principal %s %s'):format(principal, TEMP_GROUP))
        if not IsPrincipalAceAllowed(principal, 'whip.devtools') then
            print(('[whip_core:admin] could not give %s dev tools. server.cfg needs:\n'
                .. '  add_ace %s whip.devtools allow\n'
                .. '  add_ace resource.whip_core command.add_principal allow\n'
                .. '  add_ace resource.whip_core command.remove_principal allow'):format(who, TEMP_GROUP))
            return false, 'The server would not give dev tools: server.cfg is missing lines (see the server console)'
        end
        tempDevtools[license] = { userId = userId, name = who, by = player.fullName }
        -- Their client asks again (client/actions.lua): it remembers "no", which would keep the F1
        -- wheel's Dev Tools hidden until they reconnected.
        for _, src in ipairs(sessionsOf(userId)) do
            TriggerClientEvent('whip_core:client:devtoolsGranted', src)
        end
    else
        if not tempDevtools[license] then
            return false, who .. "'s dev tools come from server.cfg, not the panel"
        end
        ExecuteCommand(('remove_principal %s %s'):format(principal, TEMP_GROUP))
        if IsPrincipalAceAllowed(principal, 'whip.devtools') then
            print(('[whip_core:admin] could not take dev tools from %s. server.cfg needs:\n'
                .. '  add_ace resource.whip_core command.remove_principal allow'):format(who))
            return false, 'The server would not take dev tools back (see the server console)'
        end
        tempDevtools[license] = nil
        -- Their tools go off too, on EVERY session, a character loaded or not (God Mode on at character
        -- select would come back on the next ped).
        for _, src in ipairs(sessionsOf(userId)) do
            -- Developer mode off with them: the HUD mark comes off, and the log says why.
            DevTools.setMode(src, false, 'dev tools taken back')
            TriggerClientEvent('whip_core:client:devtoolsRevoked', src)
        end
    end

    local note = give and 'DEV TOOLS given until the server restarts' or 'DEV TOOLS taken back'
    local noted, noteId = pcall(MySQL.insert.await,
        'INSERT INTO `admin_notes` (`userId`, `note`, `createdBy`, `createdByName`) VALUES (?, ?, ?, ?)',
        { userId, note, player.charId, player.fullName }
    )
    if not noted or not noteId then
        print(('[whip_core:admin] the dev tools note for userId %d did not save: %s'):format(userId, tostring(noteId)))
    end
    print(('[whip_core:admin] %s: %s (%s)'):format(player.fullName, note, who))
    if onlineSource then
        NotifyPlayer(onlineSource,
            give and 'You have dev tools until the server restarts (/whip)' or 'Your dev tools were taken back',
            give and 'success' or 'info')
    end
    pushUserDetail(source, userId)
end)

-- The Vehicle Manager lives in server/vehicle_manager.lua, on its own: it touches the vehicle
-- lifecycle and must drive the public API (Vehicles.store / retrieve), never reach past it. Vehicle
-- Adjustments is html/js/wp/vehicleModels.js over its callbacks and Vehicles.saveMeta / saveClassMeta.

-- ============================================
-- Garage Manager — Dev Tool Events
-- ============================================

--- Broadcast full garage list to all open GM viewers. Other files ask with DevTools.refresh('gm').
local function gmBroadcast()
    if not next(DevTools.viewers.gm) then return end
    -- snapshotAll, not getAll. This crosses to a NUI, and the record stays on the server.
    local all = Garages.snapshotAll()
    local counts = Garages.getVehicleCounts()
    DevTools.eachViewer(DevTools.viewers.gm, function(src)
        TriggerClientEvent('whip_core:client:gmAllGarages', src, all, counts)
    end)
end
DevTools.setRefresh('gm', gmBroadcast)

SecureEvent('whip_core:server:gmGetAllGarages', {
    ace = 'whip.devtools',
}, function(source)
    DevTools.viewers.gm[source] = true
    TriggerClientEvent('whip_core:client:gmAllGarages', source,
        Garages.snapshotAll(), Garages.getVehicleCounts())
end)

SecureEvent('whip_core:server:gmClosed', {   -- no ACE: see plmClosed
    requirePlayer = false, whileDead = true,
}, function(source)
    DevTools.viewers.gm[source] = nil
end)

SecureEvent('whip_core:server:gmCreateGarage', {
    ace = 'whip.devtools',
    params = { {'data', 'any'} },
}, function(source, _, data)
    if type(data) ~= 'table' then return end
    local key = Sanitize.key(data.key, 60)
    if not key then
        -- Refusals in these tools are `return false, 'why'`: shown to the admin and recorded in the
        -- Event Monitor as refused.
        return false, 'Key is required'
    end

    data.key        = key
    data.name       = Sanitize.string(data.name, 100, key)
    data.x          = Sanitize.number(data.x, -10000, 10000)
    data.y          = Sanitize.number(data.y, -10000, 10000)
    data.z          = Sanitize.number(data.z, -500, 2000)
    data.heading    = Sanitize.number(data.heading, 0, 360)
    data.spawnX     = Sanitize.number(data.spawnX, -10000, 10000)
    data.spawnY     = Sanitize.number(data.spawnY, -10000, 10000)
    data.spawnZ     = Sanitize.number(data.spawnZ, -500, 2000)
    data.spawnHeading = Sanitize.number(data.spawnHeading, 0, 360)
    data.blipSprite = Sanitize.int(data.blipSprite, 0, 999, 357)
    data.blipColor  = Sanitize.int(data.blipColor, 0, 85, 3)

    local def, err = Garages.create(data)
    if not def then return false, err or 'Failed to create garage' end
    -- Garages.create gave it its first bay (at its spawn point, or the marker where the admin
    -- stood). More bays get added from the panel afterwards.

    ShowSuccess(source,
        ('Garage "%s" created'):format(def.key))
    gmBroadcast()
end)

--- The garage wizard's Create: the garage and every bay it was set out with, in one go
--- (html/js/wp/garages.js). `data` =
--- { key, name, x, y, z, heading (its map marker), blipSprite, blipColor, bays = { { x, y, z, heading } } }.
--- Answers { ok = true, key, failed } or { ok = false, why }.
---
--- Bays with coordinates, leashed to the admin: the wizard's Bays step sets them out in the world and
--- sends them here together. Every bay, and the marker, must be within Config.GarageWizardReach of the
--- admin when Create is pressed (a car park's size), so a garage is made from where it is.
local GW_MAX_BAYS = 40
SecureCallback('whip_core:gmWizardCreate', {
    ace       = 'whip.devtools',
    rateLimit = 2000,
    params    = { {'data', 'any'} },
}, function(source, _, data)
    if type(data) ~= 'table' then return { ok = false, why = 'Nothing to create' } end
    local key = Sanitize.key(data.key, 60)
    if not key then return { ok = false, why = 'Give it a name: its key is made from it' } end
    if Garages.get(key) then return { ok = false, why = ('A garage with the key "%s" exists already'):format(key) } end
    local bays = type(data.bays) == 'table' and data.bays or {}
    if #bays == 0 then return { ok = false, why = 'Set out at least one bay: bays are the only way into a garage' } end
    if #bays > GW_MAX_BAYS then return { ok = false, why = ('A garage has at most %d bays here'):format(GW_MAX_BAYS) } end

    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return { ok = false, why = 'Could not find where you are' } end
    local me = GetEntityCoords(ped)
    local reach = tonumber(Config.GarageWizardReach) or 250.0
    local function near(x, y, z)
        local dx, dy, dz = x - me.x, y - me.y, z - me.z
        return dx * dx + dy * dy + dz * dz <= reach * reach
    end

    local clean = {}
    for i, b in ipairs(bays) do
        if type(b) ~= 'table' or not (tonumber(b.x) and tonumber(b.y) and tonumber(b.z)) then
            return { ok = false, why = ('Bay %d is not a place'):format(i) }
        end
        local x = Sanitize.number(b.x, -10000, 10000)
        local y = Sanitize.number(b.y, -10000, 10000)
        local z = Sanitize.number(b.z, -500, 2000)
        if not near(x, y, z) then
            return { ok = false, why = ('Bay %d is over %d m from you: create the garage from where it is'):format(i, math.floor(reach)) }
        end
        clean[i] = { x = x, y = y, z = z, heading = Sanitize.number(b.heading, -360, 720) % 360.0 }
    end

    -- The marker: as sent, or the bays' middle.
    local mx, my, mz = tonumber(data.x), tonumber(data.y), tonumber(data.z)
    if not (mx and my and mz) then
        mx, my, mz = 0.0, 0.0, 0.0
        for _, b in ipairs(clean) do mx, my, mz = mx + b.x, my + b.y, mz + b.z end
        mx, my, mz = mx / #clean, my / #clean, mz / #clean
    end
    mx, my, mz = Sanitize.number(mx, -10000, 10000), Sanitize.number(my, -10000, 10000), Sanitize.number(mz, -500, 2000)
    if not near(mx, my, mz) then
        return { ok = false, why = ('The map marker is over %d m from you: create the garage from where it is'):format(math.floor(reach)) }
    end

    -- Its first bay is Garages.create's own (GarageSpots.seedGarage, at the spawn point): bay 1. The rest after.
    local first = clean[1]
    local def, err = Garages.create({
        key = key, name = Sanitize.string(data.name, 100, key),
        x = mx, y = my, z = mz, heading = Sanitize.number(data.heading, 0, 360),
        spawnX = first.x, spawnY = first.y, spawnZ = first.z, spawnHeading = first.heading,
        blipSprite = Sanitize.int(data.blipSprite, 0, 999, 357),
        blipColor  = Sanitize.int(data.blipColor, 0, 85, 3),
    })
    if not def then return { ok = false, why = err or 'The garage was not made' } end
    for i = 2, #clean do
        local b = clean[i]
        GarageSpots.create(key, b.x, b.y, b.z, b.heading)
    end

    -- What it has now, counted: a bay the database refused is said, not hidden.
    local made = 0
    for _, s in ipairs(GarageSpots.all()) do
        if s.garageKey == key then made = made + 1 end
    end
    ShowSuccess(source, ('Garage "%s" created with %d bay%s'):format(key, made, made == 1 and '' or 's'))
    gmBroadcast()
    return { ok = true, key = key, failed = #clean - made }
end)

--- Is this point within `reach` of `me`?
local function within(me, reach, x, y, z)
    local dx, dy, dz = x - me.x, y - me.y, z - me.z
    return dx * dx + dy * dy + dz * dz <= reach * reach
end

--- A saved garage's bays as the bay tool left them, checked: `bays` = { { x, y, z, heading, id } } — a bay with an id
--- is one of this garage's (moved, or not), one without is new, and one of its bays not in the list is taken away.
--- At least one bay (they are the only way in); every bay that is new or moved within `reach` of the admin (a bay
--- left where it was is not asked where it is). Nothing is written here: a refusal leaves the garage as it was.
---@return table|nil plan  for applyBays
---@return string|nil why
local function planBays(key, bays, me, reach)
    local have, haveN = {}, 0
    for _, s in ipairs(GarageSpots.all()) do
        if s.garageKey == key then have[s.spotId], haveN = s, haveN + 1 end
    end
    if type(bays) ~= 'table' or #bays == 0 then return nil, 'Leave at least one bay: bays are the only way into a garage' end
    -- More than the tool adds only when the garage had more already: those it keeps.
    if #bays > math.max(GW_MAX_BAYS, haveN) then return nil, ('A garage has at most %d bays here'):format(GW_MAX_BAYS) end

    local clean, kept = {}, {}
    for i, b in ipairs(bays) do
        if type(b) ~= 'table' or not (tonumber(b.x) and tonumber(b.y) and tonumber(b.z)) then
            return nil, ('Bay %d is not a place'):format(i)
        end
        local id = b.id ~= nil and tonumber(b.id) or nil
        if b.id ~= nil and not (id and have[id]) then return nil, ("Bay %d is not one of this garage's"):format(i) end
        if id and kept[id] then return nil, ('Bay #%d is in the list twice'):format(id) end
        if id then kept[id] = true end

        local x = Sanitize.number(b.x, -10000, 10000)
        local y = Sanitize.number(b.y, -10000, 10000)
        local z = Sanitize.number(b.z, -500, 2000)
        local h = Sanitize.number(b.heading, -360, 720) % 360.0
        local s = id and have[id]
        local moved = not s or math.abs(s.x - x) > 0.005 or math.abs(s.y - y) > 0.005 or math.abs(s.z - z) > 0.005
            or math.abs(((s.heading or 0.0) - h + 180.0) % 360.0 - 180.0) > 0.05
        if moved and not within(me, reach, x, y, z) then
            return nil, ('Bay %d is over %d m from you: set bays out from where they are'):format(i, math.floor(reach))
        end
        clean[#clean + 1] = { id = id, x = x, y = y, z = z, heading = h, moved = moved }
    end
    return { key = key, clean = clean, have = have, kept = kept }
end

--- Write a plan: moves and new bays first, then what was taken away, so a garage is never left with none on the way.
---@return number added, number moved, number removed, number failed
local function applyBays(plan)
    local added, moved, removed, failed = 0, 0, 0, 0
    for _, b in ipairs(plan.clean) do
        if b.id then
            if b.moved then
                if GarageSpots.update(b.id, b.x, b.y, b.z, b.heading) then moved = moved + 1 else failed = failed + 1 end
            end
        elseif GarageSpots.create(plan.key, b.x, b.y, b.z, b.heading) then added = added + 1
        else failed = failed + 1 end
    end
    for id in pairs(plan.have) do
        if not plan.kept[id] then
            if GarageSpots.delete(id) then removed = removed + 1 else failed = failed + 1 end
        end
    end
    return added, moved, removed, failed
end

--- The garage wizard's Save, for a garage that exists (html/js/wp/garages.js: the page's Change opens
--- the wizard filled in with it). `data` = { key, name?,
--- marker = { x, y, z, heading }?, blipSprite?, blipColor?, bays? } — a part not sent is left as it is, and `bays`
--- carry their ids (planBays). Answers { ok = true, added, moved, removed, failed } or { ok = false, why }; a refusal
--- changes nothing.
---
--- The wizard's rules: public garages only (a private one is its property's), and a marker or a bay that moves must be
--- within Config.GarageWizardReach of the admin — set out from where it is. A name or a blip changes from anywhere.
SecureCallback('whip_core:gmWizardSave', {
    ace       = 'whip.devtools',
    rateLimit = 2000,
    params    = { {'data', 'any'} },
}, function(source, _, data)
    if type(data) ~= 'table' then return { ok = false, why = 'Nothing to save' } end
    local key = Sanitize.key(data.key, 60)
    local g = key and Garages.get(key)
    if not key or not g then return { ok = false, why = 'No such garage' } end
    if Garages.isPrivate(key) then
        return { ok = false, why = "A private garage is its property's: change it in /whip → Properties" }
    end

    local ped = GetPlayerPed(source)
    local me = ped and ped ~= 0 and GetEntityCoords(ped) or nil
    local reach = tonumber(Config.GarageWizardReach) or 250.0

    local fields = {}
    if data.name ~= nil then
        if type(data.name) ~= 'string' or not data.name:match('%S') then return { ok = false, why = 'Give the garage a name' } end
        fields.name = Sanitize.string(data.name, 100, key)
    end
    if type(data.marker) == 'table' then
        local m = data.marker
        local x = Sanitize.number(m.x, -10000, 10000)
        local y = Sanitize.number(m.y, -10000, 10000)
        local z = Sanitize.number(m.z, -500, 2000)
        local moved = math.abs((g.x or 0) - x) > 0.005 or math.abs((g.y or 0) - y) > 0.005 or math.abs((g.z or 0) - z) > 0.005
        if moved and not (me and within(me, reach, x, y, z)) then
            return { ok = false, why = ('The map marker is over %d m from you: move it from where it is'):format(math.floor(reach)) }
        end
        fields.x, fields.y, fields.z = x, y, z
        fields.heading = Sanitize.number(m.heading, 0, 360)
    end
    if data.blipSprite ~= nil then fields.blipSprite = Sanitize.int(data.blipSprite, 0, 999, 357) end
    if data.blipColor ~= nil then fields.blipColor = Sanitize.int(data.blipColor, 0, 85, 3) end

    local plan
    if data.bays ~= nil then
        if not me then return { ok = false, why = 'Could not find where you are' } end
        local why
        plan, why = planBays(key, data.bays, me, reach)
        if not plan then return { ok = false, why = why } end
    end

    if next(fields) then
        local ok, err = Garages.update(key, fields)
        if not ok then return { ok = false, why = err or 'The garage was not saved' } end
    end
    local added, moved, removed, failed = 0, 0, 0, 0
    if plan then added, moved, removed, failed = applyBays(plan) end

    local said = {}
    if added > 0 then said[#said + 1] = ('%d added'):format(added) end
    if moved > 0 then said[#said + 1] = ('%d moved'):format(moved) end
    if removed > 0 then said[#said + 1] = ('%d taken away'):format(removed) end
    ShowSuccess(source, ('Garage "%s" saved'):format(key) .. (#said > 0 and ('  ·  bays: ' .. table.concat(said, ', ')) or ''))
    gmBroadcast()
    return { ok = true, added = added, moved = moved, removed = removed, failed = failed }
end)

SecureEvent('whip_core:server:gmUpdateGarage', {
    ace = 'whip.devtools',
    params = {
        {'key', 'key', 60},
        {'data', 'any'},
    },
}, function(source, _, key, data)
    if type(data) ~= 'table' then return end

    if data.name       ~= nil then data.name       = Sanitize.string(data.name, 100, key) end
    if data.x          ~= nil then data.x          = Sanitize.number(data.x, -10000, 10000) end
    if data.y          ~= nil then data.y          = Sanitize.number(data.y, -10000, 10000) end
    if data.z          ~= nil then data.z          = Sanitize.number(data.z, -500, 2000) end
    if data.heading    ~= nil then data.heading    = Sanitize.number(data.heading, 0, 360) end
    if data.spawnX     ~= nil then data.spawnX     = Sanitize.number(data.spawnX, -10000, 10000) end
    if data.spawnY     ~= nil then data.spawnY     = Sanitize.number(data.spawnY, -10000, 10000) end
    if data.spawnZ     ~= nil then data.spawnZ     = Sanitize.number(data.spawnZ, -500, 2000) end
    if data.spawnHeading ~= nil then data.spawnHeading = Sanitize.number(data.spawnHeading, 0, 360) end
    if data.blipSprite ~= nil then data.blipSprite = Sanitize.int(data.blipSprite, 0, 999, 357) end
    if data.blipColor  ~= nil then data.blipColor  = Sanitize.int(data.blipColor, 0, 85, 3) end

    local ok, err = Garages.update(key, data)
    if not ok then return false, err or 'Failed to update garage' end
    ShowSuccess(source,
        ('Garage "%s" updated'):format(key))
    gmBroadcast()
end)

--- Delete a garage from the panel. `moveTo`: the garage its cars go to.
---
--- A garage with cars in it needs one: the panel asks where they go, and this refuses a delete that
--- does not say. With none stored there, the nearest takes any filed under it (out in the world).
--- Scripts' DeleteGarage uses the nearest.
SecureEvent('whip_core:server:gmDeleteGarage', {
    ace = 'whip.devtools',
    params = { {'key', 'key', 60}, {'moveTo', 'any'} },
}, function(source, _, key, moveTo)
    moveTo = type(moveTo) == 'string' and Sanitize.key(moveTo, 60) or nil
    local inside = Garages.getVehicleCounts()[key] or 0
    if inside > 0 and not moveTo then
        return false, ('Choose where its %d car%s go before deleting it'):format(inside, inside == 1 and '' or 's')
    end

    local ok, err = Garages.delete(key, moveTo)
    if not ok then return false, err or 'Failed to delete garage' end
    local dest = moveTo and Garages.get(moveTo)
    ShowSuccess(source, inside > 0 and dest
        and ('Garage "%s" deleted; its %d car%s moved to %s'):format(key, inside, inside == 1 and '' or 's', dest.name or moveTo)
        or ('Garage "%s" deleted'):format(key))
    gmBroadcast()
end)

SecureEvent('whip_core:server:gmMoveVehicle', {
    ace = 'whip.devtools',
    params = {
        {'vehicleId', 'id'},
        {'toGarageKey', 'key', 60},
    },
}, function(source, _, vehicleId, toGarageKey)

    local veh = Vehicles.context(vehicleId)
    if not veh then
        return false, 'Vehicle not found'
    end

    if not Garages.get(toGarageKey) then
        return false, 'Target garage not found'
    end

    -- Through the funnel, like everything else: a tool must drive the API, not reimplement it.
    local ok, err = Vehicles.persist(vehicleId, { garage = toGarageKey })
    if not ok then
        return false, ('Could not move the vehicle: %s'):format(tostring(err))
    end

    ShowSuccess(source,
        ('Moved %s to %s'):format(veh.plate, toGarageKey))
    gmBroadcast()
end)

SecureEvent('whip_core:server:gmGetGarageVehicles', {
    ace = 'whip.devtools',
    -- 'string', not 'key': a read, and a property's private garage is keyed 'property:<id>', which
    -- the key sanitizer (letters, numbers, _ and -) would refuse. The lookup below is the check.
    params = { {'garageKey', 'string', 60} },
}, function(source, _, garageKey)
    if not Garages.get(garageKey) then return end

    local vehicles = Garages.getGarageVehicles(garageKey)
    TriggerClientEvent('whip_core:client:gmGarageVehicles', source, garageKey, vehicles)
end)

-- ============================================
-- Ground Item Manager — Dev Tool Events
-- ============================================

--- Build item defs lookup for NUI: the name, and where the picture is (see ibBuildItemList's `img`).
local function gimGetItemDefs()
    local defs = {}
    for key, def in pairs(Config.Items) do
        defs[key] = { name = def.name or key, img = Inventory.resolveItemImage(key, def) }
    end
    return defs
end

--- A charId -> name map as the PAGE can read it: the keys as strings.
---
--- The client's SendNUIMessage encodes with lua-rapidjson, which turns a number-keyed table into a
--- JSON ARRAY when the ids run 1..n, the biggest is under 11, or at least half of 1..max are present,
--- and every name then shifts by one. String keys are always an object. The ground and job panels
--- both read these maps.
---@param names table<number, string>
---@return table<string, string>
local function charNamesForPage(names)
    local out = {}
    for charId, name in pairs(names or {}) do out[tostring(charId)] = name end
    return out
end

--- charId -> "First Last" for every ground item's createdBy (ResolveCharNames: cached).
local function gimGetCharNames()
    local charIds = {}
    local seen = {}
    for _, data in pairs(GroundItems.cache) do
        if data.createdBy and not seen[data.createdBy] then
            seen[data.createdBy] = true
            charIds[#charIds + 1] = data.createdBy
        end
    end
    if #charIds == 0 then return {} end
    return charNamesForPage(ResolveCharNames(charIds))
end

--- How long a burst of ground-item changes is gathered into one push.
local GIM_COALESCE_MS = 250
local gimQueued = false

--- Push the full item list to every open viewer: later, once, and not on the caller's thread.
---
--- Every drop, throw, place, split and pickup calls this from inside that PLAYER's handler, so it only
--- marks the list stale; one timer sends it, for any number of changes inside GIM_COALESCE_MS. Nothing
--- waits on it, and with no viewer it costs nothing. Other files ask with DevTools.refresh('gim').
local function gimBroadcast()
    if gimQueued or not next(DevTools.viewers.gim) then return end
    gimQueued = true
    SetTimeout(GIM_COALESCE_MS, function()
        gimQueued = false
        if not next(DevTools.viewers.gim) then return end
        local payload = {
            items      = GroundItems.getAllArray(),
            charNames  = gimGetCharNames(),
            serverTime = os.time(),
        }
        DevTools.eachViewer(DevTools.viewers.gim, function(src)
            TriggerClientEvent('whip_core:client:gimRefresh', src, payload)
        end)
    end)
end
DevTools.setRefresh('gim', gimBroadcast)

SecureEvent('whip_core:server:gimGetAll', {
    ace = 'whip.devtools',
}, function(source)
    DevTools.viewers.gim[source] = true
    TriggerClientEvent('whip_core:client:gimAllItems', source, {
        items      = GroundItems.getAllArray(),
        defs       = gimGetItemDefs(),
        charNames  = gimGetCharNames(),
        serverTime = os.time(),
    })
end)

SecureEvent('whip_core:server:gimClosed', {   -- no ACE: see plmClosed
    requirePlayer = false, whileDead = true,
}, function(source)
    DevTools.viewers.gim[source] = nil
end)

--- One pile gone, by an admin: the last row of its timeline, and on the admin's own. Its name, or nil when
--- there is no such pile.
local function gimDeleteOne(player, id)
    local gItem = GroundItems.getById(id)
    if not gItem then return nil end
    local def = Config.Items[gItem.item]
    if GroundItems.delete(id) then
        Log.item(player and player.charId, 'lost', gItem, {
            detail = 'deleted in the admin Ground Item Manager',
            x = gItem.x, y = gItem.y, z = gItem.z,
        })
    end
    return def and def.name or gItem.item
end

SecureEvent('whip_core:server:gimDeleteItem', {
    ace = 'whip.devtools',
    params = { {'id', 'id'} },
}, function(source, player, id)
    local name = gimDeleteOne(player, id)
    if not name then return false, 'Ground item not found' end
    ShowSuccess(source, 'Deleted ground item #' .. id .. ' (' .. name .. ')')
    gimBroadcast()
end)

-- Several piles picked in the list, in one call (the rate limit would refuse a run of single deletes).
SecureEvent('whip_core:server:gimDeleteItems', {
    ace = 'whip.devtools',
    params = { {'ids', 'list', {'id', 'id'}, 200} },
}, function(source, player, ids)
    local n = 0
    for _, id in ipairs(ids) do
        if gimDeleteOne(player, id) then n = n + 1 end
    end
    ShowSuccess(source, ('Deleted %d ground item%s'):format(n, n == 1 and '' or 's'))
    gimBroadcast()
end)

SecureEvent('whip_core:server:gimDeleteAll', {
    ace = 'whip.devtools',
}, function(source, player)
    local count = GroundItems.clearAll()
    Log.write(player and player.charId, 'lost',
        { detail = ('deleted all %d ground items in the admin Ground Item Manager'):format(count) })
    ShowSuccess(source,
        ('Deleted %d ground items'):format(count))
    gimBroadcast()
end)

SecureEvent('whip_core:server:gimDeleteCell', {
    ace = 'whip.devtools',
    params = { {'cellKey', 'key', 30} },
}, function(source, player, cellKey)
    local count = GroundItems.clearCell(cellKey)
    Log.write(player and player.charId, 'lost',
        { detail = ('deleted %d ground items in grid cell %s, admin Ground Item Manager'):format(count, cellKey) })
    ShowSuccess(source,
        ('Deleted %d items in grid cell %s'):format(count, cellKey))
    gimBroadcast()
end)

-- ============================================
-- Item Browser (Dev Tool)
-- ============================================

local function ibBuildItemList()
    local items = {}
    for key, def in pairs(Config.Items) do
        items[key] = {
            name         = def.name or key,
            desc         = def.desc or '',
            weight       = def.weight or 0,
            type         = def.type or '',
            stack        = def.stack,
            maxStack     = def.maxStack or 1,
            usable       = def.usable,
            cooldown     = def.cooldown or nil,
            prop         = def.prop or nil,
            css          = def.css or nil,
            defaultAction = def.defaultAction or nil,
            -- Its own right-click options and the ones other resources added (AddItemOption).
            contextOptions = Inventory.itemOptions(key),
            metaFields   = def.metaFields or nil,
            resource     = Inventory.itemOwner(key) or 'whip_core',
            -- Where its picture is, as the inventory's own definitions say it (a browser opened before
            -- the inventory would otherwise look in whip_core's folder). nil for whip_core's own PNGs.
            img          = Inventory.resolveItemImage(key, def),
            -- The pictures it changes to (server/item_options.lua), and the root their paths are in.
            images       = def.images,
            imgRoot      = def.images and Inventory.imageRoot(key) or nil,
            -- How many of its settings an admin changed, and how many of its own it has
            -- (server/item_settings.lua). The settings themselves are asked for when it is picked.
            changed      = ItemSettings.changedCount(key),
            ownSettings  = ItemSettings.ownCount(key),
        }
    end
    return items
end

--- Push the item list to every open Item Browser. Asked for with DevTools.refresh('ib') (inventory.lua,
--- when an item is registered).
local function ibBroadcast()
    if not next(DevTools.viewers.ib) then return end
    local items = ibBuildItemList()
    DevTools.eachViewer(DevTools.viewers.ib, function(src)
        TriggerClientEvent('whip_core:client:ibAllItems', src, items)
    end)
end
DevTools.setRefresh('ib', ibBroadcast)

SecureEvent('whip_core:server:ibGetAll', {
    ace = 'whip.devtools',
}, function(source)
    DevTools.viewers.ib[source] = true
    TriggerClientEvent('whip_core:client:ibAllItems', source, ibBuildItemList())
end)

SecureEvent('whip_core:server:ibClosed', {   -- no ACE: see plmClosed
    requirePlayer = false, whileDead = true,
}, function(source)
    DevTools.viewers.ib[source] = nil
end)

SecureEvent('whip_core:server:ibGiveItem', {
    ace = 'whip.devtools',
    params = {
        {'itemKey', 'key', 60},
        -- Up to cash's own stack. 'amount' refuses rather than
        -- clamps; the page caps it too. What will not fit lands in proper stacks (Inventory.dropAtFeet).
        {'amount', 'amount', 999999},
    },
}, function(source, player, itemKey, amount)
    if not Config.Items[itemKey] then
        return false, 'Unknown item: ' .. itemKey
    end

    if not player.inventory then
        return false, 'Player not loaded'
    end

    local ok, err, placement = Inventory.giveOrDrop(source, player, itemKey, amount, nil,
        { container = 'player', reason = 'admin Item Browser' })
    if not ok then return false, 'Failed: ' .. (err or 'Unknown error') end

    -- Inventory.giveOrDrop already said so if it went to the floor; do not also claim it was "given".
    if placement ~= 'ground' then
        local def = Config.Items[itemKey]
        local defName = def and def.name or itemKey
        ShowSuccess(source,
            ('Gave %dx %s'):format(amount, defName))
    end
end)

-- ============================================
-- Item Log (opens on everything, with an Economy tab)
-- ============================================
--
-- html/js/wp/itemlog.js. The reads are Log.feedRows and Log.economy (server/activity_log.lua); one
-- item's whole life is still whip_core:alItem, above.

--- What the page needs once: every item (its filter and its pictures) and the groups' names.
SecureCallback('whip_core:alSetup', {
    ace = 'whip.devtools',
}, function()
    local items = {}
    for key, def in pairs(ibBuildItemList()) do items[key] = { name = def.name, img = def.img, resource = def.resource } end
    local groups = {}
    for key in pairs(Log.GROUPS) do groups[#groups + 1] = key end
    return { items = items, groups = groups, keepDays = Config.ActivityLogDays or 30 }
end)

--- A page of everything, narrowed (Log.feedRows says how). Polled every few seconds while the page
--- is at its newest, so the limit is generous.
SecureCallback('whip_core:alFeed', {
    ace       = 'whip.devtools',
    rateLimit = 150,
    burst     = 10,
    params    = { {'filter', 'any'} },
}, function(_, _, filter)
    return Log.feedRows(filter)
end)

--- Which items moved since a time, busiest first: the Economy item picker's "Moved today / this
--- week / this month".
SecureCallback('whip_core:alItemActivity', {
    ace       = 'whip.devtools',
    rateLimit = 300,
    burst     = 6,
    params    = { {'since', 'any'} },
}, function(_, _, since)
    local rows = Log.itemActivity(since)
    if not rows then return { ok = false, why = 'The log could not be read for that long: try a shorter one' } end
    return { ok = true, items = rows }
end)

--- One item's head on its own page: how it came to be, where it was last, how many rows.
SecureCallback('whip_core:alItemInfo', {
    ace       = 'whip.devtools',
    rateLimit = 200,
    burst     = 5,
    params    = { {'uid', 'string', 24} },
}, function(_, _, uid)
    return Log.itemInfo(uid) or { count = 0 }
end)

--- How many of one item there are now, and where. Read from the
--- saved stores — pockets, stashes, car storage and the ground — which trail the game by a second at
--- most (the write-behind). NOT counted: what is inside other items (a wallet's cash, a gun's magazine:
--- kept in that item's metadata), shelves that never run out (nothing is there until it is bought), and
--- a resource's own stores. Each count is its own read; one that fails is nil, and `complete` says so.
---@param itemKey string
---@return table { where = { pockets, stashes, cars, ground }, total, holders, complete }
local function itemCensus(itemKey)
    local hint = 'SELECT /*+ MAX_EXECUTION_TIME(4000) */ '
    local living = 'JOIN `characters` c ON c.`charId` = ci.`charId` AND c.`deleted` IS NULL '
    local function sum(sql)
        local ok, v = pcall(MySQL.scalar.await, hint .. sql, { itemKey })
        if not ok then print('[whip_core:itemlog] a count could not be read: ' .. tostring(v)) end
        return ok and (tonumber(v) or 0) or nil
    end
    local where = {
        pockets = sum('CAST(COALESCE(SUM(ci.`amount`), 0) AS SIGNED) FROM `character_inventory` ci ' .. living .. 'WHERE ci.`item` = ?'),
        stashes = sum('CAST(COALESCE(SUM(`amount`), 0) AS SIGNED) FROM `container_inventory` WHERE `item` = ?'),
        cars    = sum('CAST(COALESCE(SUM(`amount`), 0) AS SIGNED) FROM `vehicle_inventory` WHERE `item` = ?'),
        ground  = sum('CAST(COALESCE(SUM(`amount`), 0) AS SIGNED) FROM `ground_items` WHERE `item` = ?'),
    }
    local total, complete = 0, true
    for _, place in ipairs({ 'pockets', 'stashes', 'cars', 'ground' }) do
        if where[place] then total = total + where[place] else complete = false end
    end
    local okH, holders = pcall(MySQL.query.await, hint
        .. "ci.`charId`, MAX(c.`userId`) AS userId, MAX(CONCAT(c.`firstName`, ' ', c.`lastName`)) AS who, "
        .. 'CAST(SUM(ci.`amount`) AS SIGNED) AS total FROM `character_inventory` ci ' .. living
        .. 'WHERE ci.`item` = ? GROUP BY ci.`charId` ORDER BY total DESC LIMIT 10', { itemKey })
    holders = okH and holders or {}
    for _, h in ipairs(holders) do h.total = tonumber(h.total) or 0 end
    return { where = where, total = total, holders = holders, complete = complete }
end

--- The Economy tab: what came in and went out since a time, and for one item where and to whom, its
--- graph (per hour or per day), and how many there are now.
SecureCallback('whip_core:alEconomy', {
    ace       = 'whip.devtools',
    rateLimit = 500,
    burst     = 4,
    params    = { {'since', 'any'}, {'itemKey', 'any'}, {'bucket', 'any'} },
}, function(_, _, since, itemKey, bucket)
    local res = Log.economy(since, itemKey, bucket)
    if res.ok then res.census = itemCensus(res.itemKey) end
    return res
end)

-- ============================================
-- Phone Manager (Dev Tool)
-- ============================================

--- Build phone number list with character info + online status. One row per NUMBER: a character may own
--- several (whip_phone's SIM cards), so every action here names the number, not the character.
local function pmGetAllData()
    -- pn.* rather than naming `locked`: that column is whip_phone's, made when it first starts, so it
    -- may not exist yet.
    local rows = MySQL.query.await(
        'SELECT pn.*, c.firstName, c.lastName ' ..
        'FROM phone_numbers pn ' ..
        'LEFT JOIN characters c ON c.charId = pn.charId ' ..
        'ORDER BY pn.charId DESC',
        {}
    )

    local onlineLookup = {}
    for src, player in pairs(Players) do
        if player.charId then
            onlineLookup[player.charId] = src
        end
    end

    local entries = {}
    if rows then
        for _, row in ipairs(rows) do
            -- A retired number (deleted or changed here, kept so its SIM cards cannot bring it back) is not listed.
            -- A lore character's number (whip_phone's loreKey) has no character: named by the lore character.
            local lore = row.loreKey and DirectorLore.get(row.loreKey)
            if not row.retiredAt then entries[#entries + 1] = {
                phoneNumber = row.phoneNumber,
                charId      = row.charId,
                lore        = row.loreKey ~= nil or nil,
                locked      = row.locked == 1 or row.locked == true,
                firstName   = lore and lore.name or (row.loreKey and row.loreKey) or row.firstName or '',
                lastName    = row.lastName or '',
                createdAt   = row.createdAt,
                online      = onlineLookup[row.charId] and true or false,
                source      = onlineLookup[row.charId] or nil,
            } end
        end
    end

    return entries
end

--- Whether whip_phone's phone_numbers (or `tableName`) has this column. whip_phone adds its own when it starts:
--- `locked`, `prefs`, and `retiredAt` / `renamedTo` for retired numbers; `blocked` on phone_messages and phone_calls
--- since its block list.
local function phoneColumn(name, tableName)
    return (tonumber(MySQL.scalar.await([[SELECT COUNT(*) FROM information_schema.columns
        WHERE table_schema = DATABASE() AND table_name = ? AND column_name = ?]], { tableName or 'phone_numbers', name })) or 0) > 0
end

--- Whether a table is there (phone_calls and phone_blocks are whip_phone's, made when it first starts).
local function phoneTable(name)
    return (tonumber(MySQL.scalar.await([[SELECT COUNT(*) FROM information_schema.tables
        WHERE table_schema = DATABASE() AND table_name = ?]], { name })) or 0) > 0
end

--- One number's row (every column, so a server whip_phone has not brought up to date still answers), or nil.
--- A retired number counts as gone unless `withRetired`.
local function phoneRow(number, withRetired)
    local row = MySQL.single.await('SELECT * FROM phone_numbers WHERE phoneNumber = ?', { number })
    if row and row.retiredAt and not withRetired then return nil end
    return row
end

--- Whose a number is, in words: a lore character's has no charId, its loreKey instead (audit 20, SEC-4: a '%d' of
--- its nil charId threw after the change had landed).
local function phoneOwner(row)
    if row.loreKey then return 'lore character ' .. tostring(row.loreKey) end
    return 'charId #' .. tostring(row.charId)
end

--- Broadcast to all PM viewers
local function pmBroadcast()
    if not next(DevTools.viewers.pm) then return end
    local entries = pmGetAllData()
    DevTools.eachViewer(DevTools.viewers.pm, function(src)
        TriggerClientEvent('whip_core:client:pmRefresh', src, { entries = entries })
    end)
end

--- Open: get all data
SecureEvent('whip_core:server:pmGetAll', {
    ace = 'whip.devtools',
}, function(source)
    DevTools.viewers.pm[source] = true
    TriggerClientEvent('whip_core:client:pmAllData', source, {
        entries = pmGetAllData(),
    })
end)

--- Close
SecureEvent('whip_core:server:pmClosed', {   -- no ACE: see plmClosed
    requirePlayer = false, whileDead = true,
}, function(source)
    DevTools.viewers.pm[source] = nil
end)

--- Edit phone number (which number: a character may own several).
---
--- The new row first, the old one last, in one transaction: contacts, messages, calls and blocks point at their
--- number with a foreign key, so the number can't be renamed in place. The new number is written beside
--- the old one, everything moves across, and the old one goes, all of it or none.
---
--- The old number is retired, not deleted: a SIM card carries its number, and a number with no row would
--- come back, empty, the next time its phone opened. The old row is kept, marked retired and pointing at
--- the new number (with the SIM's prefs copied across), and whip_phone writes the new number onto the
--- card when its phone is next used.
SecureEvent('whip_core:server:pmEditNumber', {
    ace = 'whip.devtools',
    params = {
        {'phoneNumber', 'string', 10},
        {'newNumber', 'string', 10},
    },
}, function(source, _, oldNumber, newNumber)
    oldNumber = tostring(oldNumber or ''):gsub('[^%d]', '')
    newNumber = tostring(newNumber or ''):gsub('[^%d]', '')
    if #newNumber ~= 10 then
        return false, 'Phone number must be exactly 10 digits'
    end

    local existingRow = phoneRow(oldNumber)
    if not existingRow then
        return false, 'That number does not exist'
    end
    if oldNumber == newNumber then
        return false, 'Same number — nothing to change'
    end

    local conflict = phoneRow(newNumber, true)
    if conflict then
        if conflict.retiredAt then
            return false, ('Number %s was used before and retired (old SIM cards still carry it): pick another'):format(newNumber)
        end
        return false, ('Number %s already belongs to %s'):format(newNumber, phoneOwner(conflict))
    end

    local retire = phoneColumn('retiredAt')
    local steps = {
        retire
            and { query = 'INSERT INTO phone_numbers (phoneNumber, charId, locked, prefs) SELECT ?, charId, locked, prefs FROM phone_numbers WHERE phoneNumber = ?',
                  values = { newNumber, oldNumber } }
            or { query = 'INSERT INTO phone_numbers (phoneNumber, charId, locked) VALUES (?, ?, ?)',
                  values = { newNumber, existingRow.charId, existingRow.locked or 0 } },
        { query = 'UPDATE phone_contacts SET phoneNumber = ? WHERE phoneNumber = ?', values = { newNumber, oldNumber } },
        { query = 'UPDATE phone_contacts SET contactNumber = ? WHERE contactNumber = ?', values = { newNumber, oldNumber } },
        { query = 'UPDATE phone_messages SET senderNumber = ? WHERE senderNumber = ?', values = { newNumber, oldNumber } },
        { query = 'UPDATE phone_messages SET receiverNumber = ? WHERE receiverNumber = ?', values = { newNumber, oldNumber } },
    }
    -- phone_calls is whip_phone's (made when it first starts): moved too, when it is there.
    if phoneTable('phone_calls') then
        steps[#steps + 1] = { query = 'UPDATE phone_calls SET callerNumber = ? WHERE callerNumber = ?', values = { newNumber, oldNumber } }
        steps[#steps + 1] = { query = 'UPDATE phone_calls SET calleeNumber = ? WHERE calleeNumber = ?', values = { newNumber, oldNumber } }
    end
    -- So is phone_blocks (its block list): the number's own list, and its place on everyone else's. The new number
    -- had no row before this, so no block names it yet and neither side can collide.
    if phoneTable('phone_blocks') then
        steps[#steps + 1] = { query = 'UPDATE phone_blocks SET phoneNumber = ? WHERE phoneNumber = ?', values = { newNumber, oldNumber } }
        steps[#steps + 1] = { query = 'UPDATE phone_blocks SET blockedNumber = ? WHERE blockedNumber = ?', values = { newNumber, oldNumber } }
    end
    -- Retired where whip_phone has brought the table up to date; deleted on a server it never ran on.
    steps[#steps + 1] = retire
        and { query = 'UPDATE phone_numbers SET retiredAt = CURRENT_TIMESTAMP, renamedTo = ?, prefs = NULL, locked = 0 WHERE phoneNumber = ?',
              values = { newNumber, oldNumber } }
        or { query = 'DELETE FROM phone_numbers WHERE phoneNumber = ?', values = { oldNumber } }
    local moved = MySQL.transaction.await(steps)
    if not moved then
        return false, 'Could not change the number (database refused; nothing changed)'
    end

    -- Reload whip_phone cache
    if GetResourceState('whip_phone') == 'started' then
        pcall(exports.whip_phone.ReloadCache, exports.whip_phone)
    end

    ShowSuccess(source,
        ('Phone number changed: %s → %s (%s)'):format(oldNumber, newNumber, phoneOwner(existingRow)))

    pmBroadcast()
end)

--- Delete phone number (which number: a character may own several). Its contacts, messages, calls and blocks
--- (its own list and its place on others') go with it. The number itself is RETIRED, not removed (see
--- pmEditNumber), so the SIM cards still carrying it stop working, and the foreign keys' cascade never fires:
--- each table is emptied of it here.
SecureEvent('whip_core:server:pmDeleteNumber', {
    ace = 'whip.devtools',
    params = { {'phoneNumber', 'string', 10} },
}, function(source, _, number)
    number = tostring(number or ''):gsub('[^%d]', '')

    local existingRow = phoneRow(number)
    if not existingRow then
        return false, 'That number does not exist'
    end

    if phoneColumn('retiredAt') then
        local steps = {
            { query = 'DELETE FROM phone_contacts WHERE phoneNumber = ?', values = { number } },
            { query = 'DELETE FROM phone_messages WHERE senderNumber = ? OR receiverNumber = ?', values = { number, number } },
        }
        if phoneTable('phone_calls') then
            steps[#steps + 1] = { query = 'DELETE FROM phone_calls WHERE callerNumber = ? OR calleeNumber = ?', values = { number, number } }
        end
        if phoneTable('phone_blocks') then
            steps[#steps + 1] = { query = 'DELETE FROM phone_blocks WHERE phoneNumber = ? OR blockedNumber = ?', values = { number, number } }
        end
        steps[#steps + 1] = { query = 'UPDATE phone_numbers SET retiredAt = CURRENT_TIMESTAMP, renamedTo = NULL, prefs = NULL, locked = 0 WHERE phoneNumber = ?',
            values = { number } }
        if not MySQL.transaction.await(steps) then
            return false, 'Could not delete the number (database refused; nothing changed)'
        end
    else
        -- whip_phone has never brought the table up to date here: the old delete (the foreign keys cascade).
        MySQL.update.await('DELETE FROM phone_numbers WHERE phoneNumber = ?', { number })
    end

    if GetResourceState('whip_phone') == 'started' then
        pcall(exports.whip_phone.ReloadCache, exports.whip_phone)
    end

    ShowSuccess(source,
        ('Deleted phone number %s for %s'):format(number, phoneOwner(existingRow)))

    pmBroadcast()
end)

--- Assign new phone number to a character that doesn't have one
SecureEvent('whip_core:server:pmAssignNumber', {
    ace = 'whip.devtools',
    params = { {'charId', 'id'} },
}, function(source, _, charId)
    -- A character that is there (not deleted): the insert's foreign key threw on one that is not, unanswered
    if not MySQL.scalar.await('SELECT charId FROM characters WHERE charId = ? AND deleted IS NULL', { charId }) then
        return false, ('There is no character #%d'):format(charId)
    end

    local existing
    for _, row in ipairs(MySQL.query.await('SELECT * FROM phone_numbers WHERE charId = ?', { charId }) or {}) do
        if not row.retiredAt then existing = row break end   -- a retired number is not theirs any more
    end
    if existing then
        return false, ('CharId #%d already has number %s'):format(charId, existing.phoneNumber)
    end

    local prefixes = { '689', '041', '227', '869', '915' }
    local number
    local attempts = 0
    repeat
        local prefix = prefixes[math.random(#prefixes)]
        number = prefix
        for _ = 1, 7 do
            number = number .. tostring(math.random(0, 9))
        end
        local conflict = MySQL.single.await(
            'SELECT phoneNumber FROM phone_numbers WHERE phoneNumber = ?', { number }
        )
        if not conflict then break end
        number = nil
        attempts = attempts + 1
    until attempts > 100

    if not number then
        return false, 'Failed to generate unique number after 100 attempts'
    end

    local saved = pcall(MySQL.insert.await,
        'INSERT INTO phone_numbers (phoneNumber, charId) VALUES (?, ?)',
        { number, charId }
    )
    if not saved then return false, 'Could not save the number (database refused; nothing changed)' end

    if GetResourceState('whip_phone') == 'started' then
        pcall(exports.whip_phone.ReloadCache, exports.whip_phone)
    end

    ShowSuccess(source,
        ('Assigned number %s to charId #%d'):format(number, charId))

    pmBroadcast()
end)

--- Spawn SIM card to requesting player
SecureEvent('whip_core:server:pmSpawnSim', {
    ace = 'whip.devtools',
    params = {
        {'phoneNumber', 'string', 10},
    },
}, function(source, player, phoneNumber)
    phoneNumber = phoneNumber:gsub('[^%d]', '')
    if #phoneNumber ~= 10 then
        return false, 'Phone number must be 10 digits'
    end
    local row = phoneRow(phoneNumber, true)
    if row and row.retiredAt then
        return false, row.renamedTo and ('That number was changed to %s: spawn a SIM for that one'):format(row.renamedTo)
            or 'That number was deleted: a SIM for it would not work'
    end

    local ok, err, placement = Inventory.giveOrDrop(source, player, 'sim_card', 1, { phoneNumber = phoneNumber },
        { reason = 'admin Phone Manager, number ' .. phoneNumber })
    if not ok then return false, 'Failed to give SIM: ' .. (err or 'inventory full') end

    -- A SIM carries a phone number in its metadata: with a full inventory it lands on the floor,
    -- number intact (metadata travels with a ground item).
    if placement ~= 'ground' then
        ShowSuccess(source,
            ('Spawned SIM (%s) to your inventory'):format(phoneNumber))
    end
end)

--- What one number holds, for its page (html/js/wp/phones.js): its
--- contacts, the messages it sent or received, its calls and its blocks (the numbers it blocked and those that
--- blocked it) — what Delete takes with it. Answers { ok, contacts, messages, calls, blocks }; a count whose table is
--- not there (whip_phone has never run, or predates its block list) is left out.
SecureCallback('whip_core:pmNumberDetail', {
    ace       = 'whip.devtools',
    rateLimit = 250,
    params    = { {'phoneNumber', 'string', 10} },
}, function(_, _, number)
    number = tostring(number or ''):gsub('[^%d]', '')
    if #number ~= 10 then return { ok = false } end
    local function count(sql, args)
        local ok, n = pcall(MySQL.scalar.await, sql, args)
        return ok and tonumber(n) or nil
    end
    local out = {
        ok       = true,
        contacts = count('SELECT COUNT(*) FROM phone_contacts WHERE phoneNumber = ?', { number }),
        messages = count('SELECT COUNT(*) FROM phone_messages WHERE senderNumber = ? OR receiverNumber = ?', { number, number }),
    }
    if phoneTable('phone_calls') then
        out.calls = count('SELECT COUNT(*) FROM phone_calls WHERE callerNumber = ? OR calleeNumber = ?', { number, number })
    end
    if phoneTable('phone_blocks') then
        out.blocks = count('SELECT COUNT(*) FROM phone_blocks WHERE phoneNumber = ? OR blockedNumber = ?', { number, number })
    end
    return out
end)

-- ============================================
-- Phone records: the Phones page's dashboard (html/js/wp/phoneRecords.js)
-- ============================================
--
-- Everything one number did: its contacts, its conversations, its calls, its blocks both ways, who it talks to and
-- when. A text or call that came while its receiver had blocked the sender (whip_phone's `blocked` mark) is kept in,
-- marked HELD: the receiver never saw it, and it is the evidence when someone reports being harassed. Read
-- only. Every moment goes out as unix SECONDS (UNIX_TIMESTAMP, fields named …At), not oxmysql's milliseconds.
-- Hours and days are the ADMIN's own (their PC's offset from UTC, `tzOffset` in minutes as JS's
-- getTimezoneOffset gives it), so "busy at 2am" means 2am where they are reading it.

local PR_CALLS = 500     -- the call log's newest rows (the totals count them all)
local PR_PAGE  = 100     -- a conversation's texts per page, newest first

--- Who owns each number: { [number] = { charId, name, online, source, locked, retired, renamedTo } }.
--- A number not in phone_numbers is left out (a contact can save any ten digits).
local function prOwners(numbers)
    local list, seen = {}, {}
    for _, n in ipairs(numbers) do
        if type(n) == 'string' and n ~= '' and not seen[n] then seen[n] = true; list[#list + 1] = n end
    end
    local out = {}
    if #list == 0 then return out end
    local online = {}
    for src, p in pairs(Players) do
        if p.charId then online[p.charId] = src end
    end
    for i = 1, #list, 200 do
        local chunk = {}
        for j = i, math.min(i + 199, #list) do chunk[#chunk + 1] = list[j] end
        local rows = MySQL.query.await(('SELECT pn.*, c.firstName, c.lastName FROM phone_numbers pn '
            .. 'LEFT JOIN characters c ON c.charId = pn.charId WHERE pn.phoneNumber IN (%s)')
            :format(string.rep('?', #chunk, ',')), chunk) or {}
        for _, r in ipairs(rows) do
            local name = ((r.firstName or '') .. ' ' .. (r.lastName or '')):match('^%s*(.-)%s*$')
            -- A lore character's number: named by the lore character (it has no character).
            local lore = r.loreKey and DirectorLore.get(r.loreKey)
            if r.loreKey then name = lore and lore.name or r.loreKey end
            out[r.phoneNumber] = {
                charId    = r.charId,
                lore      = r.loreKey ~= nil or nil,
                name      = name ~= '' and name or nil,
                online    = online[r.charId] ~= nil,
                source    = online[r.charId],
                locked    = r.locked == 1 or r.locked == true,
                retired   = r.retiredAt ~= nil,
                renamedTo = r.renamedTo,
            }
        end
    end
    return out
end

local function prNum(v) return tonumber(v) or 0 end

--- A flag as oxmysql gives it: a TINYINT(1) column (whip_phone's `blocked`) comes as a boolean, a 0 in its place as a
--- number.
local function prYes(v) return v == true or prNum(v) == 1 end

--- One number's records. Answers { ok = true, … } or { ok = false, why }.
SecureCallback('whip_core:pmPhoneDossier', {
    ace       = 'whip.devtools',
    rateLimit = 400,
    burst     = 3,
    params    = { {'phoneNumber', 'string', 10}, {'tzOffset', 'int', -900, 900, 0} },
}, function(_, _, number, tzOffset)
    number = tostring(number or ''):gsub('[^%d]', '')
    if #number ~= 10 then return { ok = false, why = 'That is not a phone number' } end
    if not phoneRow(number, true) then return { ok = false, why = 'That number is not on this server' } end
    local tz = (tonumber(tzOffset) or 0) * 60   -- local = UTC - offset
    local hasCalls = phoneTable('phone_calls')
    -- whip_phone's block list: its table, and the `blocked` mark on texts and calls. A whip_phone that predates it has
    -- neither, and nothing there was held back (0).
    local hasBlocks = phoneTable('phone_blocks')
    local msgHeld = phoneColumn('blocked', 'phone_messages') and 'blocked' or '0'
    local callHeld = hasCalls and phoneColumn('blocked', 'phone_calls') and 'blocked' or '0'

    local ok, res = pcall(function()
        local q = MySQL.query.await
        local row = phoneRow(number, true) --[[@as table]]   -- asked above; one gone since fails the pcall

        local contacts = {}
        for _, c in ipairs(q([[SELECT contactId, contactName, contactNumber, UNIX_TIMESTAMP(createdAt) AS t
            FROM phone_contacts WHERE phoneNumber = ? ORDER BY contactName]], { number }) or {}) do
            contacts[#contacts + 1] = { id = c.contactId, name = c.contactName, number = c.contactNumber, savedAt = prNum(c.t) }
        end

        -- A conversation a counterpart: how many each way, how many this phone has not read, how many were held back,
        -- and its last text. A held text this phone received was never shown on it, so it is not unread there.
        local threads, lastIds = {}, {}
        for _, t in ipairs(q(([[SELECT other, COUNT(*) AS n, SUM(mine) AS sent,
                SUM(CASE WHEN mine = 0 AND readAt IS NULL AND held = 0 THEN 1 ELSE 0 END) AS unread, SUM(held) AS held,
                MIN(t) AS firstAt, MAX(t) AS lastAt, MAX(messageId) AS lastId
            FROM (SELECT IF(senderNumber = ?, receiverNumber, senderNumber) AS other, (senderNumber = ?) AS mine,
                    readAt, UNIX_TIMESTAMP(createdAt) AS t, messageId, %s AS held
                FROM phone_messages WHERE senderNumber = ? OR receiverNumber = ?) x
            GROUP BY other ORDER BY lastId DESC]]):format(msgHeld), { number, number, number, number }) or {}) do
            local n, sent = prNum(t.n), prNum(t.sent)
            threads[#threads + 1] = { number = t.other, n = n, sent = sent, recv = n - sent, unread = prNum(t.unread),
                held = prNum(t.held), firstAt = prNum(t.firstAt), lastAt = prNum(t.lastAt), lastId = prNum(t.lastId) }
            lastIds[#lastIds + 1] = prNum(t.lastId)
        end
        if #lastIds > 0 then
            local byId = {}
            for i = 1, #lastIds, 200 do
                local chunk = { number }
                for j = i, math.min(i + 199, #lastIds) do chunk[#chunk + 1] = lastIds[j] end
                for _, m in ipairs(q(('SELECT messageId, (senderNumber = ?) AS mine, content FROM phone_messages WHERE messageId IN (%s)')
                    :format(string.rep('?', #chunk - 1, ',')), chunk) or {}) do
                    byId[m.messageId] = { text = m.content, me = prNum(m.mine) == 1 }
                end
            end
            for _, t in ipairs(threads) do t.last = byId[t.lastId] end
        end

        local hours, days = {}, {}
        for h = 1, 24 do hours[h] = { msgs = 0, calls = 0 } end
        local function bucket(sql, kind)
            for _, r in ipairs(q(sql, { tz, number, number }) or {}) do
                local h = hours[prNum(r.h) + 1]
                if h then h[kind] = h[kind] + prNum(r.n) end
            end
        end
        local function daily(sql, kind)
            for _, r in ipairs(q(sql, { tz, number, number }) or {}) do
                local key = tostring(prNum(r.d))
                days[key] = days[key] or { day = prNum(r.d), msgs = 0, calls = 0 }
                days[key][kind] = days[key][kind] + prNum(r.n)
            end
        end
        bucket([[SELECT MOD(FLOOR((UNIX_TIMESTAMP(createdAt) - ?) / 3600), 24) AS h, COUNT(*) AS n FROM phone_messages
            WHERE senderNumber = ? OR receiverNumber = ? GROUP BY h]], 'msgs')
        daily([[SELECT FLOOR((UNIX_TIMESTAMP(createdAt) - ?) / 86400) AS d, COUNT(*) AS n FROM phone_messages
            WHERE (senderNumber = ? OR receiverNumber = ?) AND createdAt >= NOW() - INTERVAL 15 DAY GROUP BY d]], 'msgs')

        local calls, callsBy, callTotals = {}, {}, nil
        if hasCalls then
            for _, c in ipairs(q(([[SELECT callId, callerNumber, calleeNumber, status, UNIX_TIMESTAMP(startedAt) AS s,
                    UNIX_TIMESTAMP(answeredAt) AS a, UNIX_TIMESTAMP(endedAt) AS e, %s AS b
                FROM phone_calls WHERE callerNumber = ? OR calleeNumber = ? ORDER BY callId DESC LIMIT ?]]):format(callHeld),
                { number, number, PR_CALLS }) or {}) do
                local out = c.callerNumber == number
                calls[#calls + 1] = { id = c.callId, out = out, other = out and c.calleeNumber or c.callerNumber,
                    status = c.status, startedAt = tonumber(c.s), answeredAt = tonumber(c.a), endedAt = tonumber(c.e),
                    held = prYes(c.b) or nil }
            end
            local talk = 'CASE WHEN status = \'answered\' AND answeredAt IS NOT NULL AND endedAt IS NOT NULL '
                .. 'THEN TIMESTAMPDIFF(SECOND, answeredAt, endedAt) ELSE 0 END'
            for _, c in ipairs(q(([[SELECT IF(callerNumber = ?, calleeNumber, callerNumber) AS other, COUNT(*) AS n,
                    SUM(callerNumber = ?) AS outN, SUM(status = 'answered') AS answered, SUM(%s) AS talk,
                    MAX(UNIX_TIMESTAMP(startedAt)) AS lastAt
                FROM phone_calls WHERE callerNumber = ? OR calleeNumber = ? GROUP BY other]]):format(talk),
                { number, number, number, number }) or {}) do
                callsBy[#callsBy + 1] = { number = c.other, n = prNum(c.n), outN = prNum(c.outN),
                    answered = prNum(c.answered), talk = prNum(c.talk), lastAt = prNum(c.lastAt) }
            end
            -- A held call this phone received never rang on it: not one it missed.
            callTotals = MySQL.single.await(([[SELECT COUNT(*) AS n, SUM(callerNumber = ?) AS outN,
                    SUM(status = 'answered') AS answered, SUM(status <> 'answered' AND callerNumber <> ? AND %s = 0) AS missedIn,
                    SUM(%s) AS held, SUM(%s) AS talk, MIN(UNIX_TIMESTAMP(startedAt)) AS firstAt, MAX(UNIX_TIMESTAMP(startedAt)) AS lastAt
                FROM phone_calls WHERE callerNumber = ? OR calleeNumber = ?]]):format(callHeld, callHeld, talk),
                { number, number, number, number })
            bucket([[SELECT MOD(FLOOR((UNIX_TIMESTAMP(startedAt) - ?) / 3600), 24) AS h, COUNT(*) AS n FROM phone_calls
                WHERE callerNumber = ? OR calleeNumber = ? GROUP BY h]], 'calls')
            daily([[SELECT FLOOR((UNIX_TIMESTAMP(startedAt) - ?) / 86400) AS d, COUNT(*) AS n FROM phone_calls
                WHERE (callerNumber = ? OR calleeNumber = ?) AND startedAt >= NOW() - INTERVAL 15 DAY GROUP BY d]], 'calls')
        end

        -- Its blocks both ways (whip_phone's phone_blocks), the latest first: the numbers it blocked, and the numbers
        -- that blocked it.
        local blocks, blockedBy = {}, {}
        if hasBlocks then
            for _, b in ipairs(q([[SELECT phoneNumber, blockedNumber, UNIX_TIMESTAMP(createdAt) AS t FROM phone_blocks
                WHERE phoneNumber = ? OR blockedNumber = ? ORDER BY createdAt DESC, blockedNumber, phoneNumber]], { number, number }) or {}) do
                if b.phoneNumber == number then
                    blocks[#blocks + 1] = { number = b.blockedNumber, at = prNum(b.t) }
                else
                    blockedBy[#blockedBy + 1] = { number = b.phoneNumber, at = prNum(b.t) }
                end
            end
        end

        local sent, recv, unread, held, firstAt, lastAt = 0, 0, 0, 0, nil, nil
        for _, t in ipairs(threads) do
            sent, recv, unread, held = sent + t.sent, recv + t.recv, unread + t.unread, held + t.held
            if t.firstAt > 0 and (not firstAt or t.firstAt < firstAt) then firstAt = t.firstAt end
            if not lastAt or t.lastAt > lastAt then lastAt = t.lastAt end
        end
        local ct = callTotals or {}
        local cn = prNum(ct.n)
        if cn > 0 then
            if prNum(ct.firstAt) > 0 and (not firstAt or prNum(ct.firstAt) < firstAt) then firstAt = prNum(ct.firstAt) end
            if not lastAt or prNum(ct.lastAt) > lastAt then lastAt = prNum(ct.lastAt) end
        end

        local dayList = {}
        for _, d in pairs(days) do dayList[#dayList + 1] = d end
        table.sort(dayList, function(a, b) return a.day < b.day end)

        local numbers = { number }
        for _, c in ipairs(contacts) do numbers[#numbers + 1] = c.number end
        for _, t in ipairs(threads) do numbers[#numbers + 1] = t.number end
        for _, c in ipairs(callsBy) do numbers[#numbers + 1] = c.number end
        for _, b in ipairs(blocks) do numbers[#numbers + 1] = b.number end
        for _, b in ipairs(blockedBy) do numbers[#numbers + 1] = b.number end
        local owners = prOwners(numbers)

        -- The owner's other numbers, for the dashboard's switch.
        local others = {}
        for _, r in ipairs(q('SELECT * FROM phone_numbers WHERE charId = ? AND phoneNumber <> ? ORDER BY createdAt',
            { row.charId, number }) or {}) do
            if not r.retiredAt then others[#others + 1] = { number = r.phoneNumber, locked = r.locked == 1 or r.locked == true } end
        end

        return {
            ok        = true,
            number    = number,
            owner     = owners[number] or {},
            createdAt = prNum(MySQL.scalar.await('SELECT UNIX_TIMESTAMP(createdAt) FROM phone_numbers WHERE phoneNumber = ?', { number })),
            others    = others,
            contacts  = contacts,
            threads   = threads,
            calls     = calls,
            callsMore = cn > #calls,
            callsBy   = callsBy,
            hasCalls  = hasCalls,
            blocks    = blocks,
            blockedBy = blockedBy,
            hasBlocks = hasBlocks,
            owners    = owners,
            hours     = hours,
            days      = dayList,
            totals    = {
                contacts = #contacts, messages = sent + recv, sent = sent, recv = recv, unread = unread, held = held,
                calls = cn, callsOut = prNum(ct.outN), callsIn = cn - prNum(ct.outN), answered = prNum(ct.answered),
                missedIn = prNum(ct.missedIn), callsHeld = prNum(ct.held), talk = prNum(ct.talk), firstAt = firstAt,
                lastAt = lastAt, people = 0,
            },
        }
    end)
    if not ok then
        print(('[whip_core] phone records for %s could not be read: %s'):format(number, tostring(res)))
        return { ok = false, why = 'The phone records could not be read (see the server console)' }
    end
    -- How many people it deals with: every number it texted, called or saved.
    local people = {}
    for _, t in ipairs(res.threads) do people[t.number] = true end
    for _, c in ipairs(res.callsBy) do people[c.number] = true end
    for _, c in ipairs(res.contacts) do people[c.number] = true end
    for _ in pairs(people) do res.totals.people = res.totals.people + 1 end
    return res
end)

--- One conversation, newest first, PR_PAGE at a time (`beforeId`: the oldest text already shown).
--- Answers { ok, messages = { { id, me, text, at, readAt, held } } oldest first, more }. `held`: sent while the
--- receiver had blocked the sender, so the receiver never saw it.
SecureCallback('whip_core:pmPhoneThread', {
    ace       = 'whip.devtools',
    rateLimit = 150,
    burst     = 6,
    params    = { {'phoneNumber', 'string', 10}, {'otherNumber', 'string', 10}, {'beforeId', 'any'} },
}, function(_, _, number, other, beforeId)
    number = tostring(number or ''):gsub('[^%d]', '')
    other = tostring(other or ''):gsub('[^%d]', '')
    if #number ~= 10 or #other ~= 10 then return { ok = false, why = 'That is not a phone number' } end
    local before = math.floor(tonumber(beforeId) or 0)
    ---@type (string|integer)[]
    local args = { number, number, other, other, number }
    -- (a whip_phone that predates its block list has no `blocked`: nothing held back)
    local sql = ([[SELECT messageId, (senderNumber = ?) AS mine, content, UNIX_TIMESTAMP(createdAt) AS t,
            UNIX_TIMESTAMP(readAt) AS r, %s AS b
        FROM phone_messages WHERE ((senderNumber = ? AND receiverNumber = ?) OR (senderNumber = ? AND receiverNumber = ?))]])
        :format(phoneColumn('blocked', 'phone_messages') and 'blocked' or '0')
    if before > 0 then
        sql = sql .. ' AND messageId < ?'
        args[#args + 1] = before
    end
    sql = sql .. ' ORDER BY messageId DESC LIMIT ?'
    args[#args + 1] = PR_PAGE
    local ok, rows = pcall(MySQL.query.await, sql, args)
    if not ok then
        print(('[whip_core] a conversation of %s could not be read: %s'):format(number, tostring(rows)))
        return { ok = false, why = 'The conversation could not be read (see the server console)' }
    end
    rows = rows or {}
    local messages = {}
    for i = #rows, 1, -1 do
        local m = rows[i]
        messages[#messages + 1] = { id = m.messageId, me = prNum(m.mine) == 1, text = m.content,
            at = prNum(m.t), readAt = tonumber(m.r), held = prYes(m.b) or nil }
    end
    return { ok = true, messages = messages, more = #rows >= PR_PAGE }
end)

-- ============================================
-- Job Manager (Dev Tool)
-- ============================================

--- Names for every employee and owner across all jobs (ResolveCharNames).
local function jmGetCharNames()
    local seen, charIds = {}, {}
    local function add(charId)
        if charId and not seen[charId] then
            seen[charId] = true
            charIds[#charIds + 1] = charId
        end
    end
    for _, emps in pairs(Jobs.employees) do
        for charId in pairs(emps) do add(charId) end
    end
    for _, job in pairs(Jobs.cache) do add(job.ownerCharId) end
    return charNamesForPage(ResolveCharNames(charIds))
end

--- Convert numeric-keyed nested maps to string keys so FiveM msgpack
--- doesn't encode them as 0-indexed arrays (breaks JS key lookups)
local function jmStringifyKeys(tbl)
    local result = {}
    for k, v in pairs(tbl) do
        local sk = tostring(k)
        if type(v) == 'table' then
            -- Check if this is a nested map (not a role/employee data object)
            -- Data objects have string keys like 'name', 'level', etc.
            local hasNumericKeys = false
            for k2 in pairs(v) do
                if type(k2) == 'number' then hasNumericKeys = true break end
            end
            if hasNumericKeys then
                result[sk] = jmStringifyKeys(v)
            else
                result[sk] = v
            end
        else
            result[sk] = v
        end
    end
    return result
end

local function jmGetBankAccounts()
    local result = {}
    for jobId in pairs(Jobs.cache) do
        local accounts = Bank.GetAccountsByJob(jobId)
        if #accounts > 0 then
            result[tostring(jobId)] = {}
            for _, acc in ipairs(accounts) do
                result[tostring(jobId)][tostring(acc.accountId)] = {
                    accountId     = acc.accountId,
                    accountNumber = acc.accountNumber,
                    label         = acc.label,
                    balance       = acc.balance,
                    frozen        = acc.frozen,
                }
            end
        end
    end
    return result
end

local function jmBuildPayload()
    -- Each job's permissions — the built-ins, then its resource's own — so the role form offers a
    -- toggle for every one. Plain arrays (not stringified): they reach the page as JS arrays.
    local permissionDefs = {}
    for jobId in pairs(Jobs.cache) do permissionDefs[tostring(jobId)] = Jobs.permissionList(jobId) end

    -- The shops each job runs, for its page (light: what a row says).
    local shops = {}
    for _, s in ipairs(Shops.getAll()) do
        if s.jobId then
            local k = tostring(s.jobId)
            shops[k] = shops[k] or {}
            shops[k][#shops[k] + 1] = { shopId = s.shopId, name = s.name, mode = s.mode }
        end
    end

    return {
        permissionDefs = permissionDefs,
        jobs         = Jobs.getAll(),
        roles        = jmStringifyKeys(Jobs.roles),
        employees    = jmStringifyKeys(Jobs.employees),
        clockedOn    = jmStringifyKeys(Jobs.dutyMap()),   -- yes/no per job, not the order numbers
        charNames    = jmGetCharNames(),
        bankAccounts = jmGetBankAccounts(),
        shops        = shops,
        -- The ranks a new job starts with (config.lua §5): the job wizard's first template.
        defaultRanks = Config.JobDefaultRoles or {},
        builtinPermissions = Jobs.BUILTIN_PERMISSIONS,
    }
end

--- Broadcast full job data to all open Job Manager viewers
local function jmBroadcast()
    if not next(DevTools.viewers.jm) then return end
    local payload = jmBuildPayload()
    DevTools.eachViewer(DevTools.viewers.jm, function(src)
        TriggerClientEvent('whip_core:client:jmRefresh', src, payload)
    end)
end

-- jobs.lua asks for it with DevTools.refresh('jm') after a batch of job changes.
DevTools.setRefresh('jm', jmBroadcast)

--- Open Job Manager — register viewer + send initial data
SecureEvent('whip_core:server:jmGetAll', {
    ace = 'whip.devtools',
}, function(source)
    DevTools.viewers.jm[source] = true
    TriggerClientEvent('whip_core:client:jmAllJobs', source, jmBuildPayload())
end)

--- Close Job Manager — unregister viewer
SecureEvent('whip_core:server:jmClosed', {   -- no ACE: see plmClosed
    requirePlayer = false, whileDead = true,
}, function(source)
    DevTools.viewers.jm[source] = nil
end)

--- Create Job
SecureEvent('whip_core:server:jmCreateJob', {
    ace = 'whip.devtools',
    params = { {'data', 'any'} },
}, function(source, player, data)
    if type(data) ~= 'table' then return end

    local name = Sanitize.string(data.name, 100, 'New Job')
    local icon = data.icon and Sanitize.string(data.icon, 100) or nil
    -- Every job has a key: the doors, shops and code name jobs by it. A blank box makes one
    -- from the name ('Burger Shot' → 'burger_shot'); a typed one must be a valid identifier.
    local key = type(data.key) == 'string' and data.key:match('^%s*(.-)%s*$') or ''
    if key == '' then key = Jobs.keyFromName(name) end
    -- An address, so Sanitize.id: 0 / blank is no owner, and 1.5 is refused rather than clamped
    -- onto character #1.
    local ownerCharId = Sanitize.id(data.ownerCharId)

    local createdBy = player and player.charId or nil

    local job, why = Jobs.create({
        key         = key,
        name        = name,
        icon        = icon,
        ownerCharId = ownerCharId,
        createdBy   = createdBy,
    })

    -- A success refreshes the panel from Jobs.create itself (Jobs.touch); a failure puts it back here.
    if not job then
        jmBroadcast()
        -- Jobs answers in words, so its why is the message.
        return false, why or 'Failed to create job'
    end
    ShowSuccess(source, ('Created job: %s (%s)'):format(job.name, job.key))
end)

--- Update Job
SecureEvent('whip_core:server:jmUpdateJob', {
    ace = 'whip.devtools',
    params = {
        {'jobId', 'id'},
        {'data', 'any'},
    },
}, function(source, _, jobId, data)
    if type(data) ~= 'table' then return end

    local updateData = {}
    if data.name ~= nil then updateData.name = Sanitize.string(data.name, 100) end
    if data.icon ~= nil then updateData.icon = Sanitize.string(data.icon, 100) end

    -- A blank owner box sends 0, which means "no owner": `false` to Jobs.update (nil would be "not
    -- mentioned").
    if data.ownerCharId ~= nil then
        updateData.ownerCharId = Sanitize.id(data.ownerCharId) or false
    end

    -- The owner rules are Jobs.update's: the business account follows a new owner, the old owner's
    -- access follows their job, and an owner cannot be cleared while the job has an account.
    local ok, why = Jobs.update(jobId, updateData)
    if not ok then
        jmBroadcast()
        return false, why or 'Failed to update job'   -- a sentence already
    end

    if why == 'account_not_moved' or why == 'account_not_created' then
        ShowError(source,
            'Job updated, but its business account could not follow the new owner — check the server console')
    else
        ShowSuccess(source, 'Job updated')
    end
end)

--- Delete Job
SecureEvent('whip_core:server:jmDeleteJob', {
    ace = 'whip.devtools',
    params = { {'jobId', 'id'} },
}, function(source, _, jobId)

    local ok, why = Jobs.delete(jobId)
    if not ok then
        jmBroadcast()
        return false, why or 'Failed to delete job'   -- a sentence already
    end
    ShowSuccess(source, 'Job deleted')
end)

--- Create Role
SecureEvent('whip_core:server:jmCreateRole', {
    ace = 'whip.devtools',
    params = { {'data', 'any'} },
}, function(source, _, data)
    if type(data) ~= 'table' then return end

    -- Sanitize.id, not int: int clamps 0 up to 1, and a missing job id would become job #1.
    local jobId = Sanitize.id(data.jobId)
    if not jobId then return end

    local name  = Sanitize.string(data.name, 60, 'New Role')
    local level = Sanitize.int(data.level, 1, 100, 1)
    -- The built-in permissions AND the job's own (EnsureJob `permissions`), plus a bank access level.
    local permissions = Jobs.cleanPermissions(jobId, data.permissions)

    local role, err = Jobs.createRole(jobId, {
        name        = name,
        level       = level,
        permissions = permissions,
    })

    if not role then jmBroadcast(); return false, err or 'Failed to create role' end
    ShowSuccess(source, ('Created role: %s'):format(role.name))
end)

--- Update Role
SecureEvent('whip_core:server:jmUpdateRole', {
    ace = 'whip.devtools',
    params = {
        {'roleId', 'id'},
        {'data', 'any'},
    },
}, function(source, _, roleId, data)
    if type(data) ~= 'table' then return end

    local updateData = {}
    if data.name ~= nil then updateData.name = Sanitize.string(data.name, 60) end
    if data.level ~= nil then updateData.level = Sanitize.int(data.level, 1, 100) end
    if data.permissions ~= nil and type(data.permissions) == 'table' then
        -- The role's CURRENT bank access is kept when the form sends none (wiping it would take the
        -- business account away from everyone holding the role).
        local current = Jobs.getRole(roleId)
        if not current then return false, 'No such role' end
        updateData.permissions = Jobs.cleanPermissions(current.jobId, data.permissions,
            current.permissions and current.permissions.bankAccess)
    end

    local ok, err = Jobs.updateRole(roleId, updateData)
    if ok then
        -- (The holders' bank access is synced inside Jobs.updateRole.)
        ShowSuccess(source, 'Role updated')
    else
        jmBroadcast()
        return false, err or 'Failed to update role'
    end
end)

--- Delete Role
SecureEvent('whip_core:server:jmDeleteRole', {
    ace = 'whip.devtools',
    params = { {'roleId', 'id'} },
}, function(source, _, roleId)

    local ok, err = Jobs.deleteRole(roleId)
    if not ok then
        jmBroadcast()
        return false, err or 'Failed to delete role'   -- a sentence already
    end
    ShowSuccess(source, 'Role deleted')
end)

--- Hire Employee
SecureEvent('whip_core:server:jmHire', {
    ace = 'whip.devtools',
    params = { {'data', 'any'} },
}, function(source, player, data)
    if type(data) ~= 'table' then return end

    -- Sanitize.id: these are addresses (int would clamp 0 to 1, hiring character #1).
    local jobId  = Sanitize.id(data.jobId)
    local charId = Sanitize.id(data.charId)
    local roleId = Sanitize.id(data.roleId)
    if not jobId or not charId or not roleId then return end

    local hiredBy = player and player.charId or nil

    -- No actor arg: this is the ACE-gated admin path, exempt from the rank rule. Bank access, the
    -- hired player's job list and this panel are all updated inside Jobs.hire.
    local ok, err = Jobs.hire(jobId, charId, roleId, hiredBy)
    if ok then
        ShowSuccess(source, ('Hired charId #%d'):format(charId))
    else
        jmBroadcast()
        return false, err or 'Failed to hire'   -- a sentence already
    end
end)

--- Fire Employee
SecureEvent('whip_core:server:jmFire', {
    ace = 'whip.devtools',
    params = {
        {'jobId', 'id'},
        {'charId', 'id'},
    },
}, function(source, _, jobId, charId)

    -- Admin path, no actor arg. Bank revocation, the player's job list and this panel are all
    -- updated inside Jobs.fire.
    local ok, err = Jobs.fire(jobId, charId)
    if ok then
        ShowSuccess(source, ('Fired charId #%d'):format(charId))
    else
        jmBroadcast()
        return false, err or 'Failed to fire'
    end
end)

--- Set Employee Role
SecureEvent('whip_core:server:jmSetRole', {
    ace = 'whip.devtools',
    params = {
        {'jobId', 'id'},
        {'charId', 'id'},
        {'roleId', 'id'},
    },
}, function(source, _, jobId, charId, roleId)

    -- Admin path, no actor arg. Bank access, the player's job list and this panel are all updated
    -- inside Jobs.setRole.
    local ok, err = Jobs.setRole(jobId, charId, roleId)
    if ok then
        ShowSuccess(source, 'Role changed')
    else
        jmBroadcast()
        return false, err or 'Failed to change role'
    end
end)

-- ============================================
-- The job wizard: a job set up, or changed, in one go
-- ============================================
--
-- html/js/wp/jobs.js. Its steps are Name, Ranks, Owner and Staff; Create makes the job with its ranks
-- and hires its people, and Save writes a job's changes in the one order that works:
--
--   people fired → the job (name, owner) → ranks changed, then new → people moved, hired → ranks removed
--
-- (fired first: a new owner is refused while another character of theirs works there)
--
-- (a rank is removed last because its people move off it first, in the same Save; one nobody held
-- goes first, so a rank can be renamed to the name of one removed). Each step is the Jobs API's own
-- call, with its rules — a Save that half goes through says which parts did not, in sentences.

local JM_MAX_RANKS  = 20
local JM_MAX_PEOPLE = 50

--- The wizard's ranks, checked: { { roleId?, name, level, permissions } }. The list (names and levels
--- cleaned in place), or false and why.
local function jmCheckRanks(ranks)
    if type(ranks) ~= 'table' or #ranks == 0 then return false, 'A job needs at least one rank' end
    if #ranks > JM_MAX_RANKS then return false, ('A job has at most %d ranks'):format(JM_MAX_RANKS) end
    local seen, top = {}, false
    for i, r in ipairs(ranks) do
        if type(r) ~= 'table' then return false, ('Rank %d is missing'):format(i) end
        local name = Sanitize.string(r.name, 60, '')
        if name == '' then return false, ('Rank %d has no name'):format(i) end
        local level = Sanitize.id(r.level, 1, 100)
        if not level then return false, ('"%s": a level is a whole number from 1 to 100'):format(name) end
        if seen[name:lower()] then return false, ('Two ranks are called "%s"'):format(name) end
        seen[name:lower()] = true
        if level == 100 then top = true end
        r.name, r.level = name, level
        if type(r.permissions) ~= 'table' then r.permissions = {} end
    end
    if not top then return false, 'The top rank is level 100: the owner holds it' end
    return ranks
end

--- Hire the wizard's people: { { charId, rank (roleId or name), name } }. Each refusal is a sentence
--- in `problems`.
local function jmHireList(jobId, list, hiredBy, problems)
    if type(list) ~= 'table' then return end
    for i, h in ipairs(list) do
        if i > JM_MAX_PEOPLE then break end
        local charId = type(h) == 'table' and Sanitize.id(h.charId)
        local who = type(h) == 'table' and Sanitize.string(h.name, 60, '') or ''
        if who == '' then who = '#' .. tostring(charId or '?') end
        local role = charId and Jobs.resolveRole(jobId, h.rank)
        if not role then
            problems[#problems + 1] = ('%s was not hired: no such rank'):format(who)
        else
            local ok, why = Jobs.hire(jobId, charId, role.roleId, hiredBy)
            if not ok then problems[#problems + 1] = ('%s was not hired: %s'):format(who, why or 'refused') end
        end
    end
end

--- The wizard's Create: the job, its ranks and its people. { ok, jobId, problems } or { ok = false, why }.
SecureCallback('whip_core:jmWizardCreate', {
    ace    = 'whip.devtools',
    params = { {'data', 'any'} },
}, function(_, player, data)
    if type(data) ~= 'table' then return { ok = false, why = 'Nothing to make a job from' } end
    local name = Sanitize.string(data.name, 100, '')
    if name == '' then return { ok = false, why = 'Give the job a name' } end
    local key = type(data.key) == 'string' and data.key:match('^%s*(.-)%s*$') or ''
    if key == '' then key = Jobs.keyFromName(name) end
    local ranks, why = jmCheckRanks(data.ranks)
    if not ranks then return { ok = false, why = why } end

    local roles = {}
    for i, r in ipairs(ranks) do roles[i] = { name = r.name, level = r.level, permissions = r.permissions } end
    local job, note = Jobs.create({
        key         = key,
        name        = name,
        ownerCharId = Sanitize.id(data.ownerCharId),
        createdBy   = player and player.charId or nil,
        roles       = roles,
    })
    if not job then
        jmBroadcast()
        return { ok = false, why = note or 'The job was not made' }
    end

    local problems = {}
    if note == 'account_not_created' then
        problems[#problems + 1] = 'its business account could not be made: check the server console'
    end
    jmHireList(job.jobId, data.hire, player and player.charId or nil, problems)
    jmBroadcast()
    return { ok = true, jobId = job.jobId, key = job.key, problems = problems }
end)

--- The wizard's Save on a job that exists. Only the parts sent are touched:
---   name, ownerCharId (0 = nobody)
---   ranks   the whole list as it should be: { roleId? , name, level, permissions } (no roleId = new)
---   staff   { fire = { charId }, move = { { charId, rank } }, hire = { { charId, rank, name } } }
--- { ok, problems }: ok only when every part went through.
SecureCallback('whip_core:jmWizardSave', {
    ace    = 'whip.devtools',
    params = { {'jobId', 'id'}, {'data', 'any'} },
}, function(_, player, jobId, data)
    if not Jobs.cache[jobId] then return { ok = false, why = 'No such job' } end
    if type(data) ~= 'table' then return { ok = false, why = 'Nothing to change' } end
    local problems = {}

    -- The ranks are checked before anything is written: a list that does not stand changes nothing.
    local ranks = nil
    if data.ranks ~= nil then
        local why
        ranks, why = jmCheckRanks(data.ranks)
        if not ranks then return { ok = false, why = why } end
    end

    -- 0. People let go, FIRST: a new owner is refused while another character of theirs works
    -- there (Config.JobOneCharacterPerAccount), so "B owns it, B's alt goes" in one Save must fire before the owner
    -- changes. A fire never depends on the owner; moves and hires still come after the ranks below.
    local staff = type(data.staff) == 'table' and data.staff or {}
    local n = 0
    for _, charId in ipairs(type(staff.fire) == 'table' and staff.fire or {}) do
        n = n + 1
        if n > JM_MAX_PEOPLE then break end
        local id = Sanitize.id(charId)
        ---@type boolean, string|nil
        local ok, why = false, 'no such person'
        if id then ok, why = Jobs.fire(jobId, id) end
        if not ok then problems[#problems + 1] = ('#%s was not let go: %s'):format(tostring(charId), why or 'refused') end
    end

    -- 1. The job itself.
    if data.name ~= nil or data.ownerCharId ~= nil then
        local upd = {}
        if data.name ~= nil then
            local name = Sanitize.string(data.name, 100, '')
            if name ~= '' then upd.name = name end
        end
        if data.ownerCharId ~= nil then upd.ownerCharId = Sanitize.id(data.ownerCharId) or false end
        local ok, why = Jobs.update(jobId, upd)
        if not ok then
            problems[#problems + 1] = why or 'The job was not changed'
        elseif why == 'account_not_moved' or why == 'account_not_created' then
            problems[#problems + 1] = 'its business account could not follow the new owner: check the server console'
        end
    end

    -- 2. Ranks: unused ones removed first, then changed, then new. Removed ones still held go last.
    local removeLater = {}
    if ranks then
        local listed = {}
        for _, r in ipairs(ranks) do
            local id = Sanitize.id(r.roleId)
            if id then listed[id] = true end
        end
        local held = {}
        for _, emp in pairs(Jobs.employees[jobId] or {}) do held[emp.roleId] = true end
        local gone = {}
        for roleId in pairs(Jobs.roles[jobId] or {}) do
            if not listed[roleId] then gone[#gone + 1] = roleId end
        end
        for _, roleId in ipairs(gone) do
            if held[roleId] then
                removeLater[#removeLater + 1] = roleId
            else
                local role = Jobs.getRole(roleId)
                local ok, why = Jobs.deleteRole(roleId)
                if not ok then problems[#problems + 1] = ('Rank "%s" was not removed: %s'):format(role and role.name or '?', why or 'refused') end
            end
        end
        for _, r in ipairs(ranks) do
            local roleId = Sanitize.id(r.roleId)
            local current = roleId and (Jobs.roles[jobId] or {})[roleId]
            if current then
                local perms = Jobs.cleanPermissions(jobId, r.permissions)
                if current.name ~= r.name or current.level ~= r.level or not Registry.deepEquals(current.permissions or {}, perms) then
                    local ok, why = Jobs.updateRole(roleId, { name = r.name, level = r.level, permissions = perms })
                    if not ok then problems[#problems + 1] = ('Rank "%s" was not changed: %s'):format(r.name, why or 'refused') end
                end
            end
        end
        for _, r in ipairs(ranks) do
            local roleId = Sanitize.id(r.roleId)
            if not (roleId and (Jobs.roles[jobId] or {})[roleId]) then
                local role, why = Jobs.createRole(jobId, { name = r.name, level = r.level,
                    permissions = Jobs.cleanPermissions(jobId, r.permissions) })
                if not role then problems[#problems + 1] = ('Rank "%s" was not added: %s'):format(r.name, why or 'refused') end
            end
        end
    end

    -- 3. People: moved to another rank, hired (the fires went first, step 0).
    for _, m in ipairs(type(staff.move) == 'table' and staff.move or {}) do
        n = n + 1
        if n > JM_MAX_PEOPLE then break end
        local id = type(m) == 'table' and Sanitize.id(m.charId)
        local role = id and Jobs.resolveRole(jobId, m.rank)
        ---@type boolean, string|nil
        local ok, why = false, 'no such rank'
        if role then ok, why = Jobs.setRole(jobId, id, role.roleId) end
        if not ok then problems[#problems + 1] = ('#%s did not change rank: %s'):format(tostring(id or '?'), why or 'refused') end
    end
    jmHireList(jobId, staff.hire, player and player.charId or nil, problems)

    -- 4. The ranks removed that people held, now they have moved off them.
    for _, roleId in ipairs(removeLater) do
        local role = Jobs.getRole(roleId)
        local ok, why = Jobs.deleteRole(roleId)
        if not ok then problems[#problems + 1] = ('Rank "%s" was not removed: %s'):format(role and role.name or '?', why or 'refused') end
    end

    jmBroadcast()
    return { ok = #problems == 0, problems = problems }
end)

-- ============================================
-- Shop Manager Dev Tool
-- ============================================

local function smBroadcast()
    if not next(DevTools.viewers.sm) then return end
    local payload = {
        shops = Shops.getAll(),
        jobs  = Jobs.getAll(),
    }
    DevTools.eachViewer(DevTools.viewers.sm, function(src)
        TriggerClientEvent('whip_core:client:smRefresh', src, payload)
    end)
end
Shops.setPanelRefresh(smBroadcast)

--- The containers a stocked shop can sell from, for the set-up wizard's Stock step: the saved ones
--- (a run's container, persist = false, goes when its run ends), and only what the step shows.
local function smStockRooms()
    local out = {}
    for id, def in pairs(Containers.getAll()) do
        if def.persist ~= false then
            out[#out + 1] = { containerId = id, name = def.name, type = def.type, x = def.x, y = def.y, z = def.z }
        end
    end
    table.sort(out, function(a, b) return a.containerId < b.containerId end)
    return out
end

--- Open Shop Manager. The items and stock rooms are for the set-up wizard (html/js/wp/shops.js): its
--- Goods step is the Item Browser's list, and its Stock step lists the containers.
SecureEvent('whip_core:server:smGetAll', {
    ace = 'whip.devtools',
    requirePlayer = false,
}, function(source)
    DevTools.viewers.sm[source] = true
    -- The keys config.lua's Config.Shops starts shops with: a shop's page says where its key came from.
    local configShops = {}
    for key in pairs(Config.Shops or {}) do configShops[#configShops + 1] = key end
    TriggerClientEvent('whip_core:client:smAllShops', source, {
        shops       = Shops.getAll(),
        jobs        = Jobs.getAll(),
        items       = ibBuildItemList(),
        containers  = smStockRooms(),
        configShops = configShops,
    })
end)

--- Close Shop Manager
SecureEvent('whip_core:server:smClosed', {   -- no ACE: see plmClosed
    requirePlayer = false, whileDead = true,
}, function(source)
    DevTools.viewers.sm[source] = nil
end)

-- A text box the admin may leave blank. Blank is "none" (nil), never an empty string saved to the
-- row: an empty `key` would index the shop under '' and an empty npcModel would ask for model "".
local function optionalText(val, maxLen)
    local s = Sanitize.string(val, maxLen)
    if s == '' then return nil end
    return s
end

--- The most goods the set-up wizard prices in one go: a shop's shelf, not a warehouse.
local SM_MAX_PRICES = 200

--- A stocked shop's prices (the wizard's Prices step): per item, on its stock room, as Manage Stock
--- sets them. Its shelf is whatever the staff put in that room; these say what each thing costs.
--- `data.prices` = { item = price } puts each on sale at that price; `data.unsell` = { item, ... }
--- takes each off sale (its price is kept, as Manage Stock's Mark For Sale does). Answers how many
--- did not take.
---@param def table   the shop, as it is now
---@param data table  what the panel sent
---@return number unpriced
local function smApplyPrices(def, data)
    if def.mode ~= 'stocked' or not def.containerId then return 0 end
    local unpriced, n = 0, 0
    if type(data.prices) == 'table' then
        for itemKey, price in pairs(data.prices) do
            n = n + 1
            if n > SM_MAX_PRICES then break end
            if type(itemKey) ~= 'string' or not Shops.setItemPrice(def.containerId, itemKey, price, true) then
                unpriced = unpriced + 1
            end
        end
    end
    if type(data.unsell) == 'table' then
        for _, itemKey in ipairs(data.unsell) do
            n = n + 1
            if n > SM_MAX_PRICES then break end
            local current = type(itemKey) == 'string' and Shops.getItemPrice(def.containerId, itemKey)
            if current and not Shops.setItemPrice(def.containerId, itemKey, current.price or 0, false) then
                unpriced = unpriced + 1
            end
        end
    end
    return unpriced
end

--- Make a shop from the panel: the set-up wizard's Create, or a script calling smCreateShop.
--- `def, nil, unpriced` or `false, why`. `unpriced` counts the wizard's prices that did not take.
---@return table|false def
---@return string|nil why
---@return number|nil unpriced
local function smCreate(player, data)
    if type(data) ~= 'table' then return false, 'Nothing to make a shop from' end

    -- 0 / blank means NONE, and a named id must EXIST: the panel sends 0 for "no job", which is truthy
    -- in Lua (and clamped, would be job #1).
    local jobId       = Sanitize.id(data.jobId)
    local containerId = Sanitize.id(data.containerId)
    if jobId and not Jobs.cache[jobId] then
        return false, ('No job #%d'):format(jobId)
    end
    if containerId and not Containers.getDef(containerId) then
        return false, ('No container #%d'):format(containerId)
    end

    local def, createErr = Shops.create({
        key         = optionalText(data.key, 60),
        name        = Sanitize.string(data.name, 100, 'New Shop'),
        mode        = Sanitize.enum(data.mode, {'infinite', 'stocked', 'npc'}) or 'npc',
        jobId       = jobId,
        containerId = containerId,
        npcModel    = optionalText(data.npcModel, 60),
        prop        = optionalText(data.prop, 60),
        x           = Sanitize.number(data.x, -10000, 10000, 0),
        y           = Sanitize.number(data.y, -10000, 10000, 0),
        z           = Sanitize.number(data.z, -1000, 10000, 0),
        heading     = Sanitize.number(data.heading, 0, 360, 0),
        -- 0 is the panel's "no blip" (a sprite-0 blip is an invisible dot on the map).
        blipSprite  = Sanitize.id(data.blipSprite, 1, 999),
        blipColor   = Sanitize.int(data.blipColor, 0, 99, 2),
        catalog     = type(data.catalog) == 'table' and data.catalog or nil,
        createdBy   = player and player.charId or nil,
    })

    if not def then return false, 'Failed to create shop: ' .. tostring(createErr or 'unknown error') end
    return def, nil, smApplyPrices(def, data)
end

--- Create Shop (dev tool)
SecureEvent('whip_core:server:smCreateShop', {
    ace = 'whip.devtools',
    params = { {'data', 'any'} },
}, function(source, player, data)
    if type(data) ~= 'table' then return end
    local def, why = smCreate(player, data)
    if not def then return false, why end
    ShowSuccess(source, 'Shop created: #' .. def.shopId)
    smBroadcast()
end)

--- The set-up wizard's Create: the shop, and its id back, so the wizard can open it once it is made.
SecureCallback('whip_core:smWizardCreate', {
    ace    = 'whip.devtools',
    params = { {'data', 'any'} },
}, function(_, player, data)
    local def, why, unpriced = smCreate(player, data)
    if not def then return { ok = false, why = why } end
    smBroadcast()
    return { ok = true, shopId = def.shopId, unpriced = unpriced }
end)

--- Change a shop from the panel: the edit wizard's Save, or a script calling smUpdateShop.
--- `true, nil, unpriced` or `false, why`; a stocked shop's prices are set as smApplyPrices says.
---@return boolean ok
---@return string|nil why
---@return number|nil unpriced
local function smUpdate(shopId, data)
    if type(data) ~= 'table' then return false, 'Nothing to change' end

    -- Blank / 0 becomes `false`, which Shops.update reads as "clear it" (nil would be "not mentioned").
    local updateData = {}
    if data.key ~= nil then updateData.key = optionalText(data.key, 60) or false end
    if data.name ~= nil then updateData.name = Sanitize.string(data.name, 100, 'Shop') end
    if data.mode ~= nil then updateData.mode = Sanitize.enum(data.mode, {'infinite', 'stocked', 'npc'}) end
    -- Same rule as create: 0 means none, and a named id must exist (never clamped onto #1).
    if data.jobId ~= nil then
        local jobId = Sanitize.id(data.jobId)
        if jobId and not Jobs.cache[jobId] then
            return false, ('No job #%d'):format(jobId)
        end
        updateData.jobId = jobId or false
    end
    if data.containerId ~= nil then
        local containerId = Sanitize.id(data.containerId)
        if containerId and not Containers.getDef(containerId) then
            return false, ('No container #%d'):format(containerId)
        end
        updateData.containerId = containerId or false
    end
    if data.npcModel ~= nil then updateData.npcModel = optionalText(data.npcModel, 60) or false end
    if data.prop ~= nil then updateData.prop = optionalText(data.prop, 60) or false end
    if data.x ~= nil then updateData.x = Sanitize.number(data.x, -10000, 10000) end
    if data.y ~= nil then updateData.y = Sanitize.number(data.y, -10000, 10000) end
    if data.z ~= nil then updateData.z = Sanitize.number(data.z, -1000, 10000) end
    if data.heading ~= nil then updateData.heading = Sanitize.number(data.heading, 0, 360) end
    if data.blipSprite ~= nil then updateData.blipSprite = Sanitize.id(data.blipSprite, 1, 999) or false end
    if data.blipColor ~= nil then updateData.blipColor = Sanitize.int(data.blipColor, 0, 99, 2) end
    if data.catalog ~= nil then updateData.catalog = type(data.catalog) == 'table' and data.catalog or nil end

    local ok, err = Shops.update(shopId, updateData)
    if not ok then
        return false, err and ('Shop not updated: %s'):format(tostring(err)) or 'Shop not found'
    end
    -- Prices last, on the shop as it now is (a new stock room is the one priced).
    return true, nil, smApplyPrices(Shops.cache[shopId] or {}, data)
end

--- Update Shop (dev tool)
SecureEvent('whip_core:server:smUpdateShop', {
    ace = 'whip.devtools',
    params = {
        {'shopId', 'id'},
        {'data', 'any'},
    },
}, function(source, _, shopId, data)
    if type(data) ~= 'table' then return end
    local ok, why = smUpdate(shopId, data)
    if not ok then return false, why end
    ShowSuccess(source, 'Shop updated')
    smBroadcast()
end)

--- The edit wizard's Save: whether it took, and why not.
SecureCallback('whip_core:smWizardUpdate', {
    ace    = 'whip.devtools',
    params = { {'shopId', 'id'}, {'data', 'any'} },
}, function(_, _, shopId, data)
    local ok, why, unpriced = smUpdate(shopId, data)
    if not ok then return { ok = false, why = why } end
    smBroadcast()
    return { ok = true, unpriced = unpriced }
end)

--- What a stock room sells now, { item = price } (on sale only), for the wizard's Prices step: a shop
--- being edited, or a new one given a room that already has prices.
SecureCallback('whip_core:smStockPrices', {
    ace    = 'whip.devtools',
    params = { {'containerId', 'id'} },
}, function(_, _, containerId)
    if not Containers.getDef(containerId) then return { ok = false, why = ('No container #%d'):format(containerId) } end
    Shops.loadPrices(containerId)
    local cache = Shops.priceCache[containerId]
    if not cache then return { ok = false, why = 'Its prices could not be read' } end
    local prices = {}
    for item, p in pairs(cache) do
        if p.forSale then prices[item] = p.price end
    end
    return { ok = true, prices = prices }
end)

--- Delete Shop (dev tool)
SecureEvent('whip_core:server:smDeleteShop', {
    ace = 'whip.devtools',
    params = {
        {'shopId', 'id'},
    },
}, function(source, _, shopId)
    -- Its reason, not always "not found": "being changed — try again", a database error
    local ok, why = Shops.delete(shopId)
    if not ok then return false, why or 'Shop not found' end
    ShowSuccess(source, 'Shop deleted')
    smBroadcast()
end)

-- (The shop exports live in shops.lua, SystemDeposit in bank.lua and the time/weather exports in
-- time.lua, with the modules that own them. Shop LOADING runs from player_lifecycle.lua's startup
-- sequence with every other loadAll.)

-- ============================================
-- Time & Weather — Events + Dev Tool
-- ============================================

local function twBroadcast()
    if not next(DevTools.viewers.tw) then return end
    local payload = TimeWeather.getSyncData()
    payload.weatherTypes = TimeWeather.getWeatherTypes()
    DevTools.eachViewer(DevTools.viewers.tw, function(src)
        TriggerClientEvent('whip_core:client:twRefresh', src, payload)
    end)
end

--- Set Time (admin)
SecureEvent('whip_core:server:twSetTime', {
    ace = 'whip.devtools',
    params = {
        {'hour', 'int', 0, 23},
        {'minute', 'int', 0, 59},
    },
}, function(source, _, hour, minute)
    TimeWeather.setTime(hour, minute)
    ShowSuccess(source, ('Time set to %02d:%02d'):format(hour, minute))
    twBroadcast()
end)

--- Set Weather (admin)
SecureEvent('whip_core:server:twSetWeather', {
    ace = 'whip.devtools',
    params = {
        {'weather', 'enum', Config.WeatherTypes},
    },
}, function(source, _, weather)
    TimeWeather.setWeather(weather)
    ShowSuccess(source, 'Weather set to ' .. weather)
    twBroadcast()
end)

--- Toggle Freeze (admin)
SecureEvent('whip_core:server:twSetFrozen', {
    ace = 'whip.devtools',
    params = { {'frozen', 'bool'} },
}, function(source, _, frozen)
    TimeWeather.setFrozen(frozen)
    ShowSuccess(source, frozen and 'Time frozen' or 'Time unfrozen')
    twBroadcast()
end)

--- Toggle Blackout (admin)
SecureEvent('whip_core:server:twSetBlackout', {
    ace = 'whip.devtools',
    params = { {'blackout', 'bool'} },
}, function(source, _, blackout)
    TimeWeather.setBlackout(blackout)
    ShowSuccess(source, blackout and 'Blackout enabled' or 'Blackout disabled')
    twBroadcast()
end)

--- Set Time Scale (admin)
SecureEvent('whip_core:server:twSetTimeScale', {
    ace = 'whip.devtools',
    params = { {'scale', 'number', 0, 10} },
}, function(source, _, scale)
    TimeWeather.setTimeScale(scale)
    ShowSuccess(source, ('Time scale set to %.1f'):format(scale))
    twBroadcast()
end)

--- Open Time Manager (dev tool)
SecureEvent('whip_core:server:twGetAll', {
    ace = 'whip.devtools',
    requirePlayer = false,
}, function(source)
    DevTools.viewers.tw[source] = true
    local data = TimeWeather.getSyncData()
    data.weatherTypes = TimeWeather.getWeatherTypes()
    TriggerClientEvent('whip_core:client:twAllData', source, data)
end)

--- Close Time Manager
SecureEvent('whip_core:server:twClosed', {   -- no ACE: see plmClosed
    requirePlayer = false, whileDead = true,
}, function(source)
    DevTools.viewers.tw[source] = nil
end)

-- (The time & weather exports live in time.lua, with TimeWeather.)
