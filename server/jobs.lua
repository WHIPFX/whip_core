-- ============================================
-- JOBS / BUSINESS — Server Module
-- Employment, roles, clock on/off, permissions
-- ============================================

Jobs = {}
Jobs.cache      = {}   -- [jobId] = { jobId, key, name, icon, ownerCharId, settings, createdAt, createdBy }
Jobs.roles      = {}   -- [jobId] = { [roleId] = { roleId, jobId, name, level, permissions } }
Jobs.employees  = {}   -- [jobId] = { [charId] = { jobId, charId, roleId, hiredAt, hiredBy } }
Jobs._clockedOn = {}   -- [charId] = { [jobId] = seq }  (runtime only; a higher seq clocked on later)
Jobs._charJobs  = {}   -- [charId] = { [jobId] = roleId } (reverse index for fast lookups)
Jobs._keyIndex  = {}   -- [key] = jobId  (reverse index for key→jobId lookups)

-- ============================================
-- The reasons, in words
-- ============================================
--
-- Every Jobs answer that says no says why in a sentence a player can read (a SecureEvent handler may
-- pass it straight on). Defined once here, so every export says the same thing for the same no;
-- Jobs.WHY is for code in whip_core that has to recognise one.
local WHY = {
    job         = 'No such job',
    role        = 'No such role at that job',
    key         = 'A job key is letters, digits and _ (starting with a letter or _), up to 50',
    keyTaken    = 'Another job already uses that key',
    player      = 'No player with that server id is online (for a character, pass { charId = n })',
    character   = 'No such character',
    offline     = 'They are not online',
    notEmployed = 'They do not work there',
    employed    = 'They already work there',
    offDuty     = 'They are not on duty',
    actor       = 'You do not work there',
    rank        = 'They (or that role) outrank you',
    permission  = 'Your role is not allowed to do that',
    byNobody    = 'opts.by names nobody (a source, or { charId = n })',
    selfClock   = 'This job puts people on duty itself',
    roleUsed    = 'Move the people in that role to another role first',
    topRole     = 'The job needs a level 100 role: its owner holds it',
    power       = 'That rank can do more than yours: you cannot give more than you have',
    sameAccount = 'That is another character of someone who already works there, so they cannot be hired (one character per player at a job)',
    sameAccountOwner = 'Another character of that player works there, so they cannot own it (one character per player at a job)',
    hasAccount  = 'This job has a business account, which needs an owner — set a new owner instead of clearing it',
    moneyLeft   = 'Empty the job\'s business account first',
}
Jobs.WHY = WHY

-- ============================================
-- Permissions — the built-in ones, and the ones a job declares
-- ============================================
--
-- Every job has these five. A job resource may add its own — EnsureJob's `permissions`, e.g.
-- `{ cuff = 'Cuff suspects' }` — and they become toggles on each role in the Job Manager and answer
-- HasJobPermission like the built-ins.
--
-- bankAccess is a role's LEVEL of access to the business accounts ('none', 'view', 'deposit',
-- 'withdraw', 'manager'), not a yes/no permission.
Jobs.BUILTIN_PERMISSIONS = {
    { key = 'canHire',    label = 'Hire staff' },
    { key = 'canFire',    label = 'Fire staff' },
    { key = 'canPromote', label = 'Promote staff' },
    { key = 'canDemote',  label = 'Demote staff' },
    { key = 'canManage',  label = 'Manage the business (roles, shop stock and prices)' },
}

local BUILTIN_PERM = {}
for _, p in ipairs(Jobs.BUILTIN_PERMISSIONS) do BUILTIN_PERM[p.key] = true end

local BANK_ACCESS = { none = true, view = true, deposit = true, withdraw = true, manager = true }

