-- ============================================
-- Permissions — rights an admin gives a player's ACCOUNT in game
-- ============================================
--
-- Some things are for more people than whip's full admins, but not for everyone: building Director
-- scenarios, say. A PERMISSION is a named right a resource declares; an admin gives it to an
-- account in the /whip panel; code asks whether a player has it:
--
--   exports.whip_core:RegisterPermission('director.build', { label = 'Director builder',
--       description = 'Make, edit, test and switch on scenarios' })
--   exports.whip_core:HasPermission(source, 'director.build')        --> true / false
--   exports.whip_core:GrantPermission(source, 'director.build')      --> true, or false and why
--   exports.whip_core:RevokePermission({ charId = 12 }, 'director.build')   --> a person: source, { charId }, { userId }
--   exports.whip_core:GetPermissionHolders('director.build')         --> { { userId, name, grantedBy, grantedAt } }
--
--   * PER ACCOUNT: a grant is to the account (users.userId), so every character on
--     it has the right.
--   * ONE CAN INCLUDE OTHERS: `implies = { 'director.build' }` (a Director admin is a builder too).
--   * FULL ADMINS HOLD THEM ALL: anyone with the whip.devtools ACE has every permission, unless one
--     says `devtools = false`. (whip.devtools holders count as Director admins.)
--   * WHO MAY GIVE IT, in whip's own screens: `grantedBy` names the permission that may (default:
--     full admins only). The exports themselves are server code, and trusted as such.
--   * KEPT in the `whip_permissions` table, read once at start (it is small) and held in memory, so
--     asking costs nothing. A grant or revoke is written, then believed.
--
-- THE GATE: SecureEvent and SecureCallback take `permission = 'name'` (or a list: any of them),
-- checked in server/secure.lua before the handler runs. It does NOT excuse the dead-player rule the
-- way an `ace` does (decision 2): a schema that must work for a dead player says `whileDead = true`.

Permissions = { ready = false }

local CORE = GetCurrentResourceName()
local DEVTOOLS = 'whip.devtools'

local defs = {}     -- [name] = { name, label, description, implies = { name, ... }, devtools, grantedBy, owner }
local grants = {}   -- [userId] = { [name] = { grantedBy, grantedByName, grantedAt } }

-- The declarations, on shared/registry.lua: a name belongs to the resource that declared it, and goes when that resource stops. Its
-- grants stay — they are the server's records, and come back into force when it declares the name again.
local defReg = Registry.new('permissions', { label = 'permission', store = defs, prefixed = true })

local function say(fmt, ...) print(('[whip_core:permissions] ' .. fmt):format(...)) end

local function validName(n)
    return type(n) == 'string' and #n >= 3 and #n <= 64 and n:match('^[%w_%.%-]+$') ~= nil
end

local function q(sql, params)
    local ok, res = pcall(MySQL.query.await, sql, params or {})
    if not ok then return nil, tostring(res) end
    return res
end

-- ============================================
-- Declaring
-- ============================================

