-- ============================================
-- Systems — the store: systems, their revisions, and what they remember
-- ============================================
--
-- The Systems Creator's OWN tables, never the Director's (a system in the Director's store would be
-- switched on, listed, copied and handed to satellites as a scenario):
--
--   systems            one row per system: its key, its SHORT ID (fixed at create; what its names and
--                      tags are made from), name, status (off / on / faulted, with the reason), the
--                      draft's revision, the one that is on, the revision whose POWERS an admin
--                      approved and which powers, and who last switched it
--   system_revisions   every saved revision's document, kept; the one that is on never changes
--   system_state       what a system REMEMBERS (a variable marked Remember): one row per variable,
--                      for everyone / a character / a car. Written through the `sysvar` save unit:
--                      whip's one way to save, never a save loop of its own (house rule 38)
--
-- Built and read after whip_core is up, and never able to stop it starting: a table that cannot be
-- made switches the Systems Creator off with the reason, and the rest of whip runs.
-- Saves are revision-checked, as the Director's: a save names the revision it was made from.

SystemStore = { ready = false }

local MAX_DOC = 512 * 1024
local MAX_STATE = 400        -- bytes of one remembered value, as JSON

local systems = {}   -- [key] = row
local byId = {}      -- [id] = key
local saving = {}    -- [key] = true while a save is with the database
local retiredShort = {}   -- [shortId] = true: a deleted system's, never handed out again
local pendingState = {}   -- [unit key] = { systemId, scope, name, value (json) | false (delete) }

local function say(fmt, ...) print(('[whip_core:systems] ' .. fmt):format(...)) end

local function q(sql, params)
    local ok, res = pcall(MySQL.query.await, sql, params or {})
    if not ok then return nil, tostring(res) end
    return res
end

-- ============================================
-- Tables
-- ============================================

function SystemStore.ensureTables()
    local ok = CreateTable('systems', [[
        CREATE TABLE IF NOT EXISTS `systems` (
            `id`             INT UNSIGNED NOT NULL AUTO_INCREMENT,
            `key`            VARCHAR(64)  NOT NULL,
            `shortId`        VARCHAR(10)  NOT NULL,
            `name`           VARCHAR(80)  NOT NULL,
            `description`    VARCHAR(500) NULL,
            `status`         VARCHAR(10)  NOT NULL DEFAULT 'off',
            `reason`         VARCHAR(200) NULL,
            `draftRev`       INT UNSIGNED NOT NULL DEFAULT 0,
            `activeRev`      INT UNSIGNED NULL,
            `approvedRev`    INT UNSIGNED NULL,
            `approvedPowers` VARCHAR(60)  NULL,
            `approvedByName` VARCHAR(80)  NULL,
            `switchedByName` VARCHAR(80)  NULL,
            `createdBy`      INT UNSIGNED NULL,
            `createdByName`  VARCHAR(80)  NULL,
            `createdAt`      TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `updatedBy`      INT UNSIGNED NULL,
            `updatedByName`  VARCHAR(80)  NULL,
            `updatedAt`      TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `deletedAt`      TIMESTAMP    NULL,
            PRIMARY KEY (`id`),
            UNIQUE KEY `uq_systems_key` (`key`),
            UNIQUE KEY `uq_systems_short` (`shortId`)
        )
    ]])
    ok = CreateTable('system_revisions', [[
        CREATE TABLE IF NOT EXISTS `system_revisions` (
            `systemId`     INT UNSIGNED NOT NULL,
            `rev`          INT UNSIGNED NOT NULL,
            `doc`          MEDIUMTEXT   NOT NULL,
            `powers`       VARCHAR(60)  NULL,
            `approvedPowers` VARCHAR(60) NULL,
            `approvedByName` VARCHAR(80) NULL,
            `editedBy`     INT UNSIGNED NULL,
            `editedByName` VARCHAR(80)  NULL,
            `note`         VARCHAR(200) NULL,
            `createdAt`    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`systemId`, `rev`),
            CONSTRAINT `fk_system_rev` FOREIGN KEY (`systemId`) REFERENCES `systems` (`id`) ON DELETE CASCADE
        )
    ]]) and ok
    ok = CreateTable('system_state', [[
        CREATE TABLE IF NOT EXISTS `system_state` (
            `systemId`  INT UNSIGNED NOT NULL,
            `scope`     VARCHAR(40)  NOT NULL,
            `name`      VARCHAR(32)  NOT NULL,
            `value`     VARCHAR(400) NOT NULL,
            `updatedAt` TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`systemId`, `scope`, `name`),
            CONSTRAINT `fk_system_state` FOREIGN KEY (`systemId`) REFERENCES `systems` (`id`) ON DELETE CASCADE
        )
    ]]) and ok
    return ok