--- Every permission this job knows, in order: the built-ins, then the ones its resource declared.
---@param jobId number
---@return { key: string, label: string, custom: boolean }[]
function Jobs.permissionList(jobId)
    local list = {}
    for _, p in ipairs(Jobs.BUILTIN_PERMISSIONS) do
        list[#list + 1] = { key = p.key, label = p.label, custom = false }
    end
    local job = Jobs.cache[jobId]
    local declared = job and type(job.settings) == 'table' and job.settings.permissions
    if type(declared) == 'table' then
        local keys = {}
        for k in pairs(declared) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            list[#list + 1] = { key = k, label = tostring(declared[k]), custom = true }
        end
    end
    return list
end

--- A role's permissions cleaned to what this job knows: its permissions (true only) and a
--- bankAccess level. `keepBankAccess` is the level to keep when `perms` names none — so a form that
--- does not show bank access cannot wipe it.
---@param jobId number
---@param perms table|nil
---@param keepBankAccess string|nil
---@return table
function Jobs.cleanPermissions(jobId, perms, keepBankAccess)
    local out = {}
    perms = type(perms) == 'table' and perms or {}
    for _, p in ipairs(Jobs.permissionList(jobId)) do
        if perms[p.key] == true then out[p.key] = true end
    end
    local bank = perms.bankAccess
    if not BANK_ACCESS[bank] then bank = keepBankAccess end
    if BANK_ACCESS[bank] and bank ~= 'none' then out.bankAccess = bank end
    return out
end

--- A job resource's own permissions, checked: `{ cuff = 'Cuff suspects' }` or `{ 'cuff', ... }`.
--- Answers { [name] = label }, or false and why.
---@param decl table|nil
---@return table|false|nil
---@return string|nil err
local function cleanDeclaredPermissions(decl)
    if decl == nil then return nil end
    if type(decl) ~= 'table' then return false, 'permissions must be a table: { name = \'label\' }' end
    local out = {}
    for k, v in pairs(decl) do
        local key, label = k, v
        if type(k) == 'number' then key, label = v, v end
        if type(key) ~= 'string' or #key > 40 or not key:match('^[%a_][%w_]*$') then
            return false, ('permission name "%s": letters, digits and _ only'):format(tostring(key))
        end
        if BUILTIN_PERM[key] or key == 'bankAccess' then
            return false, ('permission "%s" is built in'):format(key)
        end
        out[key] = tostring(label or key):sub(1, 60)
    end
    return out
end

--- Role definitions, checked before anything is written: { { name, level, permissions } }.
--- Answers the list, or false and why.
---@param defs table|nil
---@return table|false|nil
---@return string|nil err
local function checkRoleDefs(defs)
    if defs == nil then return nil end
    if type(defs) ~= 'table' or #defs == 0 then
        return false, 'roles must be a list: { { name = \'Manager\', level = 50, permissions = {...} }, ... }'
    end
    local seen = {}
    for i, def in ipairs(defs) do
        if type(def) ~= 'table' or type(def.name) ~= 'string' or def.name == '' or #def.name > 60 then
            return false, ('roles[%d]: a name of 1 to 60 characters'):format(i)
        end
        if not Sanitize.id(def.level, 1, 100) then
            return false, ('roles[%d] (%s): level must be a whole number from 1 to 100'):format(i, def.name)
        end
        if def.permissions ~= nil and type(def.permissions) ~= 'table' then
            return false, ('roles[%d] (%s): permissions must be a table'):format(i, def.name)
        end
        local lower = def.name:lower()
        if seen[lower] then return false, ('roles[%d]: "%s" is listed twice'):format(i, def.name) end
        seen[lower] = true
    end
    return defs
end

--- Is this a character that exists and is not deleted? Online is proof enough; otherwise the
--- characters table is asked. For anything that names a character by id — a hire, an owner.
---@param charId number
---@return boolean|nil exists  nil when the database could not be asked
---@return string|nil err
local function characterExists(charId)
    if PlayersByCharId and PlayersByCharId[charId] then return true end
    local ok, found = pcall(MySQL.scalar.await,
        'SELECT 1 FROM `characters` WHERE `charId` = ? AND `deleted` IS NULL', { charId })
    if not ok then return nil, DB_ERROR end
    return found ~= nil
end

--- One character per player account at a job (Config.JobOneCharacterPerAccount): does another character
--- of `charId`'s account work at the job, or own it (`owner`, the owner it has or will have)? Answers
--- true or false, or nil and the database's error. Hiring and a new owner both ask.
---@return boolean|nil clash
---@return string|nil err
local function accountSiblingAtJob(jobId, charId, owner)
    local okSib, siblings = pcall(MySQL.query.await,
        'SELECT `charId` FROM `characters` WHERE `userId` = (SELECT `userId` FROM `characters` WHERE `charId` = ?) '
        .. 'AND `charId` <> ? AND `deleted` IS NULL', { charId, charId })
    if not okSib then return nil, DB_ERROR end
    local emps = Jobs.employees[jobId] or {}
    for _, row in ipairs(siblings or {}) do
        local id = tonumber(row.charId)
        if emps[id] or (owner and id == tonumber(owner)) then return true end
    end
    return false
end

-- ============================================
-- Naming a job, a person and a role — one way each
-- ============================================
--
-- Every export takes these three the same way:
--
--   a job      its jobId (number), or its key ('police')
--   a person   a source (a player online), or { charId = n } — any character, online or not
--   a role     its roleId (number), or its name ('Manager', any case)

--- Is this a usable job key? Letters, digits and underscores, starting with a letter or an
--- underscore, at most 50. Doors, shops and code name jobs by it, so it is an identifier.
---@param key any
---@return boolean
local function validKey(key)
    return type(key) == 'string' and #key <= 50 and key:match('^[%a_][%w_]*$') ~= nil
end
Jobs.validKey = validKey

--- A key made from a job's name, free for use: 'Burger Shot' → 'burger_shot', 'burger_shot_2'...
--- For the Job Manager, whose key box may be left blank.
---@param name string
---@return string
function Jobs.keyFromName(name)
    local base = tostring(name or ''):lower():gsub('[^%w]+', '_'):gsub('^_+', ''):gsub('_+$', '')
    if base == '' or base:match('^%d') then base = 'job_' .. base end
    base = base:sub(1, 44)
    local key, n = base, 1
    while Jobs._keyIndex[key] do
        n = n + 1
        key = base .. '_' .. n
    end
    return key
end

--- A job, named either way. nil when it names nothing.
---@param ref number|string  jobId or key
---@return table|nil job
function Jobs.resolve(ref)
    if type(ref) == 'string' then return Jobs.getByKey(ref) end
    if type(ref) == 'number' then return Jobs.cache[ref] end
    return nil
end

-- A person is WhoIs (helpers.lua): a source, or { charId = n }. Whether a charId belongs to a real
-- character is the caller's to ask; Jobs.hire does.

--- One of this job's roles, by roleId or by name (any case). nil when the job has no such role.
---@param jobId number
---@param ref number|string
---@return table|nil role
function Jobs.resolveRole(jobId, ref)
    local roles = Jobs.roles[jobId] or {}
    if type(ref) == 'number' then return roles[ref] end
    if type(ref) == 'string' then
        local want = ref:lower()
        for _, role in pairs(roles) do
            if tostring(role.name):lower() == want then return role end
        end
    end
    return nil
end

--- The job's lowest role — what a hire gets when it names none.
---@param jobId number
---@return table|nil role
function Jobs.lowestRole(jobId)
    local best = nil
    for _, role in pairs(Jobs.roles[jobId] or {}) do
        if not best or (role.level or 0) < (best.level or 0) then best = role end
    end
    return best
end

-- ============================================
-- Database — Table Creation
-- ============================================

---@return boolean ok
function Jobs.ensureTable()
    local ok = CreateTable('jobs', [[
        CREATE TABLE IF NOT EXISTS `jobs` (
            `jobId`       INT UNSIGNED     NOT NULL AUTO_INCREMENT,
            `key`         VARCHAR(50)      DEFAULT NULL,
            `name`        VARCHAR(100)     NOT NULL,
            `icon`        VARCHAR(100)     DEFAULT NULL,
            `ownerCharId` INT UNSIGNED     DEFAULT NULL,
            `settings`    JSON             DEFAULT NULL,
            `createdAt`   TIMESTAMP        NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `createdBy`   INT UNSIGNED     DEFAULT NULL,
            PRIMARY KEY (`jobId`),
            UNIQUE KEY `uk_job_key` (`key`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])

    -- `permissions` has no default: MySQL refuses `DEFAULT '{}'` on a JSON column. Jobs.createRole,
    -- the only insert, always writes it.
    local ok2 = CreateTable('job_roles', [[
        CREATE TABLE IF NOT EXISTS `job_roles` (
            `roleId`      INT UNSIGNED      NOT NULL AUTO_INCREMENT,
            `jobId`       INT UNSIGNED      NOT NULL,
            `name`        VARCHAR(60)       NOT NULL,
            `level`       SMALLINT UNSIGNED NOT NULL DEFAULT 1,
            `permissions` JSON              NOT NULL,
            PRIMARY KEY (`roleId`),
            UNIQUE KEY `uk_job_role_name` (`jobId`, `name`),
            KEY `idx_role_job` (`jobId`),
            CONSTRAINT `fk_role_job` FOREIGN KEY (`jobId`) REFERENCES `jobs` (`jobId`) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])

    local ok3 = CreateTable('job_employees', [[
        CREATE TABLE IF NOT EXISTS `job_employees` (
            `jobId`   INT UNSIGNED NOT NULL,
            `charId`  INT UNSIGNED NOT NULL,
            `roleId`  INT UNSIGNED NOT NULL,
            `hiredAt` TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `hiredBy` INT UNSIGNED DEFAULT NULL,
            PRIMARY KEY (`jobId`, `charId`),
            KEY `idx_employee_char` (`charId`),
            CONSTRAINT `fk_employee_job` FOREIGN KEY (`jobId`) REFERENCES `jobs` (`jobId`) ON DELETE CASCADE,
            CONSTRAINT `fk_employee_char` FOREIGN KEY (`charId`) REFERENCES `characters` (`charId`) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])
    return ok and ok2 and ok3
end

-- ============================================
-- Load All
-- ============================================

function Jobs.loadAll()
    Jobs.ensureTable()

    -- Load jobs
    local ok, rows = pcall(MySQL.query.await, 'SELECT * FROM `jobs`', {})
    if not ok then
        print(('[whip_core:jobs] ERROR loading jobs: %s'):format(tostring(rows)))
        return false   -- start-up halts (player_lifecycle.lua)
    end

    Jobs.cache = {}
    Jobs._keyIndex = {}
    local jobCount = 0
    if rows then
        for _, row in ipairs(rows) do
            local settings = nil
            if row.settings and row.settings ~= '' and row.settings ~= 'null' then
                settings = json.decode(row.settings)
            end

            Jobs.cache[row.jobId] = {
                jobId       = row.jobId,
                key         = row.key,
                name        = row.name,
                icon        = row.icon,
                ownerCharId = row.ownerCharId,
                settings    = settings,
                createdAt   = EpochSeconds(row.createdAt),   -- seconds, like CreateJob's os.time()
                createdBy   = row.createdBy,
            }
            Jobs.roles[row.jobId] = Jobs.roles[row.jobId] or {}
            Jobs.employees[row.jobId] = Jobs.employees[row.jobId] or {}
            jobCount = jobCount + 1

            -- Build key index
            if row.key then
                Jobs._keyIndex[row.key] = row.jobId
            end
        end
    end

    -- Load roles
    local ok2, roleRows = pcall(MySQL.query.await, 'SELECT * FROM `job_roles`', {})
    if not ok2 then
        print(('[whip_core:jobs] ERROR loading job_roles: %s'):format(tostring(roleRows)))
        return false
    end

    local roleCount = 0
    if roleRows then
        for _, row in ipairs(roleRows) do
            if Jobs.cache[row.jobId] then
                local perms = {}
                if row.permissions and row.permissions ~= '' and row.permissions ~= 'null' then
                    perms = json.decode(row.permissions) or {}
                end

                Jobs.roles[row.jobId] = Jobs.roles[row.jobId] or {}
                Jobs.roles[row.jobId][row.roleId] = {
                    roleId      = row.roleId,
                    jobId       = row.jobId,
                    name        = row.name,
                    level       = row.level or 1,
                    permissions = perms,
                }
                roleCount = roleCount + 1
            end
        end
    end

    -- Load employees
    local ok3, empRows = pcall(MySQL.query.await, 'SELECT * FROM `job_employees`', {})
    if not ok3 then
        print(('[whip_core:jobs] ERROR loading job_employees: %s'):format(tostring(empRows)))
        return false
    end

    Jobs._charJobs = {}
    local empCount = 0
    if empRows then
        for _, row in ipairs(empRows) do
            if Jobs.cache[row.jobId] then
                Jobs.employees[row.jobId] = Jobs.employees[row.jobId] or {}
                Jobs.employees[row.jobId][row.charId] = {
                    jobId   = row.jobId,
                    charId  = row.charId,
                    roleId  = row.roleId,
                    hiredAt = EpochSeconds(row.hiredAt),   -- seconds, like a hire this session
                    hiredBy = row.hiredBy,
                }

                -- Build reverse index
                Jobs._charJobs[row.charId] = Jobs._charJobs[row.charId] or {}
                Jobs._charJobs[row.charId][row.jobId] = row.roleId
                empCount = empCount + 1
            end
        end
    end

    -- Reset clock state (runtime only)
    Jobs._clockedOn = {}

end

-- ============================================
-- Job CRUD
-- ============================================

function Jobs.get(jobId)
    return Jobs.cache[jobId]
end

function Jobs.getAll()
    local result = {}
    for _, def in pairs(Jobs.cache) do
        result[#result + 1] = def
    end
    table.sort(result, function(a, b) return a.jobId < b.jobId end)
    return result
end

function Jobs.getByKey(key)
    if not key then return nil end
    local jobId = Jobs._keyIndex[key]
    if not jobId then return nil end
    return Jobs.cache[jobId]
end

--- Make each role in `defs` that this job does not have yet (matched by name, any case). A role the
--- job already has is left exactly as it is: a server owner may have edited it in the Job Manager.
---@param jobId number
---@param defs table  checked by checkRoleDefs
---@return boolean ok
---@return string|nil err
local function ensureRoles(jobId, defs)
    for _, def in ipairs(defs) do
        if not Jobs.resolveRole(jobId, def.name) then
            local role, err = Jobs.createRole(jobId, {
                name        = def.name,
                level       = Sanitize.id(def.level, 1, 100),
                permissions = Jobs.cleanPermissions(jobId, def.permissions),
            })
            if not role then return false, err end
        end
    end
    return true
end

--- Does this job let its players clock themselves on from the client (its ClockOn)? Yes unless its
--- resource said `selfClockOn = false` — then only its own server code puts people on duty.
---@param jobId number
---@return boolean
function Jobs.allowsSelfClockOn(jobId)
    local job = Jobs.cache[jobId]
    return not (job and type(job.settings) == 'table' and job.settings.selfClockOn == false)
end

--- Idempotent find-or-create. Resources call this on start. Answers the job, or `false, reason`.
---
--- data: { name, icon, ownerCharId, settings, roles, permissions, selfClockOn }
---   roles         the job's ranks, { { name, level, permissions } } — instead of Config.JobDefaultRoles
---   permissions   the job's OWN permissions, { name = 'label' }, beside the built-in five
---   selfClockOn   false: players cannot clock themselves on from the client; your code does it
---
--- On a job that already exists, the code's own declarations follow the code: name, icon,
--- permissions and selfClockOn are updated when they differ, and roles it lists that the job lacks
--- are added. Nothing else changes — never the owner (UpdateJob does that), never a role that
--- exists (a server owner may have edited it), never other settings.
---
--- One resource per key, as EnsureContainer and EnsureZone: the declaring resource is kept in its
--- settings (`declaredBy`), and another running resource declaring the same key is refused. A job
--- made in the Job Manager, or whose resource is gone, is taken by the next resource to declare it.
---@param key string — stable code identifier (e.g. 'pdm', 'burgershot')
---@param data table
---@param caller string|nil  the declaring resource
---@return table|false job
---@return string|nil err
function Jobs.ensureJob(key, data, caller)
    if not validKey(key) then return false, WHY.key end

    data = data or {}

    local declared, declErr = cleanDeclaredPermissions(data.permissions)
    if declared == false then return false, declErr end
    local roleDefs, rolesErr = checkRoleDefs(data.roles)
    if roleDefs == false then return false, rolesErr end
    if data.settings ~= nil and type(data.settings) ~= 'table' then return false, 'settings must be a table' end

    caller = caller or GetCurrentResourceName()

    -- Check if already exists
    local existing = Jobs.getByKey(key)
    if existing then
        local by = type(existing.settings) == 'table' and existing.settings.declaredBy or nil
        if by and by ~= caller and Registry.alive(by) then
            return false, ('job "%s" is declared by %s'):format(key, by)
        end

        local updateData = {}
        if data.name and data.name ~= existing.name then updateData.name = data.name end
        if data.icon ~= nil and data.icon ~= existing.icon then updateData.icon = data.icon end

        -- The code's declarations, compared as values: a change of label or a new permission is a
        -- change, and an unchanged restart writes nothing.
        local settings, settingsChanged = {}, false
        for k, v in pairs(type(existing.settings) == 'table' and existing.settings or {}) do settings[k] = v end
        if declared and not Registry.deepEquals(settings.permissions, declared) then
            settings.permissions, settingsChanged = declared, true
        end
        if data.selfClockOn ~= nil then
            -- `false` is stored; `true` is the default and stored as nothing. Written out: the
            -- one-liner `x == false and false or nil` is ALWAYS nil.
            local want = nil
            if data.selfClockOn == false then want = false end
            if settings.selfClockOn ~= want then settings.selfClockOn, settingsChanged = want, true end
        end
        if settings.declaredBy ~= caller then settings.declaredBy, settingsChanged = caller, true end
        if settingsChanged then updateData.settings = settings end

        if next(updateData) then
            local ok, err = Jobs.update(existing.jobId, updateData)
            if not ok then return false, err end
        end

        if roleDefs then
            local ok, err = ensureRoles(existing.jobId, roleDefs)
            if not ok then return false, err end
        end

        -- (An owned job gets its business account from Jobs.create / Jobs.update, not here.)

        return Jobs.cache[existing.jobId]
    end

    -- Create new
    local settings = {}
    for k, v in pairs(data.settings or {}) do settings[k] = v end
    if declared then settings.permissions = declared end
    if data.selfClockOn == false then settings.selfClockOn = false end
    settings.declaredBy = caller

    return Jobs.create({
        key         = key,
        name        = data.name or key,
        icon        = data.icon,
        ownerCharId = data.ownerCharId,
        settings    = next(settings) and settings or nil,
        roles       = roleDefs,
    })
end

--- Make a job, with its roles and, when it has an owner, its business account. Answers the job, or
--- `false, reason`: WHY.key | WHY.keyTaken | WHY.character | DB_ERROR.
---
--- A key is required: doors, shops and EnsureJob name a job by it (the Job Manager makes one from the
--- name when its box is blank).
function Jobs.create(data)
    local key = data.key
    if not validKey(key) then return false, WHY.key end
    if Jobs._keyIndex[key] then return false, WHY.keyTaken end

    if data.ownerCharId then
        local exists, existsErr = characterExists(data.ownerCharId)
        if exists == nil then return false, existsErr end
        if not exists then return false, WHY.character end
    end

    local settingsJson = data.settings and json.encode(data.settings) or nil

    local ok, insertId = pcall(MySQL.insert.await,
        'INSERT INTO `jobs` (`key`, `name`, `icon`, `ownerCharId`, `settings`, `createdBy`) VALUES (?, ?, ?, ?, ?, ?)',
        {
            key,
            data.name or 'New Job',
            data.icon,
            data.ownerCharId,
            settingsJson,
            data.createdBy,
        }
    )

    if not ok then
        print(('[whip_core:jobs] ERROR creating job: %s'):format(tostring(insertId)))
        return false, DB_ERROR
    end

    local def = {
        jobId       = insertId,
        key         = key,
        name        = data.name or 'New Job',
        icon        = data.icon,
        ownerCharId = data.ownerCharId,
        settings    = data.settings,
        createdAt   = os.time(),
        createdBy   = data.createdBy,
    }

    Jobs.cache[insertId] = def
    Jobs.roles[insertId] = {}
    Jobs.employees[insertId] = {}
    Jobs._keyIndex[key] = insertId

    -- Its roles: the ones the caller declared (EnsureJob `roles`), or the config's defaults. After the
    -- cache entry, so each role's permissions are cleaned against this job's declared ones.
    -- Each one checked: the job stands, and the console says which role did not save.
    local roleDefs = data.roles or Config.JobDefaultRoles or {}
    for _, roleDef in ipairs(roleDefs) do
        local role, roleErr = Jobs.createRole(insertId, {
            name        = roleDef.name,
            level       = Sanitize.id(roleDef.level, 1, 100) or 1,
            permissions = Jobs.cleanPermissions(insertId, roleDef.permissions),
        })
        if not role then
            print(('[whip_core:jobs] job #%d was created, but its role "%s" could not be: %s')
                :format(insertId, tostring(roleDef.name), tostring(roleErr)))
        end
    end

    -- Auto-create business bank account if owner exists, checked: the job stands, and the note says
    -- the account did not follow, as Jobs.update's does ('account_not_created').
    local note = nil
    if data.ownerCharId then
        local bankLabel = (def.name or 'Business') .. ' Account'
        if not Bank.CreateAccount(data.ownerCharId, bankLabel, 'business', false, insertId) then
            print(('[whip_core:jobs] job #%d was created, but its business account could not be'):format(insertId))
            note = 'account_not_created'
        end
    end

    -- The owner holds the top role from the start (Jobs.getPlayerRole), so their list shows it.
    Jobs.touch(data.ownerCharId)
    Jobs.emitJobEvent('whip_core:job:created', insertId, nil, { name = def.name })
    return def, note
end

--- Hand a job's business accounts to its new owner. Answers nil when all went through, or a note.
---
--- The account follows the job, and the old owner's access follows their job: SetAccountOwner steps
--- them down to 'manager' (still withdraw access), so still employed, their role decides; not
--- employed, they lose it. No account yet, the new owner gets one.
---@param jobId number
---@param oldOwner number|nil
---@param newOwner number
---@return string|nil note  'account_not_created' | 'account_not_moved'
local function moveBusinessAccounts(jobId, oldOwner, newOwner)
    local job = Jobs.cache[jobId]
    local accounts, accErr = Bank.GetAccountsByJob(jobId)
    -- Not read is not "none": a second business account would be made beside the first.
    if accErr then return 'account_not_moved' end

    if #accounts == 0 then
        local acc = Bank.CreateAccount(newOwner, ((job and job.name) or 'Business') .. ' Account', 'business', false, jobId)
        if acc then return nil end
        print(('[whip_core:jobs] job #%d changed owner, but its business account could not be created')
            :format(jobId))
        return 'account_not_created'
    end

    local failed = false
    for _, acc in ipairs(accounts) do
        if not Bank.SetAccountOwner(acc.accountId, newOwner) then failed = true end
    end

    if oldOwner then
        if Jobs.employees[jobId] and Jobs.employees[jobId][oldOwner] then
            -- Checked: a failed sync would leave the old owner holding the owner's access.
            if not Jobs.syncEmployeeBankAccess(jobId, oldOwner) then failed = true end
        else
            for _, acc in ipairs(accounts) do
                local revoked, why = Bank.ForceRevokeAccess(acc.accountId, oldOwner)
                if not revoked and why == DB_ERROR then failed = true end
            end
        end
    end

    if failed then
        print(('[whip_core:jobs] job #%d changed owner, but a business account\'s owner or access could not be changed')
            :format(jobId))
        return 'account_not_moved'
    end
    return nil
end

--- Change a job's name, icon, settings or owner. Answers `true` (plus a note when the job changed but
--- its business account could not follow — 'account_not_moved'), or `false, reason`.
---
--- `ownerCharId = false` clears the owner (nil means "not mentioned").
---
--- The owner rules live here: a new owner must be a real character, the business account moves with
--- the job (moveBusinessAccounts), and an owner cannot be CLEARED while the job has a business
--- account (the account would keep its owner, and the money).
function Jobs.update(jobId, data)
    local def = Jobs.cache[jobId]
    if not def then return false, WHY.job end

    -- Row first, memory second, as Shops.update does.
    local name        = data.name ~= nil and data.name or def.name
    local icon        = data.icon ~= nil and data.icon or def.icon
    local settings    = data.settings ~= nil and data.settings or def.settings
    local ownerCharId = def.ownerCharId
    if data.ownerCharId == false then
        ownerCharId = nil
    elseif data.ownerCharId ~= nil then
        ownerCharId = data.ownerCharId
    end

    if ownerCharId ~= def.ownerCharId then
        if ownerCharId == nil then
            local accounts, accErr = Bank.GetAccountsByJob(jobId)
            if accErr then return false, accErr end
            if #accounts > 0 then return false, WHY.hasAccount end
        end
        if ownerCharId ~= nil then
            local exists, existsErr = characterExists(ownerCharId)
            if exists == nil then return false, existsErr end
            if not exists then return false, WHY.character end
            -- The one-character rule holds for an owner too
            if Config.JobOneCharacterPerAccount ~= false then
                local clash, clashErr = accountSiblingAtJob(jobId, ownerCharId, nil)
                if clash == nil then return false, clashErr end
                if clash then return false, WHY.sameAccountOwner end
            end
        end
    end

    local settingsJson = settings and json.encode(settings) or nil

    local ok, err = pcall(MySQL.query.await,
        'UPDATE `jobs` SET `name`=?, `icon`=?, `ownerCharId`=?, `settings`=? WHERE `jobId`=?',
        { name, icon, ownerCharId, settingsJson, jobId }
    )

    if not ok then
        print(('[whip_core:jobs] ERROR updating job #%d: %s'):format(jobId, tostring(err)))
        return false, DB_ERROR
    end

    local oldOwner = def.ownerCharId
    def.name, def.icon, def.ownerCharId, def.settings = name, icon, ownerCharId, settings

    -- A new owner takes the top role and the old one loses it, at once (see Jobs.getPlayerRole).
    -- An old owner who was on duty only BY owning the place is taken off duty, the business account
    -- follows the job, and both players' job lists are resent so their screens agree.
    local note = nil
    if oldOwner ~= ownerCharId then
        if oldOwner and not (Jobs.employees[jobId] or {})[oldOwner] and Jobs.isClockedOn(oldOwner, jobId) then
            local p = PlayersByCharId and PlayersByCharId[oldOwner]
            Jobs.clockOff(oldOwner, jobId, p and p.source or nil)
        end
        if ownerCharId then note = moveBusinessAccounts(jobId, oldOwner, ownerCharId) end
    elseif ownerCharId then
        -- The account catches up: one still naming someone else (an earlier move that failed)
        -- follows the owner now.
        local accounts, accErr = Bank.GetAccountsByJob(jobId)
        if accErr then
            note = 'account_not_moved'
        else
            for _, acc in ipairs(accounts) do
                local holder = tonumber(acc.ownerCharId)
                if holder ~= ownerCharId then
                    note = moveBusinessAccounts(jobId, holder, ownerCharId)
                    break
                end
            end
        end
    end

    -- Everyone who sees this job in their list (the name or icon may have changed), and the old
    -- owner, who no longer does.
    Jobs.touchJob(jobId)
    Jobs.touch(oldOwner)
    Jobs.emitJobEvent('whip_core:job:updated', jobId, nil, {
        name = name, icon = icon, ownerCharId = ownerCharId, oldOwnerCharId = oldOwner,
    })
    return true, note
end

--- Send a character their job list, if they are online.
---@param charId number|nil
function Jobs.syncCharJobs(charId)
    local p = charId and PlayersByCharId and PlayersByCharId[charId]
    if p then TriggerClientEvent('whip_core:client:jobsSync', p.source, Jobs.getCharJobs(charId)) end
end

-- ============================================
-- Keeping screens current — from here, not from the callers
-- ============================================
--
-- A player's job list and the Job Manager are told by Jobs.* itself, so a change through any export
-- (HirePlayer from any satellite) reaches their screens. Batched to one send per tick, after the
-- whole change (a job delete fires everyone; a role edit touches everyone holding it).
local _syncQueue   = {}      -- [charId] = true, waiting for this tick's flush
local _panelQueued = false
local _flushArmed  = false

local function flushJobSyncs()
    _flushArmed = false
    local queue = _syncQueue
    _syncQueue = {}
    for charId in pairs(queue) do Jobs.syncCharJobs(charId) end
    if _panelQueued then
        _panelQueued = false
        -- The Job Manager's broadcast to whoever has it open (devtools.lua registers it).
        DevTools.refresh('jm')
    end
end

local function armFlush()
    if _flushArmed then return end
    _flushArmed = true
    SetTimeout(0, flushJobSyncs)
end

--- Something about these characters' jobs changed: resend their lists (the online ones) and refresh
--- an open Job Manager, once, at the end of this tick.
---@param ... number|nil  charIds; nil entries are skipped
function Jobs.touch(...)
    for i = 1, select('#', ...) do
        local charId = select(i, ...)
        if charId then _syncQueue[charId] = true end
    end
    _panelQueued = true
    armFlush()
end

-- ============================================
-- Events — whip_core:job:*
-- ============================================
--
-- Each carries { jobId, key } and, for a person, { charId, source } — source only while online:
--
--   whip_core:job:created      { jobId, key, name }
--   whip_core:job:updated      { jobId, key, name, icon, ownerCharId, oldOwnerCharId }
--   whip_core:job:deleted      { jobId, key }
--   whip_core:job:hired        { ..., charId, source, roleId, role, by }
--   whip_core:job:fired        { ..., charId, source }
--   whip_core:job:roleChanged  { ..., charId, source, roleId, role, oldRoleId }
--   whip_core:job:clockedOn    { ..., charId, source }
--   whip_core:job:clockedOff   { ..., charId, source }
--
-- The client fires its own clockedOn / clockedOff for the local player (client/jobs.lua).

local lifeHooks = {}   -- [kind] = { fn, ... }

--- whip_core's own reaction to a job moment, before the public event (house rule: core never listens
--- to its own events): 'clockedOn', 'clockedOff', 'hired', 'fired', 'roleChanged', 'created',
--- 'updated', 'deleted'. fn(payload) runs at once and must not wait. A job audience (server/audience.lua)
--- follows clock-ons through this (blips.lua, runtime_points.lua).
---@param kind string
---@param fn function
function Jobs.onLife(kind, fn)
    lifeHooks[kind] = lifeHooks[kind] or {}
    table.insert(lifeHooks[kind], fn)
end

--- Announce a job event. `extra` is merged over { jobId, key, charId, source }.
---@param name string
---@param jobId number
---@param charId number|nil
---@param extra table|nil
local function emitJobEvent(name, jobId, charId, extra)
    local job = Jobs.cache[jobId]
    local p = charId and PlayersByCharId and PlayersByCharId[charId]
    local payload = {
        jobId  = jobId,
        key    = job and job.key or nil,
        charId = charId,
        source = p and p.source or nil,
    }
    for k, v in pairs(extra or {}) do payload[k] = v end
    for _, fn in ipairs(lifeHooks[name:match('^whip_core:job:(.+)$') or ''] or {}) do
        local ok, err = pcall(fn, payload)
        if not ok then print(('^1[whip_core:jobs] a %s hook failed: %s^0'):format(name, tostring(err))) end
    end
    WhipEmit(name, payload)
end
Jobs.emitJobEvent = emitJobEvent

--- Everyone whose job list shows this job: its employees and its owner.
---@param jobId number
function Jobs.touchJob(jobId)
    for charId in pairs(Jobs.employees[jobId] or {}) do _syncQueue[charId] = true end
    local job = Jobs.cache[jobId]
    if job and job.ownerCharId then _syncQueue[job.ownerCharId] = true end
    _panelQueued = true
    armFlush()
end

--- Delete a job, its roles and its staff list. Answers `true`, or `false, reason`.
---
--- Its business accounts close with it, and a job whose account still holds money is not deleted
--- (WHY.moneyLeft), the rule closing any bank account follows.
function Jobs.delete(jobId)
    if not Jobs.cache[jobId] then return false, WHY.job end

    -- Every employee's bank access dies with the job, collected BEFORE the deletes (afterwards
    -- nothing remembers who worked here).
    local accounts, accErr = Bank.GetAccountsByJob(jobId)
    if accErr then return false, accErr end
    for _, acc in ipairs(accounts) do
        if (tonumber(acc.balance) or 0) > 0 then return false, WHY.moneyLeft end
    end

    -- The (empty) business accounts close FIRST, before any staff is touched: a sale landing after the
    -- balance read makes the close refuse, and the delete stops before anything changed. A closed
    -- account is out of use, so a retry after a failed revoke below has nothing to redo here.
    for _, acc in ipairs(accounts) do
        local closed, why = Bank.CloseAccount(acc.accountId)
        if not closed then
            print(('[whip_core:jobs] could not close business account %s — job #%d not deleted (%s)')
                :format(tostring(acc.accountId), jobId, tostring(why)))
            if why == 'Account must have zero balance' then return false, WHY.moneyLeft end
            return false, why or DB_ERROR
        end
    end

    -- Clock off all employees of this job. A revoke that fails on the database stops the delete
    -- here, while the job still exists to retry it from (see Jobs.fire).
    local emps = Jobs.employees[jobId] or {}
    for charId in pairs(emps) do
        local onlinePlayer = PlayersByCharId and PlayersByCharId[charId] or nil
        Jobs.clockOff(charId, jobId, onlinePlayer and onlinePlayer.source or nil)
        for _, acc in ipairs(accounts) do
            local revoked, why = Bank.ForceRevokeAccess(acc.accountId, charId)
            if not revoked and why == DB_ERROR then
                print(('[whip_core:jobs] ERROR revoking bank access for charId %d — job #%d not deleted')
                    :format(charId, jobId))
                return false, DB_ERROR
            end
        end
    end

    -- Delete from DB, checked, before the cache is touched, in one transaction: all three land, or none.
    local deleted, delErr = Stores.runTransaction({
        { query = 'DELETE FROM `job_employees` WHERE `jobId` = ?', values = { jobId } },
        { query = 'DELETE FROM `job_roles` WHERE `jobId` = ?',     values = { jobId } },
        { query = 'DELETE FROM `jobs` WHERE `jobId` = ?',          values = { jobId } },
    })
    if not deleted then
        print(('[whip_core:jobs] ERROR deleting job #%d: %s'):format(jobId, tostring(delErr)))
        return false, DB_ERROR
    end

    -- DB is clean; now forget it in memory.
    for charId in pairs(emps) do
        if Jobs._charJobs[charId] then
            Jobs._charJobs[charId][jobId] = nil
            if not next(Jobs._charJobs[charId]) then
                Jobs._charJobs[charId] = nil
            end
        end
    end

    -- Clear key index
    local def = Jobs.cache[jobId]
    if def and def.key then
        Jobs._keyIndex[def.key] = nil
    end

    -- The owner goes off duty and loses it from their list too — they held its top role without
    -- being on the payroll, so the employee loop above never saw them.
    local owner = def and def.ownerCharId
    if owner and not emps[owner] and Jobs.isClockedOn(owner, jobId) then
        local p = PlayersByCharId and PlayersByCharId[owner]
        Jobs.clockOff(owner, jobId, p and p.source or nil)
    end

    -- Clear cache
    Jobs.cache[jobId] = nil
    Jobs.roles[jobId] = nil
    Jobs.employees[jobId] = nil

    -- Everyone who had it in their list: the whole staff, and the owner.
    for charId in pairs(emps) do Jobs.touch(charId) end
    Jobs.touch(owner)

    -- The key travels in the payload: the job is already gone from the cache.
    Jobs.emitJobEvent('whip_core:job:deleted', jobId, nil, { key = def and def.key or nil })
    return true
end

-- ============================================
-- Role CRUD
-- ============================================

function Jobs.createRole(jobId, data)
    if not Jobs.cache[jobId] then return nil, WHY.job end

    local permsJson = data.permissions and json.encode(data.permissions) or '{}'

    local ok, insertId = pcall(MySQL.insert.await,
        'INSERT INTO `job_roles` (`jobId`, `name`, `level`, `permissions`) VALUES (?, ?, ?, ?)',
        { jobId, data.name or 'New Role', data.level or 1, permsJson }
    )

    if not ok then
        print(('[whip_core:jobs] ERROR creating role for job #%d: %s'):format(jobId, tostring(insertId)))
        return nil, DB_ERROR
    end

    local role = {
        roleId      = insertId,
        jobId       = jobId,
        name        = data.name or 'New Role',
        level       = data.level or 1,
        permissions = data.permissions or {},
    }

    Jobs.roles[jobId] = Jobs.roles[jobId] or {}
    Jobs.roles[jobId][insertId] = role

    Jobs.touch()   -- the Job Manager
    return role
end

--- The business-account access a role gives: its `bankAccess`, 'manager' at owner level (100+), else
--- 'none'. `role` may be one about to be written (a level and permissions not yet saved).
--- (Declared above updateRole and setRoleNow, which use it: a local below its first use reads as a
--- nil global there.)
---@param role table|nil
---@return string
local function roleBankAccess(role)
    if not role then return 'none' end
    if (role.level or 0) >= 100 then return 'manager' end
    return role.permissions and role.permissions.bankAccess or 'none'
end

--- Does moving from role `from` to role `to` LOWER business-account access?
---@return boolean
local function lowersBankAccess(from, to)
    return Bank.accessRank(roleBankAccess(to)) < Bank.accessRank(roleBankAccess(from))
end

function Jobs.updateRole(roleId, data)
    -- Find the role in cache
    local role, foundJobId
    for jId, roles in pairs(Jobs.roles) do
        if roles[roleId] then
            role = roles[roleId]
            foundJobId = jId
            break
        end
    end

    if not role then return false, WHY.role end

    -- Row first, memory second.
    local newName  = data.name ~= nil and data.name or role.name
    local newLevel = data.level ~= nil and data.level or role.level
    local newPerms = data.permissions ~= nil and data.permissions or role.permissions

    local permsJson = newPerms and json.encode(newPerms) or '{}'

    -- Access never runs ahead of the role: lowering the role's bank access, its holders are lowered
    -- FIRST (if that fails the role is not changed, and a retry finishes it). Raising, the role goes
    -- first.
    local lowering = lowersBankAccess(role, { level = newLevel, permissions = newPerms })
    if lowering then
        local aok, aerr = Jobs.syncRoleBankAccess(foundJobId, roleId, { level = newLevel, permissions = newPerms })
        if not aok then return false, aerr end
    end

    local ok, err = pcall(MySQL.query.await,
        'UPDATE `job_roles` SET `name`=?, `level`=?, `permissions`=? WHERE `roleId`=?',
        { newName, newLevel, permsJson, roleId }
    )

    if not ok then
        print(('[whip_core:jobs] ERROR updating role #%d: %s'):format(roleId, tostring(err)))
        -- The role stays as it was; its holders go back to what it gives, if they can.
        if lowering then Jobs.syncRoleBankAccess(foundJobId, roleId) end
        return false, DB_ERROR
    end

    role.name        = newName
    role.level       = newLevel
    role.permissions = newPerms

    -- And its holders' bank access follows, here, as hire and setRole do. Raised (or unchanged) now,
    -- after the role: a failure leaves less access than it gives, and is said.
    if not lowering and not Jobs.syncRoleBankAccess(foundJobId, roleId) then
        print(('[whip_core:jobs] role #%d changed, but its holders\' bank access could not all be raised yet')
            :format(roleId))
    end

    -- Its holders' lists show the role's name and level.
    Jobs.touchJob(foundJobId)
    return true
end

function Jobs.deleteRole(roleId)
    -- Find the role
    local role, foundJobId
    for jId, roles in pairs(Jobs.roles) do
        if roles[roleId] then
            role = roles[roleId]
            foundJobId = jId
            break
        end
    end

    if not role then return false, WHY.role end

    -- Check if any employees hold this role
    local emps = Jobs.employees[foundJobId] or {}
    for _, emp in pairs(emps) do
        if emp.roleId == roleId then
            return false, WHY.roleUsed
        end
    end

    -- Checked, before memory forgets it.
    local ok, err = pcall(MySQL.query.await, 'DELETE FROM `job_roles` WHERE `roleId` = ?', { roleId })
    if not ok then
        print(('[whip_core:jobs] ERROR deleting role #%d: %s'):format(roleId, tostring(err)))
        return false, DB_ERROR
    end
    Jobs.roles[foundJobId][roleId] = nil

    -- The owner's top role may have been this one.
    Jobs.touchJob(foundJobId)
    return true
end

function Jobs.getRoles(jobId)
    local roles = Jobs.roles[jobId] or {}
    local result = {}
    for _, role in pairs(roles) do
        result[#result + 1] = role
    end
    table.sort(result, function(a, b) return a.level > b.level end)
    return result
end

function Jobs.getRole(roleId)
    for _, roles in pairs(Jobs.roles) do
        if roles[roleId] then
            return roles[roleId]
        end
    end
    return nil
end

-- ============================================
-- Employee Management
-- ============================================

-- ============================================
-- Actor rank rule
-- ============================================

--- May this actor act on something at `targetLevel` within this job?
---
--- nil actorCharId means a TRUSTED caller — a satellite's own decision, or the ACE-gated admin tools —
--- and is not checked: whip trusts the resources a server owner chose to run. A charId means a PLAYER
--- pressed something (a boss menu passing `opts.by` to the exports), and players are checked: you may
--- only act strictly below your own level. Level 100 acts on anything, including other level-100
--- roles: somebody has to.
---@param jobId number
---@param actorCharId number|nil
---@param targetLevel number
---@return boolean ok
---@return string|nil err
local function actorMayAct(jobId, actorCharId, targetLevel)
    if actorCharId == nil then return true end
    local role = Jobs.getPlayerRole(actorCharId, jobId)
    -- WHY.actor, distinct from the WHY.notEmployed the callers use for the TARGET.
    if not role then return false, WHY.actor end
    if role.level >= 100 then return true end
    if targetLevel >= role.level then return false, WHY.rank end
    return true
end

--- And does the actor's role hold the permission for this act (canHire, canFire, canPromote,
--- canDemote)? The same nil-means-trusted rule as actorMayAct; the exports pass their `opts.by` here.
---@param jobId number
---@param actorCharId number|nil
---@param permission string
---@return boolean ok
---@return string|nil err
local function actorHas(jobId, actorCharId, permission)
    if actorCharId == nil then return true end
    if Jobs.hasPermission(actorCharId, jobId, permission) then return true end
    return false, WHY.permission
end

--- And does the actor hold everything this hands out? Nobody grants more power than they hold (the rank
--- rule alone keeps only the LEVEL down). `perms` are a rank's permissions (or what a change makes
--- them); `before` what the person or rank already had, which is not being given. A permission the job
--- no longer knows gives nothing. The same nil-means-trusted rule; level 100 holds all.
---@param jobId number
---@param actorCharId number|nil
---@param perms table|nil
---@param before table|nil
---@return boolean ok
---@return string|nil err
local function actorCovers(jobId, actorCharId, perms, before)
    if actorCharId == nil then return true end
    local role = Jobs.getPlayerRole(actorCharId, jobId)
    if not role then return false, WHY.actor end
    if role.level >= 100 then return true end
    perms, before = perms or {}, before or {}
    for _, p in ipairs(Jobs.permissionList(jobId)) do
        if perms[p.key] == true and before[p.key] ~= true and not Jobs.hasPermission(actorCharId, jobId, p.key) then
            return false, WHY.power
        end
    end
    local give = Bank.accessRank(perms.bankAccess)
    if give > Bank.accessRank(before.bankAccess) and give > Bank.accessRank(roleBankAccess(role)) then
        return false, WHY.power
    end
    return true
end

--- May `actorCharId` hire `charId` at this rank? Every rule Jobs.hire applies, nothing written: the phone asks it
--- before it sends a job offer (whip_phone: a hire is an offer the other player accepts), and
--- Jobs.hire asks it again before the write.
---@return boolean ok
---@return string|nil why
function Jobs.checkHire(jobId, charId, roleId, actorCharId)
    if not Jobs.cache[jobId] then return false, WHY.job end

    -- Verify role exists for this job
    local roles = Jobs.roles[jobId] or {}
    if not roles[roleId] then return false, WHY.role end

    local mayAct, rankErr = actorMayAct(jobId, actorCharId, roles[roleId].level)
    if not mayAct then return false, rankErr end
    local allowed, permErr = actorHas(jobId, actorCharId, 'canHire')
    if not allowed then return false, permErr end
    local covers, powerErr = actorCovers(jobId, actorCharId, roles[roleId].permissions)
    if not covers then return false, powerErr end

    -- Check if already employed at this job
    local emps = Jobs.employees[jobId] or {}
    if emps[charId] then return false, WHY.employed end

    -- A character that exists (not a typo, not a deleted one).
    local exists, existsErr = characterExists(charId)
    if exists == nil then return false, existsErr end
    if not exists then return false, WHY.character end

    -- One character per player account at a job (a setting, on by default), so an alt can't keep a
    -- fired manager's access. Any trusted path too: the rule is the job's, not the caller's.
    if Config.JobOneCharacterPerAccount ~= false then
        -- The owner is the job's, not always an employee row
        local clash, clashErr = accountSiblingAtJob(jobId, charId, Jobs.cache[jobId].ownerCharId)
        if clash == nil then return false, clashErr end
        if clash then return false, WHY.sameAccount end
    end
    return true
end

function Jobs.hire(jobId, charId, roleId, hiredBy, actorCharId)
    local may, why = Jobs.checkHire(jobId, charId, roleId, actorCharId)
    if not may then return false, why end
    local roles = Jobs.roles[jobId] or {}

    local ok, err = pcall(MySQL.query.await,
        'INSERT INTO `job_employees` (`jobId`, `charId`, `roleId`, `hiredBy`) VALUES (?, ?, ?, ?)',
        { jobId, charId, roleId, hiredBy }
    )

    if not ok then
        print(('[whip_core:jobs] ERROR hiring charId %d at job #%d: %s'):format(charId, jobId, tostring(err)))
        return false, DB_ERROR
    end

    local emp = {
        jobId   = jobId,
        charId  = charId,
        roleId  = roleId,
        hiredAt = os.time(),
        hiredBy = hiredBy,
    }

    Jobs.employees[jobId] = Jobs.employees[jobId] or {}
    Jobs.employees[jobId][charId] = emp

    -- Update reverse index
    Jobs._charJobs[charId] = Jobs._charJobs[charId] or {}
    Jobs._charJobs[charId][jobId] = roleId

    -- Bank access follows the role, here, so every caller (any export) inherits it.
    Jobs.syncEmployeeBankAccess(jobId, charId)

    Jobs.touch(charId)
    Jobs.emitJobEvent('whip_core:job:hired', jobId, charId, {
        roleId = roleId, role = roles[roleId].name, by = hiredBy,
    })
    return true
end

--- One change to one person at a time: fire yields between revoking access and deleting the row, and
--- a setRole in that window would re-grant the access. fire and setRole take a per-person claim; the
--- second is refused while the first is still saving.
local _personBusy = {}

---@param fn fun(jobId: number, charId: number, ...): boolean, string|nil
local function onePersonAtATime(jobId, charId, fn, ...)
    local key = tostring(jobId) .. ':' .. tostring(charId)
    if _personBusy[key] then return false, 'Another change to that person is still being saved' end
    _personBusy[key] = true
    local okCall, ok, err = pcall(fn, jobId, charId, ...)
    _personBusy[key] = nil
    if not okCall then
        print(('[whip_core:jobs] ERROR changing charId %s at job #%s: %s')
            :format(tostring(charId), tostring(jobId), tostring(ok)))
        return false, DB_ERROR
    end
    return ok, err
end

local function fireNow(jobId, charId, actorCharId)
    if not Jobs.cache[jobId] then return false, WHY.job end

    local emps = Jobs.employees[jobId] or {}
    local emp = emps[charId]
    if not emp then return false, WHY.notEmployed end

    local targetRole = (Jobs.roles[jobId] or {})[emp.roleId]
    local mayAct, rankErr = actorMayAct(jobId, actorCharId, targetRole and targetRole.level or 0)
    if not mayAct then return false, rankErr end
    local allowed, permErr = actorHas(jobId, actorCharId, 'canFire')
    if not allowed then return false, permErr end

    -- Clock off first (resolve source if player is online)
    local onlinePlayer = PlayersByCharId and PlayersByCharId[charId] or nil
    Jobs.clockOff(charId, jobId, onlinePlayer and onlinePlayer.source or nil)

    -- Access dies with the employment, and goes FIRST (ForceRevoke: they will have no role). A failure
    -- leaves them employed with less access than their role gives: safe, and a retry finishes it.
    -- ('owner' is not a failure: the account's owner keeps it.) A failed READ of the accounts stops it
    -- too: an empty list would fire them with access intact.
    local jobAccounts, accErr = Bank.GetAccountsByJob(jobId)
    if accErr then return false, accErr end
    for _, acc in ipairs(jobAccounts) do
        local revoked, why = Bank.ForceRevokeAccess(acc.accountId, charId)
        if not revoked and why == DB_ERROR then
            print(('[whip_core:jobs] ERROR revoking bank access for charId %d at job #%d — not fired')
                :format(charId, jobId))
            return false, DB_ERROR
        end
    end

    -- Checked, before the cache forgets them.
    local ok, err = pcall(MySQL.query.await,
        'DELETE FROM `job_employees` WHERE `jobId` = ? AND `charId` = ?',
        { jobId, charId }
    )
    if not ok then
        print(('[whip_core:jobs] ERROR firing charId %d at job #%d: %s'):format(charId, jobId, tostring(err)))
        return false, DB_ERROR
    end

    Jobs.employees[jobId][charId] = nil

    -- Update reverse index
    if Jobs._charJobs[charId] then
        Jobs._charJobs[charId][jobId] = nil
        if not next(Jobs._charJobs[charId]) then
            Jobs._charJobs[charId] = nil
        end
    end

    Jobs.touch(charId)
    Jobs.emitJobEvent('whip_core:job:fired', jobId, charId)
    return true
end

function Jobs.fire(jobId, charId, actorCharId)
    return onePersonAtATime(jobId, charId, fireNow, actorCharId)
end

local function setRoleNow(jobId, charId, roleId, actorCharId)
    if not Jobs.cache[jobId] then return false, WHY.job end

    local roles = Jobs.roles[jobId] or {}
    if not roles[roleId] then return false, WHY.role end

    local emps = Jobs.employees[jobId] or {}
    if not emps[charId] then return false, WHY.notEmployed end

    -- Both levels checked: the role they hold now (you may not touch a peer or a superior)
    -- and the role they would receive (you may not create one).
    local currentRole = roles[emps[charId].roleId]
    local mayActCurrent, rankErr1 = actorMayAct(jobId, actorCharId, currentRole and currentRole.level or 0)
    if not mayActCurrent then return false, rankErr1 end
    local mayActNew, rankErr2 = actorMayAct(jobId, actorCharId, roles[roleId].level)
    if not mayActNew then return false, rankErr2 end
    -- Up is a promotion, down (or sideways) a demotion.
    local up = roles[roleId].level > (currentRole and currentRole.level or 0)
    local allowed, permErr = actorHas(jobId, actorCharId, up and 'canPromote' or 'canDemote')
    if not allowed then return false, permErr end
    local covers, powerErr = actorCovers(jobId, actorCharId, roles[roleId].permissions, currentRole and currentRole.permissions)
    if not covers then return false, powerErr end

    local oldRoleId = emps[charId].roleId

    -- Access never runs ahead of the role (fireNow's order): a demotion that LOWERS business-account
    -- access reaches the accounts first, and if that fails they keep their role. A promotion changes
    -- the role first (below).
    local lowering = lowersBankAccess(currentRole, roles[roleId])
    if lowering then
        local aok, aerr = Jobs.syncEmployeeBankAccess(jobId, charId, roles[roleId])
        if not aok then return false, aerr end
    end

    local ok, err = pcall(MySQL.query.await,
        'UPDATE `job_employees` SET `roleId` = ? WHERE `jobId` = ? AND `charId` = ?',
        { roleId, jobId, charId }
    )

    if not ok then
        print(('[whip_core:jobs] ERROR changing role for charId %d at job #%d: %s'):format(charId, jobId, tostring(err)))
        -- Still their old role: its access back, if it can be.
        if lowering then Jobs.syncEmployeeBankAccess(jobId, charId) end
        return false, DB_ERROR
    end

    emps[charId].roleId = roleId

    -- Update reverse index
    if Jobs._charJobs[charId] then
        Jobs._charJobs[charId][jobId] = roleId
    end

    -- Bank access follows the role — see hire. Raised (or the same) after the role: a failure leaves
    -- less access than the role gives, and syncEmployeeBankAccess says so.
    if not lowering then Jobs.syncEmployeeBankAccess(jobId, charId) end

    Jobs.touch(charId)
    Jobs.emitJobEvent('whip_core:job:roleChanged', jobId, charId, {
        roleId = roleId, role = roles[roleId] and roles[roleId].name or nil, oldRoleId = oldRoleId,
    })
    return true
end

function Jobs.setRole(jobId, charId, roleId, actorCharId)
    return onePersonAtATime(jobId, charId, setRoleNow, roleId, actorCharId)
end

function Jobs.getEmployees(jobId)
    return Jobs.employees[jobId] or {}
end

function Jobs.getCharJobs(charId)
    local result = {}

    local function add(jobId)
        local job  = Jobs.cache[jobId]
        -- getPlayerRole, not the employee row: an owner is shown with the top role (see there).
        local role = Jobs.getPlayerRole(charId, jobId)
        if job and role then
            result[jobId] = {
                jobId     = jobId,
                key       = job.key,
                name      = job.name,
                icon      = job.icon,
                roleId    = role.roleId,
                roleName  = role.name,
                roleLevel = role.level,
                clockedOn = Jobs.isClockedOn(charId, jobId),
                -- Higher = clocked on more recently; nil off duty. How the client tells which of
                -- several on-duty jobs is the current one (the client's GetPlayerJob), the rule GetPlayerJob uses.
                dutyOrder = Jobs._clockedOn[charId] and Jobs._clockedOn[charId][jobId] or nil,
                -- What they may do here, so the client offers only what the server will allow
                -- (the shop's Manage Stock option). A hint: the server still decides.
                permissions = Jobs.effectivePermissions(charId, jobId),
            }
        end
    end

    for jobId in pairs(Jobs._charJobs[charId] or {}) do add(jobId) end

    -- And every job they OWN, employed there or not — the owner holds the top role.
    if charId then
        for jobId, job in pairs(Jobs.cache) do
            if job.ownerCharId == charId and not result[jobId] then add(jobId) end
        end
    end

    return result
end

--- A business whose owner was deleted: no owner, and it KEEPS RUNNING — staff, roles, its shop and its
--- business account all stay, like a house going up for sale. The account moves to whoever an admin
--- names as the new owner in the Job Manager (Jobs.update → moveBusinessAccounts). Not through
--- Jobs.update: its rule that an account needs an owner is for an admin clearing one by hand.
---@param jobId number
---@return boolean ok
local function releaseDeletedOwner(jobId)
    local def = Jobs.cache[jobId]
    if not def then return false end
    local ok, err = pcall(MySQL.query.await, 'UPDATE `jobs` SET `ownerCharId` = NULL WHERE `jobId` = ?', { jobId })
    if not ok then
        print(('[whip_core:jobs] ERROR releasing job #%d from its deleted owner: %s'):format(jobId, tostring(err)))
        return false
    end
    local oldOwner = def.ownerCharId
    def.ownerCharId = nil
    Jobs.touchJob(jobId)
    Jobs.emitJobEvent('whip_core:job:updated', jobId, nil, {
        name = def.name, icon = def.icon, ownerCharId = nil, oldOwnerCharId = oldOwner,
    })
    return true
end

-- A deleted character leaves every job, through Jobs.fire (no actor: this is whip itself), so their
-- business-account access goes as for any fire. A job they OWN has no owner and keeps running
-- (releaseDeletedOwner above). A hook the delete runs, not a handler on the public event.
Character.onLife('deleted', function(e)
    local charId = e and e.charId
    if not charId then return end

    -- Copied first: Jobs.fire edits this table and waits on the database between entries.
    local jobIds = {}
    for jobId in pairs(Jobs._charJobs[charId] or {}) do jobIds[#jobIds + 1] = jobId end
    for _, jobId in ipairs(jobIds) do
        local ok, err = Jobs.fire(jobId, charId)
        if not ok then
            print(('[whip_core:jobs] deleted character %d could not be removed from job #%d: %s')
                :format(charId, jobId, tostring(err)))
        end
    end

    local owned = {}
    for jobId, job in pairs(Jobs.cache) do
        if job.ownerCharId == charId then owned[#owned + 1] = jobId end
    end
    for _, jobId in ipairs(owned) do
        if releaseDeletedOwner(jobId) then
            print(('[whip_core:jobs] job #%d (%s) has no owner now — its owner was deleted; give it a new one in the Job Manager')
                :format(jobId, tostring(Jobs.cache[jobId] and Jobs.cache[jobId].name)))
        end
    end
end)

-- ============================================
-- Clock System (runtime only, not persisted)
-- ============================================
--
-- Which job is "the" job: the one clocked on most recently. Each clock-on takes the next number from
-- a counter, and everything that asks (GetPlayerJob, the job statebag) reads the highest still on duty.
local _dutySeq = 0

--- The job this character is on duty at that they clocked on at most recently, or nil.
---@param charId number
---@return number|nil jobId
function Jobs.currentDutyJob(charId)
    local best, bestSeq = nil, nil
    for jobId, seq in pairs(Jobs._clockedOn[charId] or {}) do
        if not bestSeq or seq > bestSeq then best, bestSeq = jobId, seq end
    end
    return best
end

--- Who is on duty where, as { [charId] = { [jobId] = true } } — for the Job Manager, which only
--- needs yes or no.
---@return table
function Jobs.dutyMap()
    local out = {}
    for charId, jobs in pairs(Jobs._clockedOn) do
        out[charId] = {}
        for jobId in pairs(jobs) do out[charId][jobId] = true end
    end
    return out
end

--- Clock on. Pass source (optional) to auto-send client event + update statebag.
---
--- Clocking on at a job they are already on duty at makes it their current one again.
---@param charId number
---@param jobId number
---@param source number|nil  Server ID of the player (nil = internal/offline, skip client sync)
function Jobs.clockOn(charId, jobId, source)
    if not Jobs.cache[jobId] then return false, WHY.job end
    local emps = Jobs.employees[jobId] or {}
    -- The owner may clock on at their own business without being on its payroll.
    if not emps[charId] and not Jobs.isOwner(charId, jobId) then return false, WHY.notEmployed end

    -- One job at a time, when the server wants it (Config.JobDutyOneAtATime): off duty everywhere
    -- else first, each announced like any clock-off.
    if Config.JobDutyOneAtATime then
        local others = {}
        for otherId in pairs(Jobs._clockedOn[charId] or {}) do
            if otherId ~= jobId then others[#others + 1] = otherId end
        end
        for _, otherId in ipairs(others) do Jobs.clockOff(charId, otherId, source) end
    end

    local wasOn = Jobs.isClockedOn(charId, jobId)
    _dutySeq = _dutySeq + 1
    Jobs._clockedOn[charId] = Jobs._clockedOn[charId] or {}
    Jobs._clockedOn[charId][jobId] = _dutySeq

    if source then
        TriggerClientEvent('whip_core:client:jobClockState', source, jobId, true)
        local job = Jobs.cache[jobId]
        Sentinel.setPlayerKey(source, PLAYER_JOB_KEY, job and job.key or false)
    end

    Jobs.touch()   -- the Job Manager's duty dots; the player's own client was told above
    -- Only a real change is announced: clocking on again where they already are is not one.
    if not wasOn then Jobs.emitJobEvent('whip_core:job:clockedOn', jobId, charId) end
    return true
end

--- Clock off. Pass source (optional) to auto-send client event + update statebag.
---@param charId number
---@param jobId number
---@param source number|nil
function Jobs.clockOff(charId, jobId, source)
    if not Jobs.isClockedOn(charId, jobId) then return false, WHY.offDuty end
    Jobs._clockedOn[charId][jobId] = nil
    if not next(Jobs._clockedOn[charId]) then
        Jobs._clockedOn[charId] = nil
    end

    if source then
        TriggerClientEvent('whip_core:client:jobClockState', source, jobId, false)
        -- Still on duty elsewhere: that becomes the job, the most recent of what is left.
        local nextJob = Jobs.cache[Jobs.currentDutyJob(charId)]
        Sentinel.setPlayerKey(source, PLAYER_JOB_KEY, nextJob and nextJob.key or false)
    end

    Jobs.touch()
    Jobs.emitJobEvent('whip_core:job:clockedOff', jobId, charId)
    return true
end

--- Off duty at every job. Through clockOff, one job at a time, so each is announced like any other
--- clock-off. Answers true.
---@param charId number
---@param source number|nil  their source, when their client and statebag should hear it
function Jobs.clockOffAll(charId, source)
    local jobIds = {}
    for jobId in pairs(Jobs._clockedOn[charId] or {}) do jobIds[#jobIds + 1] = jobId end
    for _, jobId in ipairs(jobIds) do Jobs.clockOff(charId, jobId, source) end
    return true
end

function Jobs.isClockedOn(charId, jobId)
    if not Jobs._clockedOn[charId] then return false end
    return Jobs._clockedOn[charId][jobId] ~= nil
end

function Jobs.getClockedOnEmployees(jobId)
    local result = {}
    local emps = Jobs.employees[jobId] or {}
    for charId in pairs(emps) do
        if Jobs.isClockedOn(charId, jobId) then
            result[#result + 1] = charId
        end
    end
    -- An owner on duty counts, employed there or not.
    local owner = Jobs.cache[jobId] and Jobs.cache[jobId].ownerCharId
    if owner and not emps[owner] and Jobs.isClockedOn(owner, jobId) then
        result[#result + 1] = owner
    end
    return result
end

-- ============================================
-- Permissions
-- ============================================

--- The job's top role: the highest level it has ('Owner', level 100, with the default roles).
---@param jobId number
---@return table|nil role
local function topRole(jobId)
    local best = nil
    for _, role in pairs(Jobs.roles[jobId] or {}) do
        if not best or (role.level or 0) > (best.level or 0) then best = role end
    end
    return best
end

--- Does this character own the job?
---@return boolean
function Jobs.isOwner(charId, jobId)
    local job = Jobs.cache[jobId]
    return job ~= nil and charId ~= nil and job.ownerCharId == charId
end

--- The role this character acts with at this job, or nil if they have none.
---
--- The owner holds the top role, employed or not. Resolved HERE, rather than by hiring the owner as
--- an employee, so it ends the moment ownership moves (a level-100 employee left behind would keep
--- every power).
function Jobs.getPlayerRole(charId, jobId)
    if Jobs.isOwner(charId, jobId) then
        local top = topRole(jobId)
        if top then return top end
    end

    local emps = Jobs.employees[jobId] or {}
    local emp = emps[charId]
    if not emp then return nil end

    local roles = Jobs.roles[jobId] or {}
    return roles[emp.roleId]
end

--- Does this job still know this permission — a built-in, or one its resource declares NOW?
---
--- A role's table is not enough: a permission the resource stopped declaring stays in each role's
--- stored table, with no toggle left to take it away. A key this job does not know counts for nothing.
---@param jobId number
---@param permission string
---@return boolean
local function knownPermission(jobId, permission)
    if BUILTIN_PERM[permission] then return true end
    local job = Jobs.cache[jobId]
    local declared = job and type(job.settings) == 'table' and job.settings.permissions
    return type(declared) == 'table' and declared[permission] ~= nil
end

function Jobs.hasPermission(charId, jobId, permission)
    local role = Jobs.getPlayerRole(charId, jobId)
    if not role then return false end

    -- Owner level (100) always has all permissions
    if role.level >= 100 then return true end

    local perms = role.permissions or {}
    return perms[permission] == true and knownPermission(jobId, permission)
end

--- Every permission this character holds at this job, as { [name] = true } — what hasPermission
--- would say yes to. For the client's job list.
---@param charId number
---@param jobId number
---@return table
function Jobs.effectivePermissions(charId, jobId)
    local out = {}
    local role = Jobs.getPlayerRole(charId, jobId)
    if not role then return out end
    if role.level >= 100 then
        -- The built-ins and the job's own: level 100 holds everything hasPermission knows of.
        for _, p in ipairs(Jobs.permissionList(jobId)) do out[p.key] = true end
        return out
    end
    for key, value in pairs(role.permissions or {}) do
        if value == true and knownPermission(jobId, key) then out[key] = true end
    end
    return out
end

-- ============================================
-- Bank Access Sync
-- ============================================

--- Sync a single employee's bank access for all job accounts based on their role.
---
--- Answers, and a failed read is a failure (not "a job with no accounts"): `true`, or `false, DB_ERROR`.
---
--- `role` is the role to sync to; nil means the one they hold. A caller LOWERING access passes the
--- role they are about to get, and syncs first (see setRoleNow): access never runs ahead of the role.
---@param jobId number
---@param charId number
---@param role table|nil
---@return boolean ok
---@return string|nil err
function Jobs.syncEmployeeBankAccess(jobId, charId, role)
    local emp = Jobs.employees[jobId] and Jobs.employees[jobId][charId]
    if not emp then return true end

    role = role or (Jobs.roles[jobId] and Jobs.roles[jobId][emp.roleId])
    if not role then return true end

    local bankAccess = roleBankAccess(role)

    local jobAccounts, accErr = Bank.GetAccountsByJob(jobId)
    if accErr then
        print(('[whip_core:jobs] ERROR reading job #%d\'s accounts to sync charId %d\'s bank access: %s')
            :format(jobId, charId, tostring(accErr)))
        return false, accErr
    end
    local allOk = true
    for _, acc in ipairs(jobAccounts) do
        local ok, why
        if bankAccess == 'none' then
            ok, why = Bank.ForceRevokeAccess(acc.accountId, charId)
            -- The account's OWNER keeps access whatever their role says, and that is not an error.
            if not ok and why ~= DB_ERROR then ok = true end
        else
            ok = Bank.ForceSetAccess(acc.accountId, charId, bankAccess)
        end
        if not ok then
            allOk = false
            print(('[whip_core:jobs] ERROR syncing bank access for charId %d on account %s (job #%d)')
                :format(charId, tostring(acc.accountId), jobId))
        end
    end
    if not allOk then return false, DB_ERROR end
    return true
end

--- Sync bank access for ALL employees holding a specific role. `role` as syncEmployeeBankAccess:
--- the role as it is about to be, for a change that lowers access. Answers true only if every one
--- of them synced.
---@param jobId number
---@param roleId number
---@param role table|nil
---@return boolean ok
---@return string|nil err
function Jobs.syncRoleBankAccess(jobId, roleId, role)
    local emps = Jobs.employees[jobId] or {}
    local ok, err = true, nil
    for charId, emp in pairs(emps) do
        if emp.roleId == roleId then
            local one, why = Jobs.syncEmployeeBankAccess(jobId, charId, role)
            if not one then ok, err = false, why end
        end
    end
    return ok, err
end

-- ============================================
-- Answers about a character
-- ============================================

--- The job a character is on duty at — the one they clocked on at most recently (see the Clock
--- System note) — or nil when they are off duty. The same job the whipJob statebag names.
---@param charId number
---@return table|nil { jobId, key, name, icon, roleId, roleName, roleLevel }
function Jobs.dutyJobInfo(charId)
    local current = Jobs.currentDutyJob(charId)
    if not current then return nil end

    local job = Jobs.cache[current]
    local role = Jobs.getPlayerRole(charId, current)
    if not job or not role then return nil end

    return {
        jobId     = current,
        key       = job.key,
        name      = job.name,
        icon      = job.icon,
        roleId    = role.roleId,
        roleName  = role.name,
        roleLevel = role.level,
    }
end

--- Every job an online player has a role at (for doors.lua, which holds a source).
function Jobs.getPlayerJobs(source)
    local player = Players[source]
    if not player then return {} end
    return Jobs.getCharJobs(player.charId)
end

-- ============================================
-- Public Exports
-- ============================================
--
-- Every one takes the three reference shapes at the top of this file — a job by jobId or key, a
-- person by source or { charId = n }, a role by roleId or name — and answers whip's one rule: a
-- value, or `false` and a reason — a sentence, from WHY at the top of this file (or DB_ERROR).
--
-- (The player's job list and an open Job Manager are refreshed inside Jobs.* — see Jobs.touch.)

--- A role as a plain row, its permissions a copy.
---@param role table
---@return table { roleId, name, level, permissions }
local function roleRow(role)
    local perms = {}
    for k, v in pairs(role.permissions or {}) do perms[k] = v end
    return { roleId = role.roleId, name = role.name, level = role.level, permissions = perms }
end

--- A job's roles as plain rows, highest level first.
---@param jobId number
---@return table[] { roleId, name, level, permissions }
local function roleRows(jobId)
    local rows = {}
    for _, role in ipairs(Jobs.getRoles(jobId)) do
        rows[#rows + 1] = roleRow(role)
    end
    return rows
end

-- ---- Jobs ----

--- A job, by jobId or key. nil when there is none.
exports('GetJob', function(job)
    return Jobs.resolve(job)
end)

--- Every job, by jobId.
exports('GetJobs', function()
    return Jobs.getAll()
end)

--- A job's roles, highest level first: { roleId, name, level, permissions }. What a satellite hires into.
exports('GetJobRoles', function(job)
    local def = Jobs.resolve(job)
    if not def then return false, WHY.job end
    return roleRows(def.jobId)
end)

--- Find-or-create a job by key. data: { name, icon, owner = person, roles, permissions, selfClockOn,
--- settings } — see Jobs.ensureJob for each, and for what changes on a job that already exists. An
--- existing job keeps its owner: `owner` only applies when the job is made. Answers the job, or
--- false and why.
exports('EnsureJob', function(key, data)
    local caller = Registry.caller()   -- first, before anything can yield
    -- Waits for whip_core to finish starting, or the jobs aren't loaded and the key looks new.
    if not WaitForCoreReady() then return false, NOT_READY end
    data = type(data) == 'table' and data or {}
    local ownerCharId = nil
    if data.owner ~= nil then
        ownerCharId = WhoIs(data.owner)
        if not ownerCharId then return false, WHY.player end
    end
    -- Just the job when it worked, as UpdateJob answers (a second value would read as a failure).
    -- A business account that did not follow goes to the console.
    local job, second = Jobs.ensureJob(key, {
        name        = data.name,
        icon        = data.icon,
        ownerCharId = ownerCharId,
        settings    = data.settings,
        roles       = data.roles,
        permissions = data.permissions,
        selfClockOn = data.selfClockOn,
    }, caller)
    if not job then
        Registry.sayRefused(caller, ('EnsureJob("%s"): %s'):format(tostring(key), tostring(second)))
        return false, second
    end
    if second ~= nil then
        print(('[whip_core:jobs] EnsureJob("%s"): the job stands, but %s'):format(tostring(key),
            second == 'account_not_created' and 'its business account could not be made' or tostring(second)))
    end
    return job
end)

--- Change a job: { name, icon, owner = person | false }. `owner = false` removes the owner (refused
--- while the job has a business account). The business account follows a new owner. Answers true,
--- or false and why.
---
--- Just true once the job has changed: a second value from an export is always a reason. A business
--- account that could not follow is said in the console (moveBusinessAccounts).

-- A job another running resource declared (EnsureJob) is that resource's to change or delete, as a zone is
-- (DeleteZone). One made in the Job Manager, or whose resource is not running, is open to any.
local function declaredByAnother(def, caller)
    local by = type(def.settings) == 'table' and def.settings.declaredBy or nil
    if by and by ~= caller and Registry.alive(by) then
        return ('job "%s" is declared by %s: only it can change or delete it'):format(tostring(def.key), by)
    end
    return nil
end

exports('UpdateJob', function(job, patch)
    local caller = Registry.caller()   -- first, before anything can yield
    local def = Jobs.resolve(job)
    if not def then return false, WHY.job end
    if type(patch) ~= 'table' then return false, 'nothing to change' end
    local theirs = declaredByAnother(def, caller)
    if theirs then return false, theirs end

    local data = { name = patch.name, icon = patch.icon }
    if patch.owner == false then
        data.ownerCharId = false
    elseif patch.owner ~= nil then
        local charId = WhoIs(patch.owner)
        if not charId then return false, WHY.player end
        data.ownerCharId = charId
    end
    local ok, why = Jobs.update(def.jobId, data)
    if not ok then return false, why end
    return true
end)

--- Delete a job, its roles and its staff list; its (empty) business accounts close with it.
exports('DeleteJob', function(job)
    local caller = Registry.caller()
    local def = Jobs.resolve(job)
    if not def then return false, WHY.job end
    local theirs = declaredByAnother(def, caller)
    if theirs then return false, theirs end
    return Jobs.delete(def.jobId)
end)

-- ---- Staff ----

--- `opts.by`: the player doing it. A person (source or { charId = n }) whose rank and role permission
--- are checked: they must outrank the person's role now and the role they give, and hold canHire /
--- canFire / canPromote / canDemote. Leave it out when your own code or an admin tool decides — then
--- nothing is checked (a trusted caller, as the Job Manager is).
---@param opts table|nil
---@return number|nil|false actorCharId  nil for none; false when `by` names nobody
local function byOf(opts)
    if type(opts) ~= 'table' or opts.by == nil then return nil end
    return WhoIs(opts.by) or false
end

--- Hire someone. `role` is optional — a role name or id; without one they start at the lowest role.
--- opts: { by = person } — the player hiring them: recorded, and checked (see byOf). Offline
--- characters can be hired ({ charId = n }).
exports('HirePlayer', function(who, job, role, opts)
    local charId = WhoIs(who)
    if not charId then return false, WHY.player end
    local def = Jobs.resolve(job)
    if not def then return false, WHY.job end

    local r
    if role == nil then r = Jobs.lowestRole(def.jobId) else r = Jobs.resolveRole(def.jobId, role) end
    if not r then return false, WHY.role end

    local by = byOf(opts)
    if by == false then return false, WHY.byNobody end
    return Jobs.hire(def.jobId, charId, r.roleId, by, by)
end)

--- Would HirePlayer with these arguments be allowed? Every one of its rules, nothing written: for a step that
--- waits on someone first (the phone's job offer, which hires when the other player accepts).
exports('CanHirePlayer', function(who, job, role, opts)
    local charId = WhoIs(who)
    if not charId then return false, WHY.player end
    local def = Jobs.resolve(job)
    if not def then return false, WHY.job end
    local r
    if role == nil then r = Jobs.lowestRole(def.jobId) else r = Jobs.resolveRole(def.jobId, role) end
    if not r then return false, WHY.role end
    local by = byOf(opts)
    if by == false then return false, WHY.byNobody end
    return Jobs.checkHire(def.jobId, charId, r.roleId, by)
end)

--- Fire someone. opts: { by = person } — the player firing them, checked (see byOf).
exports('FirePlayer', function(who, job, opts)
    local charId = WhoIs(who)
    if not charId then return false, WHY.player end
    local def = Jobs.resolve(job)
    if not def then return false, WHY.job end
    local by = byOf(opts)
    if by == false then return false, WHY.byNobody end
    return Jobs.fire(def.jobId, charId, by)
end)

--- Change someone's role. opts: { by = person } — the player promoting or demoting them, checked
--- (see byOf): nobody promotes themselves or a peer, or hands out a role at their own level.
exports('SetPlayerRole', function(who, job, role, opts)
    local charId = WhoIs(who)
    if not charId then return false, WHY.player end
    local def = Jobs.resolve(job)
    if not def then return false, WHY.job end
    local r = Jobs.resolveRole(def.jobId, role)
    if not r then return false, WHY.role end
    local by = byOf(opts)
    if by == false then return false, WHY.byNobody end
    return Jobs.setRole(def.jobId, charId, r.roleId, by)
end)

-- ---- Roles ----
--
-- Make, change and delete a job's roles, for the phone's Business app and any boss menu. `opts.by` is
-- the player doing it (byOf), checked:
--   - they need canManage;
--   - below level 100, a role at or above their own level is not theirs to change or delete, and they may
--     not make a role at their level or raise one to it;
--   - nor give a role a permission, or more business-account access, than their own role has (actorCovers);
--   - they may not leave the job without a level 100 role (the owner's top role, which nobody below 100
--     could make again).

--- A role name as given: 1 to 60 characters, and no other role at the job has it (names ignore case, as
--- the database's do). nil when it will do, else why.
---@param jobId number
---@param name any
---@param roleId number|nil  the role being renamed
---@return string|nil why
local function roleNameWhy(jobId, name, roleId)
    if type(name) ~= 'string' or name == '' or #name > 60 or name:find('[%z\1-\31]') then
        return 'A role name is 1 to 60 characters'
    end
    local same = Jobs.resolveRole(jobId, name)
    if same and same.roleId ~= roleId then return ('There is already a role called %s'):format(same.name) end
    return nil
end

--- A role's permissions from what a caller wrote, `{ canHire = true, cuff = true, bankAccess = 'view' }`,
--- laid over `base` (on a change, the role's own: what is not named stays, and `false` takes one away).
--- A name the job does not know is refused rather than dropped, so a misspelt 'canhire' is not saved as
--- nothing.
---@param jobId number
---@param given table|nil
---@param base table|nil
---@return table|false perms
---@return string|nil why
local function rolePermissions(jobId, given, base)
    local perms = {}
    for k, v in pairs(base or {}) do perms[k] = v end
    if given ~= nil then
        if type(given) ~= 'table' then
            return false, 'permissions must be a table: { canHire = true, bankAccess = \'view\' }'
        end
        local known = {}
        for _, p in ipairs(Jobs.permissionList(jobId)) do known[p.key] = true end
        for k, v in pairs(given) do
            if k == 'bankAccess' then
                if not BANK_ACCESS[v] then return false, 'bankAccess is none, view, deposit, withdraw or manager' end
                perms.bankAccess = v
            elseif not known[k] then
                return false, ('"%s" is not a permission at this job'):format(tostring(k))
            elseif type(v) ~= 'boolean' then
                return false, ('Permission "%s" is true or false'):format(k)
            else
                perms[k] = v or nil
            end
        end
    end
    return Jobs.cleanPermissions(jobId, perms)
end

--- Would changing role `roleId` to `newLevel` (nil: deleting it) leave the job with no level 100 role?
---@param jobId number
---@param roleId number
---@param newLevel number|nil
---@return boolean
local function losesTopLevel(jobId, roleId, newLevel)
    local roles = Jobs.roles[jobId] or {}
    for id, role in pairs(roles) do
        if id ~= roleId and (role.level or 0) >= 100 then return false end
    end
    local role = roles[roleId]
    return role ~= nil and (role.level or 0) >= 100 and (newLevel == nil or newLevel < 100)
end

--- A new role: data { name, level (1-100), permissions? }. opts: { by = person }, checked (above).
--- Answers the role { roleId, name, level, permissions }, or false and why.
exports('CreateJobRole', function(job, data, opts)
    local def = Jobs.resolve(job)
    if not def then return false, WHY.job end
    if type(data) ~= 'table' then return false, 'data must be a table: { name, level, permissions }' end
    local nameWhy = roleNameWhy(def.jobId, data.name)
    if nameWhy then return false, nameWhy end
    local level = Sanitize.id(data.level, 1, 100)
    if not level then return false, 'A role\'s level is a whole number from 1 to 100' end
    local perms, permWhy = rolePermissions(def.jobId, data.permissions)
    if not perms then return false, permWhy end

    local by = byOf(opts)
    if by == false then return false, WHY.byNobody end
    local ok, why = actorHas(def.jobId, by, 'canManage')
    if not ok then return false, why end
    ok, why = actorMayAct(def.jobId, by, level)
    if not ok then return false, why end
    ok, why = actorCovers(def.jobId, by, perms)
    if not ok then return false, why end

    local role, err = Jobs.createRole(def.jobId, { name = data.name, level = level, permissions = perms })
    if not role then return false, err end
    return roleRow(role)
end)

--- Change a role: patch { name?, level?, permissions? }. Permissions not named keep their value (a job's
--- own, like 'cuff', are not wiped by a form that does not show them). opts: { by = person }, checked.
--- Holders' business-account access follows the role. Answers true, or false and why.
exports('UpdateJobRole', function(job, role, patch, opts)
    local def = Jobs.resolve(job)
    if not def then return false, WHY.job end
    local r = Jobs.resolveRole(def.jobId, role)
    if not r then return false, WHY.role end
    if type(patch) ~= 'table' then return false, 'patch must be a table: { name?, level?, permissions? }' end

    local data = {}
    if patch.name ~= nil then
        local nameWhy = roleNameWhy(def.jobId, patch.name, r.roleId)
        if nameWhy then return false, nameWhy end
        data.name = patch.name
    end
    if patch.level ~= nil then
        data.level = Sanitize.id(patch.level, 1, 100)
        if not data.level then return false, 'A role\'s level is a whole number from 1 to 100' end
    end
    if patch.permissions ~= nil then
        local perms, permWhy = rolePermissions(def.jobId, patch.permissions, r.permissions)
        if not perms then return false, permWhy end
        data.permissions = perms
    end

    local by = byOf(opts)
    if by == false then return false, WHY.byNobody end
    local ok, why = actorHas(def.jobId, by, 'canManage')
    if not ok then return false, why end
    ok, why = actorMayAct(def.jobId, by, r.level)
    if not ok then return false, why end
    if data.level then
        ok, why = actorMayAct(def.jobId, by, data.level)
        if not ok then return false, why end
        if by and losesTopLevel(def.jobId, r.roleId, data.level) then return false, WHY.topRole end
    end
    if data.permissions then
        ok, why = actorCovers(def.jobId, by, data.permissions, r.permissions)
        if not ok then return false, why end
    end
    return Jobs.updateRole(r.roleId, data)
end)

--- Delete a role nobody holds. opts: { by = person }, checked. Answers true, or false and why.
exports('DeleteJobRole', function(job, role, opts)
    local def = Jobs.resolve(job)
    if not def then return false, WHY.job end
    local r = Jobs.resolveRole(def.jobId, role)
    if not r then return false, WHY.role end

    local by = byOf(opts)
    if by == false then return false, WHY.byNobody end
    local ok, why = actorHas(def.jobId, by, 'canManage')
    if not ok then return false, why end
    ok, why = actorMayAct(def.jobId, by, r.level)
    if not ok then return false, why end
    if by and losesTopLevel(def.jobId, r.roleId) then return false, WHY.topRole end
    return Jobs.deleteRole(r.roleId)
end)

--- Everyone on the payroll, by charId: { charId, roleId, roleName, roleLevel, hiredAt, hiredBy,
--- onDuty, source (online only) }. The owner is not listed unless also hired.
exports('GetJobEmployees', function(job)
    local def = Jobs.resolve(job)
    if not def then return false, WHY.job end

    local out = {}
    for charId, emp in pairs(Jobs.employees[def.jobId] or {}) do
        local role = (Jobs.roles[def.jobId] or {})[emp.roleId]
        local p = PlayersByCharId and PlayersByCharId[charId]
        out[charId] = {
            charId    = charId,
            roleId    = emp.roleId,
            roleName  = role and role.name or nil,
            roleLevel = role and role.level or nil,
            hiredAt   = emp.hiredAt,
            hiredBy   = emp.hiredBy,
            onDuty    = Jobs.isClockedOn(charId, def.jobId),
            source    = p and p.source or nil,
        }
    end
    return out
end)

--- Everyone on duty at this job, owner included: { { charId, source } }. Duty ends at logout, so each
--- has a source — the list a dispatch or a paycheck walks.
exports('GetClockedOnEmployees', function(job)
    local def = Jobs.resolve(job)
    if not def then return false, WHY.job end

    local out = {}
    for _, charId in ipairs(Jobs.getClockedOnEmployees(def.jobId)) do
        local p = PlayersByCharId and PlayersByCharId[charId]
        out[#out + 1] = { charId = charId, source = p and p.source or nil }
    end
    return out
end)

-- ---- A person's jobs ----

--- Their role at this job (the top role if they own it), or nil.
exports('GetPlayerRole', function(who, job)
    local charId = WhoIs(who)
    local def = Jobs.resolve(job)
    if not charId or not def then return nil end
    return Jobs.getPlayerRole(charId, def.jobId)
end)

--- May they do this at this job? opts: { onDuty = true } also requires them to be on duty there —
--- permissions otherwise hold on duty or off (a manager can manage stock on their day off).
---
--- `true`, or `false, why`, as every access check answers. The why is worded for either person, since
--- the asker is often the player.
exports('HasJobPermission', function(who, job, permission, opts)
    local charId = WhoIs(who)
    if not charId then return false, WHY.player end
    local def = Jobs.resolve(job)
    if not def then return false, WHY.job end
    if type(opts) == 'table' and opts.onDuty and not Jobs.isClockedOn(charId, def.jobId) then
        return false, ('Not on duty at %s'):format(def.name or def.key or 'that job')
    end
    if Jobs.hasPermission(charId, def.jobId, permission) then return true end
    return false, ('Not allowed at %s'):format(def.name or def.key or 'that job')
end)

--- The job they are on duty at — the most recent clock-on — or nil.
exports('GetPlayerJob', function(who)
    local charId = WhoIs(who)
    if not charId then return nil end
    return Jobs.dutyJobInfo(charId)
end)

--- Every job they have a role at, by jobId.
exports('GetPlayerJobs', function(who)
    local charId = WhoIs(who)
    if not charId then return {}, WHY.player end   -- a list read: empty, and why
    return Jobs.getCharJobs(charId)
end)

--- On duty at this job — or, with no job, at any. `false, why` when the question is wrong (no such
--- player or job), so a caller can tell "off duty" from "asked about nobody".
exports('IsPlayerClockedOn', function(who, job)
    local charId = WhoIs(who)
    if not charId then return false, WHY.player end
    if job == nil then return Jobs.currentDutyJob(charId) ~= nil end
    local def = Jobs.resolve(job)
    if not def then return false, WHY.job end
    return Jobs.isClockedOn(charId, def.jobId)
end)

-- ---- Duty ----

--- Put an online player on duty. Answers true, or false and why.
---
--- opts: { by = person } — the player doing it (the phone's Business app), checked as the client's
--- the client's ClockOn is: a player clocks only themselves on, and only at a job that lets them (EnsureJob's
--- selfClockOn). Leave it out when your own code decides (the uniform locker at the station).
exports('ClockOn', function(who, job, opts)
    local charId, source = WhoIs(who)
    if not charId then return false, WHY.player end
    -- (With a charId, WhoIs answers their source or nil, not a why.)
    ---@cast source number|nil
    if not source then return false, WHY.offline end
    local def = Jobs.resolve(job)
    if not def then return false, WHY.job end
    local by = byOf(opts)
    if by == false then return false, WHY.byNobody end
    if by then
        if by ~= charId then return false, 'A player clocks only themselves on' end
        if not Jobs.allowsSelfClockOn(def.jobId) then return false, WHY.selfClock end
    end
    return Jobs.clockOn(charId, def.jobId, source)
end)

--- Take someone off duty at this job — or, with no job, at every job.
exports('ClockOff', function(who, job)
    local charId, source = WhoIs(who)
    if not charId then return false, WHY.player end
    -- (With a charId, WhoIs answers their source or nil, not a why.)
    ---@cast source number|nil
    if job == nil then return Jobs.clockOffAll(charId, source) end
    local def = Jobs.resolve(job)
    if not def then return false, WHY.job end
    return Jobs.clockOff(charId, def.jobId, source)
end)

-- ---- The player's own clock on / off (the client's ClockOn / ClockOff) ----
--
-- Callbacks, so the client hears the answer. A job whose resource said `selfClockOn = false` refuses
-- the clock-ON: its resource puts people on duty itself (at the station, with the uniform on). Going
-- OFF duty is always allowed.

--- The job a client named — a jobId or a key — or nil.
local function clientJob(ref)
    if type(ref) == 'string' and validKey(ref) then return Jobs.getByKey(ref) end
    local id = Sanitize.id(ref)
    return id and Jobs.cache[id] or nil
end

SecureCallback('whip_core:jobs:clockOn', {
    rateLimit = 1000,
    params = { {'job', 'any'} },
}, function(source, player, job)
    local def = clientJob(job)
    if not def then return false, WHY.job end
    if not Jobs.allowsSelfClockOn(def.jobId) then return false, WHY.selfClock end
    return Jobs.clockOn(player.charId, def.jobId, source)
end)

SecureCallback('whip_core:jobs:clockOff', {
    whileDead = true,   -- going off duty is always allowed (clocking ON is not, while dead)
    rateLimit = 1000,
    params = { {'job', 'any'} },
}, function(source, player, job)
    if job == nil then return Jobs.clockOffAll(player.charId, source) end
    local def = clientJob(job)
    if not def then return false, WHY.job end
    return Jobs.clockOff(player.charId, def.jobId, source)
end)