--- Declare a permission. The resource that declares a name owns it; declaring it again (a restart)
--- replaces its words. Answers true, or false and why.
---@param owner string   Registry.caller()
---@param name string    e.g. 'director.build': letters, digits, '.', '_' and '-'
---@param def table|nil  { label, description, implies = { name, ... }, devtools = true, grantedBy = name }
function Permissions.register(owner, name, def)
    if not validName(name) then return false, 'a permission is 3-64 letters, digits, ".", "_" and "-"' end
    def = type(def) == 'table' and def or {}
    local implies = {}
    for _, other in ipairs(type(def.implies) == 'table' and def.implies or {}) do
        if not validName(other) then return false, 'implies: ' .. tostring(other) .. ' is not a permission name' end
        if other ~= name then implies[#implies + 1] = other end
    end
    if def.grantedBy ~= nil and not validName(def.grantedBy) then return false, 'grantedBy must be a permission name' end
    -- Another running resource's name is refused; the same owner declaring again replaces its words.
    local ok, why = defReg:add(owner, name, {
        name = name, owner = owner,
        label = type(def.label) == 'string' and def.label:sub(1, 60) or name,
        description = type(def.description) == 'string' and def.description:sub(1, 200) or nil,
        implies = implies,
        devtools = def.devtools ~= false,
        grantedBy = def.grantedBy,
    })
    if not ok then return false, why end
    return true
end

function Permissions.get(name)
    return defs[name]
end

--- Every permission declared: { name, label, description, implies, grantedBy, owner }.
function Permissions.list()
    local out = {}
    for _, d in pairs(defs) do
        out[#out + 1] = { name = d.name, label = d.label, description = d.description, implies = d.implies,
                          grantedBy = d.grantedBy, owner = d.owner }
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- ============================================
-- Asking
-- ============================================

--- Does this account hold `name` by a grant (its own, or one that includes it)? Walks `implies` with
--- a seen-set, so a loop in the declarations ends.
local function grantedTo(userId, name)
    local mine = userId and grants[userId]
    if not mine then return false end
    if mine[name] then return true end
    local seen, stack = {}, {}
    for held in pairs(mine) do stack[#stack + 1] = held end
    while #stack > 0 do
        local held = table.remove(stack)
        if not seen[held] then
            seen[held] = true
            local d = defs[held]
            for _, other in ipairs(d and d.implies or {}) do
                if other == name then return true end
                stack[#stack + 1] = other
            end
        end
    end
    return false
end

--- Does this player have `name`? Full admins (whip.devtools) have every permission that allows it;
--- anyone else needs a grant on their account. A server id that is not a player has none.
---@param src number|nil
---@param name string
---@return boolean
function Permissions.has(src, name)
    if type(src) ~= 'number' or src <= 0 or not validName(name) then return false end
    local d = defs[name]
    -- A full admin's rights need developer mode on (DevTools.hasAce); their grants, like anyone's, do not.
    if (d == nil or d.devtools) and DevTools.hasAce(src, DEVTOOLS) then return true end
    -- The account: a loaded character's, or (on the character screen) the joined player's.
    local p = (Players and Players[src]) or (PendingPlayers and PendingPlayers[src])
    return p ~= nil and grantedTo(p.userId, name)
end

--- Any of these? `names` is a name or a list of names (the SecureEvent `permission` key's shapes).
function Permissions.hasAny(src, names)
    if type(names) == 'string' then return Permissions.has(src, names) end
    for _, n in ipairs(type(names) == 'table' and names or {}) do
        if Permissions.has(src, n) then return true end
    end
    return false
end

--- Does this ACCOUNT have `name` (by a grant; full admins are an ACE, which needs a player)?
function Permissions.accountHas(userId, name)
    return grantedTo(math.tointeger(tonumber(userId)), name)
end

--- May this player give (or take away) `name` from the /whip panel? Full admins may give anything;
--- a permission's `grantedBy` names who else may.
---
--- Not a temporary admin: dev tools given from the panel end at the restart; a grant
--- is saved and does not. Their ACE counts for neither route: `grantedBy` is asked of grants only.
function Permissions.mayGrant(src, name)
    if DevTools.hasAce(src, DEVTOOLS) and not DevTools.isTemporary(src) then return true end
    local d = defs[name]
    if d == nil or d.grantedBy == nil then return false end
    local p = (Players and Players[src]) or (PendingPlayers and PendingPlayers[src])
    return p ~= nil and grantedTo(p.userId, d.grantedBy)
end

-- ============================================
-- Giving and taking away
-- ============================================

local function byWho(by)
    local p = type(by) == 'number' and Players and Players[by] or nil
    if p then return p.userId, p.fullName, p.charId end
    return nil, type(by) == 'string' and by or 'the server', nil
end

--- On the activity log, under whoever did it (their character's timeline), or as a system line.
local function logLine(charId, event, detail)
    if Log and Log.write then Log.write(charId, event, { detail = detail }) end
end

local function changed(userId, name, granted)
    -- Anyone on the account who is online is told (a screen they have open can re-ask).
    for src, p in pairs(Players or {}) do
        if p.userId == userId then
            TriggerClientEvent('whip_core:client:permissionChanged', src, { permission = name, granted = granted })
        end
    end
    WhipEmit('whip_core:permission:changed', { userId = userId, permission = name, granted = granted })
end

--- Give an account a permission. Answers true, or false and why.
---@param userId number|nil
---@param name string
---@param by number|string|nil  who gave it (a server id, a resource name, or nil: the server)
function Permissions.grant(userId, name, by)
    userId = math.tointeger(tonumber(userId))
    if not userId or userId <= 0 then return false, 'that is not an account' end
    if not defs[name] then return false, 'no permission called ' .. tostring(name) end
    if not Permissions.ready then return false, 'permissions are still loading' end
    if grants[userId] and grants[userId][name] then return true end
    local gid, gname, gchar = byWho(by)
    local res, err = q([[INSERT INTO `whip_permissions` (`userId`, `permission`, `grantedBy`, `grantedByName`)
                         VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE `permission` = `permission`]],
        { userId, name, gid, gname })
    if not res then
        say('could not give %s to account %d: %s', name, userId, tostring(err))
        return false, DB_ERROR
    end
    grants[userId] = grants[userId] or {}
    grants[userId][name] = { grantedBy = gid, grantedByName = gname, grantedAt = os.time() * 1000 }
    logLine(gchar, 'permission_given', ('%s to account %d, by %s'):format(name, userId, tostring(gname)))
    changed(userId, name, true)
    return true
end

--- Take a permission away from an account. Answers true (also when it never had it), or false and why.
function Permissions.revoke(userId, name, by)
    userId = math.tointeger(tonumber(userId))
    if not userId or userId <= 0 then return false, 'that is not an account' end
    if not validName(name) then return false, 'no permission called ' .. tostring(name) end
    if not Permissions.ready then return false, 'permissions are still loading' end
    if not (grants[userId] and grants[userId][name]) then return true end
    local res, err = q('DELETE FROM `whip_permissions` WHERE `userId` = ? AND `permission` = ?', { userId, name })
    if not res then
        say('could not take %s from account %d: %s', name, userId, tostring(err))
        return false, DB_ERROR
    end
    grants[userId][name] = nil
    if next(grants[userId]) == nil then grants[userId] = nil end
    local _, gname, gchar = byWho(by)
    logLine(gchar, 'permission_taken', ('%s from account %d, by %s'):format(name, userId, tostring(gname)))
    changed(userId, name, false)
    return true
end

--- Who has been given `name` (directly: full admins hold everything without a row). Each holder's
--- name is the account's latest character, else its FiveM name. Waits on the database for names.
---@return table[] { userId, name, charId, grantedBy, grantedAt, online }
function Permissions.holders(name)
    local out, ids = {}, {}
    for userId, mine in pairs(grants) do
        local g = mine[name]
        if g then
            out[#out + 1] = { userId = userId, grantedBy = g.grantedByName, grantedAt = g.grantedAt }
            ids[#ids + 1] = userId
        end
    end
    if #ids == 0 then return out end
    local online = {}
    for _, p in pairs(Players or {}) do
        if p.userId and p.fullName then online[p.userId] = p end
    end
    local marks = {}
    for i = 1, #ids do marks[i] = '?' end
    -- Their character: the one they play now, else the one they played last (its name, and its id for the face).
    local rows = q(([[SELECT u.`userId`, u.`name` AS `account`,
                             (SELECT CONCAT(c.`firstName`, ' ', c.`lastName`) FROM `characters` c
                               WHERE c.`userId` = u.`userId` AND c.`deleted` IS NULL ORDER BY c.`lastPlayed` DESC LIMIT 1) AS `charName`,
                             (SELECT c.`charId` FROM `characters` c
                               WHERE c.`userId` = u.`userId` AND c.`deleted` IS NULL ORDER BY c.`lastPlayed` DESC LIMIT 1) AS `charId`
                        FROM `users` u WHERE u.`userId` IN (%s)]]):format(table.concat(marks, ',')), ids) or {}
    local names = {}
    for _, r in ipairs(rows) do
        names[tonumber(r.userId)] = { char = r.charName, charId = tonumber(r.charId), account = r.account }
    end
    for _, h in ipairs(out) do
        local n, p = names[h.userId] or {}, online[h.userId]
        h.name = (p and p.fullName) or n.char or n.account or ('account ' .. h.userId)
        h.charId = (p and p.charId) or n.charId
        h.account = n.account
        h.online = p ~= nil
    end
    table.sort(out, function(a, b) return tostring(a.name) < tostring(b.name) end)
    return out
end

-- ============================================
-- Start-up: the table, then every grant
-- ============================================
--
-- After whip_core is up, and never able to stop it: a table that cannot be made or read leaves
-- grants empty (full admins still hold everything) and says why.

function Permissions.ensureTable()
    return CreateTable('whip_permissions', [[
        CREATE TABLE IF NOT EXISTS `whip_permissions` (
            `userId`        INT UNSIGNED NOT NULL,
            `permission`    VARCHAR(64)  NOT NULL,
            `grantedBy`     INT UNSIGNED NULL,
            `grantedByName` VARCHAR(80)  NULL,
            `grantedAt`     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`userId`, `permission`),
            KEY `ix_whip_permissions_name` (`permission`),
            CONSTRAINT `fk_whip_permissions_user` FOREIGN KEY (`userId`)
                REFERENCES `users` (`userId`) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
end

function Permissions.loadAll()
    local rows, err = q('SELECT `userId`, `permission`, `grantedBy`, `grantedByName`, `grantedAt` FROM `whip_permissions`')
    if not rows then return false, err end
    grants = {}
    for _, r in ipairs(rows) do
        local uid = tonumber(r.userId)
        if uid then
            grants[uid] = grants[uid] or {}
            grants[uid][r.permission] = { grantedBy = r.grantedBy, grantedByName = r.grantedByName, grantedAt = r.grantedAt }
        end
    end
    Permissions.ready = true
    return #rows
end

CoreStart.add('permissions', function()
    if not Permissions.ensureTable() then
        say('^1the whip_permissions table could not be made: only full admins have permissions^0')
        return
    end
    local n, why = Permissions.loadAll()
    if not n then say('^1grants could not be read (%s): only full admins have permissions^0', tostring(why)) end
end)

-- ============================================
-- whip's own: the Director's two levels (decision 2)
-- ============================================

Permissions.register(CORE, 'director.build', {
    label = 'Director builder',
    description = 'See every scenario; make, edit, test, switch on and switch off',
    grantedBy = 'director.admin',
})
Permissions.register(CORE, 'director.admin', {
    label = 'Director admin',
    description = 'A builder who can also delete scenarios, accept shipped packs, export packs, and give or take Director access',
    implies = { 'director.build' },
    grantedBy = 'director.admin',
})
-- Dungeon Mode, its own, implied by neither: a builder makes scenarios, a Dungeon Master changes the world as it is
-- (server/director/live.lua). Nothing it does lasts past a restart; what would is a full admin's.
Permissions.register(CORE, 'director.live', {
    label = 'Dungeon Mode',
    description = 'Make NPCs, cars and props in the live world, and use the Object Viewer on anything, until the server restarts',
    grantedBy = 'director.admin',
})

-- ============================================
-- The /whip panel: which sections a player may open
-- ============================================
--
-- Full admins open every section. Anyone else, only the sections a permission opens (the Director's group,
-- html/js/wp/director.js: its pages for a builder, Access for a Director admin), and every action inside one is
-- gated on the server by the same permission.
Permissions.panelSections = {
    director          = 'director.build',   -- the Overview
    directorScenarios = 'director.build',
    directorLore      = 'director.build',
    directorShipped   = 'director.build',
    directorRuns      = 'director.build',
    directorAccess    = 'director.admin',
    directorLive      = 'director.live',
}

--- The sections `src` may open: 'all', a list of section ids, or nil (none).
function Permissions.panelAccess(src)
    if DevTools.hasAce(src, DEVTOOLS) then return 'all' end   -- developer mode on, too
    local list = {}
    for id, perm in pairs(Permissions.panelSections) do
        if Permissions.has(src, perm) then list[#list + 1] = id end
    end
    table.sort(list)
    return #list > 0 and list or nil
end

SecureCallback('whip_core:panel:access', { rateLimit = 500, burst = 3, whileDead = true, requirePlayer = false }, function(source)
    local access = Permissions.panelAccess(source)
    if not access then
        -- A developer with developer mode off is told how to get in (the client opener says nothing).
        if DevTools.isEligible(source) then
            DevTools.sayOff(source)
            return false, DevTools.OFF_REASON
        end
        DevTools.askedForTools(source)   -- the console's line that would make them an admin
        return false, 'You have no access to the admin panel'
    end
    -- permanent: whip.devtools from server.cfg, not the Player Manager's temporary tools. Only a
    -- permanent admin is shown the settings pages (Settings.mayEdit decides the same, and the
    -- server refuses anyone else's changes regardless).
    local permanent = access == 'all' and Settings.mayEdit(source)
    return { all = access == 'all', sections = access ~= 'all' and access or nil, permanent = permanent,
             -- Each satellite's settings page is a section of its own (wp/config.js makes them).
             settingsPages = permanent and Settings.satellitePages() or nil }
end)

-- ============================================
-- Exports
-- ============================================

exports('RegisterPermission', function(name, def)
    return Permissions.register(Registry.caller(), name, def)
end)

exports('HasPermission', function(source, name)
    return Permissions.has(tonumber(source), name)
end)

--- The account a person is on, for the two exports below: an online player's server id, { charId = n } (online or
--- not), or { userId = n } for an account itself. A bare number is a server id, as everywhere in whip, never an
--- account: GrantPermission(source, ...) next to HasPermission(source, ...) means the same player.
---@return integer|nil userId, string|nil why
local function accountOf(who)
    if type(who) == 'table' then
        if who.userId ~= nil then
            local uid = math.tointeger(tonumber(who.userId))
            if not uid or uid <= 0 then return nil, 'an account is { userId = n }' end
            return uid
        end
        local charId = Sanitize.id(who.charId)
        if not charId then return nil, 'a person is a server id, { charId = n } or { userId = n }' end
        local p = PlayersByCharId and PlayersByCharId[charId]
        if p and p.userId then return p.userId end
        local ok, uid = pcall(MySQL.scalar.await, 'SELECT `userId` FROM `characters` WHERE `charId` = ?', { charId })
        if not ok then return nil, DB_ERROR end
        uid = math.tointeger(tonumber(uid))
        if not uid then return nil, 'no such character' end
        return uid
    end
    local src = tonumber(who)
    local player = src and Players[src]
    if not player or not player.userId then
        return nil, 'No player with that server id is online (for a character, pass { charId = n }; for an account, { userId = n })'
    end
    return player.userId
end

exports('GrantPermission', function(who, name)
    local by = Registry.caller()   -- first, before anything can yield
    local userId, why = accountOf(who)
    if not userId then return false, why end
    return Permissions.grant(userId, name, by)
end)

exports('RevokePermission', function(who, name)
    local by = Registry.caller()
    local userId, why = accountOf(who)
    if not userId then return false, why end
    return Permissions.revoke(userId, name, by)
end)

exports('GetPermissionHolders', function(name)
    if not validName(name) then return false, 'no permission called ' .. tostring(name) end
    return Permissions.holders(name)
end)