end

-- ============================================
-- Reading
-- ============================================

local function remember(row)
    systems[row.key] = row
    byId[row.id] = row.key
end

function SystemStore.loadAll()
    local rows, err = q('SELECT * FROM `systems`')
    if not rows then return false, err end
    systems, byId, retiredShort = {}, {}, {}
    for _, r in ipairs(rows) do
        if r.deletedAt == nil then remember(r) else retiredShort[r.shortId] = true end
    end
    SystemStore.ready = true
    return true
end

--- A system's row as anyone may read it.
local function view(r)
    return { id = r.id, key = r.key, shortId = r.shortId, name = r.name, description = r.description,
             status = r.status, reason = r.reason, draftRev = r.draftRev, activeRev = r.activeRev,
             approvedRev = r.approvedRev, approvedPowers = r.approvedPowers, approvedBy = r.approvedByName,
             switchedBy = r.switchedByName, createdBy = r.createdByName, updatedBy = r.updatedByName }
end

--- (A row being deleted is gone already: SystemStore.delete.)
function SystemStore.get(key) local r = systems[key]; return r and not r.deleting and view(r) or nil end
function SystemStore.keyOf(id) return byId[id] end

function SystemStore.list()
    local out = {}
    for _, r in pairs(systems) do if not r.deleting then out[#out + 1] = view(r) end end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

--- A revision's document, decoded, its powers as saved, and the powers an admin approved FOR THIS
--- REVISION (approving a new draft must not take the running one's away). Answers doc, rev, powers ('items,money'), approved, or nil and why. WAITS on the database.
function SystemStore.revision(key, rev)
    local r = systems[key]
    if not r then return nil, 'no such system' end
    rev = math.tointeger(tonumber(rev) or r.draftRev)
    local rows, err = q('SELECT `doc`, `powers`, `approvedPowers` FROM `system_revisions` WHERE `systemId` = ? AND `rev` = ?', { r.id, rev })
    if not rows then return nil, err end
    if not rows[1] then return nil, 'no such revision' end
    local ok, doc = pcall(json.decode, rows[1].doc)
    if not ok or type(doc) ~= 'table' then return nil, 'that revision cannot be read' end
    return doc, rev, rows[1].powers or '', rows[1].approvedPowers
end

-- ============================================
-- Writing (admin actions: they answer)
-- ============================================

local function who(by)
    local p = by and Players[by]
    if p then return p.userId, p.fullName end
    return nil, 'the server'
end

--- The powers a document's cards have, as the approval lists them: 'items,money' (sorted, no repeats).
function SystemStore.powersOf(doc)
    local set = {}
    for _, n in ipairs(type(doc) == 'table' and type(doc.nodes) == 'table' and doc.nodes or {}) do
        local def = type(n) == 'table' and SystemCards.get(n.type) or nil
        if def and def.power then for _, p in ipairs(def.powers or { def.power }) do set[p] = true end end
    end
    local list = {}
    for p in pairs(set) do list[#list + 1] = p end
    table.sort(list)
    return table.concat(list, ',')
end

local function encode(doc)
    if type(doc) ~= 'table' then return nil, 'a system is a document (a table)' end
    if doc.format ~= 1 or doc.kind ~= 'system' then return nil, 'that is not a system document (format 1, kind "system")' end
    local ok, s = pcall(json.encode, doc)
    if not ok or type(s) ~= 'string' then return nil, 'that system cannot be written down' end
    if #s > MAX_DOC then return nil, ('a system is at most %d KB'):format(MAX_DOC // 1024) end
    return s
end

local function validKey(key)
    return type(key) == 'string' and #key >= 2 and #key <= 64 and key:match('^[%w_%-]+$') ~= nil
end

--- The short id for a new key: its letters and digits, lower case, 8 at most, made unique with a
--- number (`speedcam`, `speedca2`). Names and tags are made from it (modules refuse long or dotted
--- names).
local function shortIdFor(key)
    local base = key:lower():gsub('[^%w]', ''):sub(1, 8)
    if base == '' or not base:match('^%a') then base = ('s' .. base):sub(1, 8) end
    local taken = {}
    for _, r in pairs(systems) do taken[r.shortId] = true end
    for s in pairs(retiredShort) do taken[s] = true end
    if not taken[base] then return base end
    for i = 2, 999 do
        local tail = tostring(i)
        local id = base:sub(1, 10 - #tail) .. tail
        if not taken[id] then return id end
    end
    return nil
end

--- Make a new system from a document: answers its row, or false and why.
function SystemStore.create(key, name, doc, by)
    if not validKey(key) then return false, 'a system key is 2-64 letters, digits, _ and -' end
    if systems[key] then return false, 'there is already a system called ' .. key end
    if type(name) ~= 'string' or name == '' or #name > 80 then return false, 'a name is up to 80 characters' end
    local s, why = encode(doc)
    if not s then return false, why end
    local shortId = shortIdFor(key)
    if not shortId then return false, 'no short id is free for that key' end
    local userId, uname = who(by)
    local ok, id = pcall(MySQL.insert.await, [[
        INSERT INTO `systems` (`key`, `shortId`, `name`, `description`, `draftRev`, `createdBy`, `createdByName`, `updatedBy`, `updatedByName`)
        VALUES (?, ?, ?, ?, 1, ?, ?, ?, ?)
    ]], { key, shortId, name, type(doc.description) == 'string' and doc.description:sub(1, 500) or nil, userId, uname, userId, uname })
    if not ok or not id then return false, DB_ERROR end
    local okR = pcall(MySQL.insert.await,
        'INSERT INTO `system_revisions` (`systemId`, `rev`, `doc`, `powers`, `editedBy`, `editedByName`, `note`) VALUES (?, 1, ?, ?, ?, ?, ?)',
        { id, s, SystemStore.powersOf(doc), userId, uname, 'created' })
    if not okR then
        q('DELETE FROM `systems` WHERE `id` = ?', { id })
        return false, DB_ERROR
    end
    local rows = q('SELECT * FROM `systems` WHERE `id` = ?', { id })
    if rows and rows[1] then remember(rows[1]) end
    return systems[key] and view(systems[key]) or false, systems[key] == nil and DB_ERROR or nil
end

--- Save the draft: a new revision on top of `baseRev`. Answers the new revision, or false and why.
function SystemStore.save(key, baseRev, doc, by, note)
    local r = systems[key]
    if not r then return false, 'no such system' end
    baseRev = math.tointeger(tonumber(baseRev) or -1)
    if baseRev ~= r.draftRev then
        return false, ('changed by %s since you opened it (revision %d)'):format(tostring(r.updatedByName or 'someone'), r.draftRev)
    end
    if saving[key] then return false, 'another save of this system is under way' end
    local s, why = encode(doc)
    if not s then return false, why end
    local userId, uname = who(by)
    local rev = baseRev + 1
    saving[key] = true
    local committed, err = Stores.runTransaction({
        { query = 'UPDATE `systems` SET `draftRev` = ?, `name` = ?, `updatedBy` = ?, `updatedByName` = ?, `updatedAt` = NOW() WHERE `id` = ? AND `draftRev` = ?',
          values = { rev, type(doc.name) == 'string' and doc.name:sub(1, 80) or r.name, userId, uname, r.id, baseRev } },
        { query = 'INSERT INTO `system_revisions` (`systemId`, `rev`, `doc`, `powers`, `editedBy`, `editedByName`, `note`) VALUES (?, ?, ?, ?, ?, ?, ?)',
          values = { r.id, rev, s, SystemStore.powersOf(doc), userId, uname, type(note) == 'string' and note:sub(1, 200) or nil } },
    })
    saving[key] = nil
    if not committed then
        say('saving %s revision %d failed: %s', key, rev, tostring(err))
        return false, 'Could not save that: someone else may have saved it, or the database said no'
    end
    r.draftRev, r.updatedBy, r.updatedByName = rev, userId, uname
    if type(doc.name) == 'string' then r.name = doc.name:sub(1, 80) end
    return rev
end

--- A systems.admin approves a revision's powers (§6): it may then be switched on. Kept ON THAT
--- REVISION'S ROW (each revision its own approval); the system's row says which was approved last, for
--- the list.
function SystemStore.approve(key, rev, powers, by)
    local r = systems[key]
    if not r then return false, 'no such system' end
    local _, uname = who(by)
    local res = q('UPDATE `system_revisions` SET `approvedPowers` = ?, `approvedByName` = ? WHERE `systemId` = ? AND `rev` = ?',
        { powers, uname, r.id, rev })
    if not res then return false, DB_ERROR end
    q('UPDATE `systems` SET `approvedRev` = ?, `approvedPowers` = ?, `approvedByName` = ? WHERE `id` = ?', { rev, powers, uname, r.id })
    r.approvedRev, r.approvedPowers, r.approvedByName = rev, powers, uname
    return true
end

--- Its last `limit` revisions, newest first: { rev, by, note, at, powers, approved, approvedBy }. WAITS.
function SystemStore.history(key, limit)
    local r = systems[key]
    if not r then return nil, 'no such system' end
    limit = math.max(1, math.min(50, math.tointeger(tonumber(limit) or 30) or 30))
    local rows, err = q(('SELECT `rev`, `editedByName`, `note`, `powers`, `approvedPowers`, `approvedByName`, UNIX_TIMESTAMP(`createdAt`) AS `at` FROM `system_revisions` WHERE `systemId` = ? ORDER BY `rev` DESC LIMIT %d'):format(limit),
        { r.id })
    if not rows then return nil, err end
    local out = {}
    for i, row in ipairs(rows) do
        out[i] = { rev = row.rev, by = row.editedByName, note = row.note, at = tonumber(row.at), powers = row.powers or '',
                   approved = row.approvedPowers, approvedBy = row.approvedByName }
    end
    return out
end

--- Delete a system (an admin; it must be off): gone from every list, its revisions kept in the table
--- (deletedAt), its key free again. Answers true, or false and why. WAITS.
function SystemStore.delete(key, by)
    local r = systems[key]
    if not r or r.deleting then return false, 'no such system' end
    if saving[key] then return false, 'it is being saved: try again in a moment' end
    local userId, uname = who(by)
    -- Gone from every read BEFORE the wait (a switch-on waiting meanwhile must not find it still there).
    -- Back if the database says no.
    r.deleting = true
    -- The KEY is freed for a new system (the deleted row keeps it behind its id: unique). The SHORT ID
    -- is not: names and tags were made from it, so a new system never inherits them.
    local res = q('UPDATE `systems` SET `deletedAt` = NOW(), `status` = \'off\', `key` = ?, `updatedBy` = ?, `updatedByName` = ? WHERE `id` = ?',
        { ('~%d~%s'):format(r.id, r.key):sub(1, 64), userId, uname, r.id })
    if not res then r.deleting = nil return false, DB_ERROR end
    retiredShort[r.shortId] = true
    systems[key] = nil
    byId[r.id] = nil
    return true
end

--- Its status: 'on' (with the revision that is on), 'off' or 'faulted' (with the reason).
function SystemStore.setStatus(key, status, activeRev, reason, by)
    local r = systems[key]
    if not r then return false, 'no such system' end
    if status ~= 'on' and status ~= 'off' and status ~= 'faulted' then return false, 'unknown status' end
    local _, uname = who(by)
    local res = q('UPDATE `systems` SET `status` = ?, `activeRev` = ?, `reason` = ?, `switchedByName` = ? WHERE `id` = ?',
        { status, activeRev, type(reason) == 'string' and reason:sub(1, 200) or nil, uname, r.id })
    if not res then return false, DB_ERROR end
    r.status, r.activeRev, r.reason, r.switchedByName = status, activeRev, reason, uname
    return true
end

-- ============================================
-- Remembered state (the `sysvar` save unit)
-- ============================================

--- Everything a system remembers, as the walker takes it: { [scopeKey] = { [name] = value } }. WAITS.
function SystemStore.loadState(systemId)
    local rows, err = q('SELECT `scope`, `name`, `value` FROM `system_state` WHERE `systemId` = ?', { systemId })
    if not rows then return nil, err end
    local out = {}
    local function put(scope, name, raw)
        local ok, v = pcall(json.decode, raw)
        if ok and v ~= nil then
            local s = out[scope]
            if not s then s = {}; out[scope] = s end
            s[name] = type(v) == 'table' and v.v or v
        end
    end
    for _, row in ipairs(rows) do put(row.scope, row.name, row.value) end
    -- What is waiting for the next save is newer than the table (switched off and on within a second).
    for _, p in pairs(pendingState) do
        if p.systemId == systemId then
            if p.value == false then
                if out[p.scope] then out[p.scope][p.name] = nil end
            else
                put(p.scope, p.name, p.value)
            end
        end
    end
    return out
end

local function unitKey(systemId, scope, name) return ('%d|%s|%s'):format(systemId, scope, name) end

local unitDefined = false
local function defineUnit()
    if unitDefined then return end
    unitDefined = true
    Stores.defineUnit('sysvar', {
        mode = 'later',
        label = function(key) return ('a remembered value (%s)'):format(tostring(key)) end,
        -- The value waiting stays waiting until its write LANDED (`confirm`), and only if nothing newer
        -- came meanwhile. A load reads it from here in the meantime.
        persist = function(key)
            local p = pendingState[key]
            if not p then return {} end
            local confirm = function() if pendingState[key] == p then pendingState[key] = nil end end
            if p.value == false then
                return { { query = 'DELETE FROM `system_state` WHERE `systemId` = ? AND `scope` = ? AND `name` = ?',
                           values = { p.systemId, p.scope, p.name } } }, confirm
            end
            return { { query = [[INSERT INTO `system_state` (`systemId`, `scope`, `name`, `value`) VALUES (?, ?, ?, ?)
                                 ON DUPLICATE KEY UPDATE `value` = VALUES(`value`)]],
                       values = { p.systemId, p.scope, p.name, p.value } } }, confirm
        end,
    })
end

--- A remembered variable changed (the walker's Ports.remember): written with the next save. nil
--- forgets it. Answers false and why when the value is too big to keep.
function SystemStore.rememberValue(systemId, scope, name, value)
    defineUnit()   -- here, not at the top: stores.lua loads later in the manifest (house rule)
    ---@type string|false
    local enc = false
    if value ~= nil then
        local ok, s = pcall(json.encode, { v = value })
        if not ok then return false, 'that value cannot be written down' end
        if #s > MAX_STATE then return false, ('a remembered value is %d bytes at most'):format(MAX_STATE) end
        enc = s
    end
    local key = unitKey(systemId, scope, name)
    pendingState[key] = { systemId = systemId, scope = scope, name = name, value = enc }
    Stores.markDirty(Stores.unit('sysvar', key))
    return true
end

-- (Per-car variables cannot be remembered yet (compile.lua), so nothing is kept per car to forget.)
