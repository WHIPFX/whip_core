-- ============================================
-- Schema migrations — server/migrations.lua
--
-- THE SCHEMA IS NOT HERE. Each module's ensureTable builds its tables complete — columns, keys,
-- foreign keys, checks — with a `CREATE TABLE IF NOT EXISTS` (through CreateTable in
-- server/helpers.lua), and start-up runs them in a fixed order, parents first
-- (server/player_lifecycle.lua). An empty database is built right the first time.
--
-- THIS FILE IS FOR CHANGING A SCHEMA THAT ALREADY EXISTS ON SOMEBODY'S SERVER. A CREATE TABLE IF NOT
-- EXISTS cannot touch a table that is already there, so once whip is in use, a change to a table
-- is two edits: the CREATE (so a new server gets it) and a migration here (so an existing one
-- does).
--
-- 001–021 are gone on purpose: they were squashed into the CREATE statements before release. New
-- migrations start at 022.
--
-- A NEW DATABASE RUNS NONE OF THEM. Start-up asks before it makes any table (Migrations.isNewDatabase);
-- on a new one every table is made complete, so the whole list is recorded as done and the console says
-- so in one line. Only a database made before a change runs it, and the console counts them from 1.
--
-- EVERY MIGRATION MUST STILL BE A NO-OP ON A FRESH TABLE, because a table made after the rest (a
-- satellite's, the Director's) has the change in its CREATE too. So a statement says what it is about —
-- `unless = { index|column|constraint = { table, name } }` skips it when the thing already exists,
-- `onlyIf = {...}` skips it when it does not — or the migration is a `run` function that probes first.
--
-- How it runs: the list is ORDERED and APPEND ONLY. Each entry has a stable `id`; applied ids are
-- recorded in `schema_migrations`, so each runs once per database. Runs on resource start, after
-- the ensureTable calls and before any player can load. A failure halts start-up.
-- ============================================

Migrations = {}

---@alias WhipMigrationGuard { index: string[]|nil, column: string[]|nil, constraint: string[]|nil }
---@alias WhipMigrationStatement string|{ sql: string, unless: WhipMigrationGuard|nil, onlyIf: WhipMigrationGuard|nil }

-- ============================================
-- Migration list — APPEND ONLY, starting at 022
-- ============================================
--
-- The shape: an `id`, a `note` saying why it exists (for whoever reads the list in a year), and
-- `statements` that each say what they are about, so a fresh database — whose CREATE already has
-- the change — skips them all.

--- 3D Clanker's furniture category fixes from v4 on (as 037 does them): data/<file> lists model,from,to, and each
--- row moves only while it is still in `from`, so an admin's own move stands. To 'hidden' (not a category) takes it
--- out of the furnisher, marked unavailable as /prop remove does. One statement per (from, to) and 500 models.
---@param file string
---@return number moved, number removed
local function movePropCategories(file)
    local src = LoadResourceFile(GetCurrentResourceName(), 'data/' .. file)
    if not src then error('data/' .. file .. ' is missing') end
    local byMove, order = {}, {}
    for line in src:gmatch('[^\r\n]+') do
        local model, from, to = line:match('^([%w_]+),([%w_]+),([%w_]+)$')
        if model and model ~= 'model' then
            local k = from .. '>' .. to
            if not byMove[k] then
                byMove[k] = { from = from, to = to, models = {} }
                order[#order + 1] = k
            end
            local list = byMove[k].models
            list[#list + 1] = model
        end
    end
    local moved, removed = 0, 0
    for _, k in ipairs(order) do
        local m = byMove[k]
        for first = 1, #m.models, 500 do
            local sql, params
            if m.to == 'hidden' then
                sql = 'UPDATE `prop_catalog` SET `status` = \'unavailable\' WHERE `category` = ? AND `status` <> \'unavailable\' AND `model` IN (%s)'
                params = { m.from }
            else
                sql = 'UPDATE `prop_catalog` SET `category` = ? WHERE `category` = ? AND `model` IN (%s)'
                params = { m.to, m.from }
            end
            local marks = {}
            for i = first, math.min(first + 499, #m.models) do
                params[#params + 1] = m.models[i]
                marks[#marks + 1] = '?'
            end
            local n = tonumber(MySQL.update.await(sql:format(table.concat(marks, ',')), params)) or 0
            if m.to == 'hidden' then removed = removed + n else moved = moved + n end
        end
    end
    return moved, removed
end

--- Whip's own tables, the phone's among them (whip_phone/server/schema.lua): 042 changes these and nothing else that
--- shares the database.
local WHIP_TABLES = {
    'activity_log', 'admin_notes', 'bank_access', 'bank_accounts', 'bank_transactions', 'bans', 'cash_marks',
    'character_inventory', 'character_portraits', 'characters', 'container_inventory', 'containers', 'director_lore',
    'director_lore_portraits', 'director_pack_trust', 'director_packs', 'director_revisions', 'director_run_events',
    'director_run_players', 'director_runs', 'director_scenarios', 'director_takes', 'doors', 'garage_spots', 'garages',
    'ground_items', 'job_employees', 'job_roles', 'jobs', 'pending_gives', 'phone_blocks', 'phone_calls', 'phone_contacts',
    'phone_messages', 'phone_numbers', 'prop_catalog', 'properties', 'property_keys', 'property_objects',
    'property_packs', 'property_template_units', 'property_templates', 'schema_migrations', 'shop_item_prices', 'shops',
    'system_revisions', 'system_state', 'systems', 'users', 'vehicle_catalog', 'vehicle_class_meta', 'vehicle_inventory',
    'vehicle_meta', 'vehicles', 'whip_camera_sequences', 'whip_item_holds', 'whip_permissions', 'whip_settings', 'whip_settings_log',
    'whip_world', 'zones',
}

local function sqlQuote(s)
    return "'" .. (tostring(s):gsub('\\', '\\\\'):gsub("'", "''")) .. "'"
end

-- The foreign keys 042 takes off while it changes the text they join (the database refuses to change a column a key
-- uses, whatever the key checks say), kept in a server KVP until they are back: a start stopped between taking them
-- off and putting them back puts them back at the next one. One key a line: table|name|cols|ref|refCols|delete|update.
local HELD_KEYS_KVP = 'whip_core:migration042:keys'

local function keySql(k)
    return ('ALTER TABLE `%s` ADD CONSTRAINT `%s` FOREIGN KEY (`%s`) REFERENCES `%s` (`%s`) ON DELETE %s ON UPDATE %s')
        :format(k.tbl, k.name, k.cols:gsub(',', '`, `'), k.ref, k.refCols:gsub(',', '`, `'), k.del, k.upd)
end

--- The foreign keys of whip's tables that join text columns still sorting another way than `target`:
--- { tbl, name, cols, ref, refCols, del, upd }.
local function textKeys(wanted, target)
    local rows = MySQL.query.await([[
        SELECT k.TABLE_NAME AS tbl, k.CONSTRAINT_NAME AS name, k.COLUMN_NAME AS col, k.REFERENCED_TABLE_NAME AS ref,
            k.REFERENCED_COLUMN_NAME AS refCol, r.DELETE_RULE AS del, r.UPDATE_RULE AS upd,
            c.COLLATION_NAME AS coll, pc.COLLATION_NAME AS refColl
        FROM information_schema.KEY_COLUMN_USAGE k
        JOIN information_schema.REFERENTIAL_CONSTRAINTS r ON r.CONSTRAINT_SCHEMA = k.TABLE_SCHEMA
            AND r.TABLE_NAME = k.TABLE_NAME AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME
        JOIN information_schema.COLUMNS c ON c.TABLE_SCHEMA = k.TABLE_SCHEMA AND c.TABLE_NAME = k.TABLE_NAME
            AND c.COLUMN_NAME = k.COLUMN_NAME
        LEFT JOIN information_schema.COLUMNS pc ON pc.TABLE_SCHEMA = k.TABLE_SCHEMA
            AND pc.TABLE_NAME = k.REFERENCED_TABLE_NAME AND pc.COLUMN_NAME = k.REFERENCED_COLUMN_NAME
        WHERE k.TABLE_SCHEMA = DATABASE() AND k.REFERENCED_TABLE_NAME IS NOT NULL AND c.COLLATION_NAME IS NOT NULL
        ORDER BY k.TABLE_NAME, k.CONSTRAINT_NAME, k.ORDINAL_POSITION]]) or {}
    local stale = {}
    for _, r in ipairs(rows) do
        if r.coll ~= target or r.refColl ~= target then stale[r.tbl .. '.' .. r.name] = true end
    end
    local keys, byName = {}, {}
    for _, r in ipairs(rows) do
        if (wanted[r.tbl] or wanted[r.ref]) and stale[r.tbl .. '.' .. r.name] then
            local id = r.tbl .. '.' .. r.name
            local k = byName[id]
            if not k then
                k = { tbl = r.tbl, name = r.name, cols = r.col, ref = r.ref, refCols = r.refCol, del = r.del, upd = r.upd }
                byName[id] = k
                keys[#keys + 1] = k
            else
                k.cols, k.refCols = k.cols .. ',' .. r.col, k.refCols .. ',' .. r.refCol
            end
        end
    end
    return keys
end

local function saveHeldKeys(keys)
    local lines = {}
    for _, k in ipairs(keys) do
        lines[#lines + 1] = table.concat({ k.tbl, k.name, k.cols, k.ref, k.refCols, k.del, k.upd }, '|')
    end
    if #lines > 0 then SetResourceKvp(HELD_KEYS_KVP, table.concat(lines, '\n')) else DeleteResourceKvp(HELD_KEYS_KVP) end
end

local function loadHeldKeys()
    local keys = {}
    for line in (GetResourceKvpString(HELD_KEYS_KVP) or ''):gmatch('[^\n]+') do
        local f = {}
        for part in line:gmatch('[^|]+') do f[#f + 1] = part end
        if #f == 7 then
            keys[#keys + 1] = { tbl = f[1], name = f[2], cols = f[3], ref = f[4], refCols = f[5], del = f[6], upd = f[7] }
        end
    end
    return keys
end

--- 042: every whip table sorts its text by TABLE_COLLATION (server/helpers.lua), as a new database makes it. One
--- ALTER a table: its default, and each text column that sorts another way, with its type, NULL, default and comment
--- as they are. A binary column keeps its own (a JSON column is one, on MariaDB). A foreign key that joins text (the
--- phone's numbers) is taken off first and put back after, as it was (HELD_KEYS_KVP). Answers false while a table
--- could not be changed or a key could not be put back: each is said, and the next start tries again.
---@return boolean
local function alignCollation()
    local target = TABLE_COLLATION
    local maria = tostring(MySQL.scalar.await('SELECT VERSION()') or ''):lower():find('mariadb', 1, true) ~= nil
    local wanted = {}
    for _, name in ipairs(WHIP_TABLES) do wanted[name] = true end

    -- The keys that join text: taken off (and written down first), whether or not their tables need it this time.
    local held = loadHeldKeys()
    local seen = {}
    for _, k in ipairs(held) do seen[k.tbl .. '.' .. k.name] = true end
    for _, k in ipairs(textKeys(wanted, target)) do
        if not seen[k.tbl .. '.' .. k.name] then held[#held + 1] = k; seen[k.tbl .. '.' .. k.name] = true end
    end
    saveHeldKeys(held)
    for _, k in ipairs(held) do
        if Migrations.has.constraint(k.tbl, k.name) then
            local ok, err = pcall(MySQL.query.await, ('ALTER TABLE `%s` DROP FOREIGN KEY `%s`'):format(k.tbl, k.name))
            if not ok then
                print(('[whip_core:migrations] 042: the key `%s` on `%s` could not be taken off: %s'):format(k.name, k.tbl, tostring(err)))
            end
        end
    end

    local tables = MySQL.query.await([[SELECT TABLE_NAME AS name, TABLE_COLLATION AS coll FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_TYPE = 'BASE TABLE' ORDER BY TABLE_NAME]]) or {}
    local changed, failed = 0, 0
    for _, t in ipairs(tables) do
        if wanted[t.name] then
            local cols = MySQL.query.await([[SELECT COLUMN_NAME AS name, COLUMN_TYPE AS `type`, IS_NULLABLE AS nullable,
                    COLUMN_DEFAULT AS def, EXTRA AS extra, COLUMN_COMMENT AS `comment`, CHARACTER_SET_NAME AS cs,
                    COLLATION_NAME AS coll
                FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?
                    AND COLLATION_NAME IS NOT NULL ORDER BY ORDINAL_POSITION]], { t.name }) or {}
            local parts, generated = {}, false
            for _, c in ipairs(cols) do
                if c.cs == 'utf8mb4' and c.coll ~= target and not c.coll:find('_bin$') then
                    local extra = tostring(c.extra or ''):upper()
                    if extra:find('VIRTUAL', 1, true) or extra:find('STORED', 1, true) or extra:find('PERSISTENT', 1, true) then
                        generated = true
                    end
                    local d = ('MODIFY `%s` %s CHARACTER SET utf8mb4 COLLATE %s %s'):format(c.name, c.type, target,
                        c.nullable == 'YES' and 'NULL' or 'NOT NULL')
                    -- MariaDB gives a default as SQL ('text', NULL); MySQL gives the value itself
                    if c.def ~= nil then d = d .. ' DEFAULT ' .. (maria and tostring(c.def) or sqlQuote(c.def)) end
                    if c.comment and c.comment ~= '' then d = d .. ' COMMENT ' .. sqlQuote(c.comment) end
                    parts[#parts + 1] = d
                end
            end
            if generated then
                print(('[whip_core:migrations] 042: `%s` has a generated text column: left as it is'):format(t.name))
            elseif t.coll ~= target or #parts > 0 then
                local sql = ('ALTER TABLE `%s` DEFAULT CHARACTER SET utf8mb4 COLLATE %s'):format(t.name, target)
                if #parts > 0 then sql = sql .. ', ' .. table.concat(parts, ', ') end
                local ok, err = pcall(MySQL.query.await, sql)
                if ok then
                    changed = changed + 1
                else
                    failed = failed + 1
                    print(('[whip_core:migrations] 042: `%s` could not be changed: %s'):format(t.name, tostring(err)))
                end
            end
        end
    end
    if changed > 0 then
        print(('[whip_core:migrations] 042: %d table(s) now sort their text by %s'):format(changed, target))
    end

    -- The keys back, as they were. One that will not go back stays written down and is tried again next start.
    local still = {}
    for _, k in ipairs(held) do
        if not Migrations.has.constraint(k.tbl, k.name) then
            local ok, err = pcall(MySQL.query.await, keySql(k))
            if not ok then
                still[#still + 1] = k
                print(('[whip_core:migrations] 042: the key `%s` on `%s` could not be put back (%s); by hand: %s')
                    :format(k.name, k.tbl, tostring(err), keySql(k)))
            end
        end
    end
    saveHeldKeys(still)
    return failed == 0 and #still == 0
end

---@type { id: string, note: string, statements: WhipMigrationStatement[]|nil, run: (fun(): boolean)|nil }[]
Migrations.list = {
    {
        id   = '022_containers_key',
        note = 'EnsureContainer: a container can be declared by key, so a stash a '
            .. 'resource makes at start is found again instead of made again. `key` names it; '
            .. '`declared` keeps the declaration EnsureContainer compares against. The CREATE in '
            .. 'server/containers.lua has both, so every statement skips on a fresh database.',
        statements = {
            { sql = 'ALTER TABLE `containers` ADD COLUMN `key` VARCHAR(100) DEFAULT NULL',
              unless = { column = { 'containers', 'key' } } },
            { sql = 'ALTER TABLE `containers` ADD COLUMN `declared` JSON DEFAULT NULL',
              unless = { column = { 'containers', 'declared' } } },
            { sql = 'ALTER TABLE `containers` ADD UNIQUE KEY `uq_container_key` (`key`)',
              unless = { index = { 'containers', 'uq_container_key' } } },
        },
    },
    {
        id   = '023_bank_closed_empty',
        note = 'A closed account holds nothing: CloseAccount read the balance and '
            .. 'then closed, and a deposit landing in between left money in an account no query shows. '
            .. 'As a CHECK, either order errors and rolls back. The CREATE in server/bank.lua has it, so '
            .. 'a fresh database skips this. A closed account that ALREADY holds money would make the '
            .. 'ALTER fail and halt start-up, so that is looked for first: it is said, the migration is '
            .. 'left unrecorded, and it is tried again at the next start.',
        run = function()
            if Migrations.has.constraint('bank_accounts', 'chk_closed_empty') then return true end
            local stuck = tonumber(MySQL.scalar.await(
                'SELECT COUNT(*) FROM `bank_accounts` WHERE `closedAt` IS NOT NULL AND `balance` <> 0')) or 0
            if stuck > 0 then
                print(('[whip_core:migrations] 023: %d closed bank account(s) still hold money. Empty or '
                    .. 'reopen them (closedAt = NULL); the rule is added at the first start with none.'):format(stuck))
                return false
            end
            MySQL.query.await('ALTER TABLE `bank_accounts` ADD CONSTRAINT `chk_closed_empty` '
                .. 'CHECK (`closedAt` IS NULL OR `balance` = 0)')
            return true
        end,
    },
    {
        id   = '024_activity_log_ts',
        note = 'The activity log prune finds old rows by `ts`; without an index that '
            .. 'was a full scan of the biggest table, held before anyone could join. The CREATE in '
            .. 'server/activity_log.lua has the key, so a fresh database skips this. On a big log the '
            .. 'ALTER takes a while, once.',
        statements = {
            { sql = 'ALTER TABLE `activity_log` ADD KEY `idx_al_ts` (`ts`)',
              unless = { index = { 'activity_log', 'idx_al_ts' } } },
        },
    },
    {
        id   = '025_job_roles_permissions_default',
        note = "job_roles.permissions loses its DEFAULT '{}': MySQL refuses a plain "
            .. 'default on a JSON column, so the CREATE in server/jobs.lua no longer has one, and this '
            .. 'makes an older database match. Jobs.createRole always writes the column. A column with '
            .. 'no default (a fresh database) skips it.',
        run = function()
            local current = MySQL.scalar.await(
                'SELECT `COLUMN_DEFAULT` FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() '
                .. "AND TABLE_NAME = 'job_roles' AND COLUMN_NAME = 'permissions'")
            if current == nil then return true end
            MySQL.query.await('ALTER TABLE `job_roles` ALTER COLUMN `permissions` DROP DEFAULT')
            return true
        end,
    },
    {
        id   = '026_containers_requirements',
        note = 'Who may open a container, in the doors\' shape: { jobs, onDuty, charIds, '
            .. 'items, ace }, so a police locker is one field on EnsureContainer instead of a lock, an '
            .. 'action, an event and a skipAccess open. The CREATE in server/containers.lua has the '
            .. 'column, so a fresh database skips this.',
        statements = {
            { sql = 'ALTER TABLE `containers` ADD COLUMN `requirements` JSON DEFAULT NULL',
              unless = { column = { 'containers', 'requirements' } } },
        },
    },
    {
        id   = '027_garages_resource',
        note = 'Which resource made a garage (CreateGarage), so its blip shows only while that resource '
            .. 'runs. NULL for an admin\'s or the config\'s: always shown. The CREATE in '
            .. 'server/garages.lua has the column, so a fresh database skips this.',
        statements = {
            { sql = 'ALTER TABLE `garages` ADD COLUMN `resource` VARCHAR(64) DEFAULT NULL',
              unless = { column = { 'garages', 'resource' } } },
        },
    },
    {
        id   = '028_director_card_providers',
        note = 'Which resource provided each of a scenario\'s cards when a person switched it on (the Director '
            .. 'API): the server brings it back by itself only from the same resources, so no '
            .. 'other resource can put its code inside a scenario someone approved. A `run`, not a statement: '
            .. 'the Director builds its tables after whip_core is up, AFTER migrations run, so on a fresh '
            .. 'database the table is not there yet (its CREATE in server/director/store.lua has the column).',
        run = function()
            if not Migrations.has.table('director_scenarios') then return true end
            if Migrations.has.column('director_scenarios', 'cardProviders') then return true end
            MySQL.query.await('ALTER TABLE `director_scenarios` ADD COLUMN `cardProviders` TEXT NULL')
            return true
        end,
    },
    {
        id   = '029_whip_power_into_whip_autos',
        note = 'whip_power merged into whip_autos, and its FMC stress test dropped. A '
            .. 'DATA migration, not a schema one: what was saved under whip_power\'s name is handed to '
            .. 'whip_autos, or it would be refused or lost. (1) The settings an admin saved on the Power page '
            .. '(whip_settings.owner): left behind, they would quietly fall back to config.lua. (2) Each '
            .. 'car\'s VehicleData keys whip_power owned (vehData\'s "@owners"): a key belongs to the resource '
            .. 'that first wrote it, so whip_autos writing turbo_mod would be refused. (3) Interaction '
            .. 'overrides on whip_power\'s actions (the turbo\'s "Bolt on Turbo"), whose keys carry the '
            .. 'resource\'s name. And FMC\'s leftovers come off every car: the fmc1-fmc10 gauges (and the '
            .. 'old fmc_seed) in vehStats and fmcDistances in vehData. FMC kits still in a pocket are '
            .. 'unknown items now, thrown away like any other. A fresh database has none of it, and every '
            .. 'step is a no-op.',
        run = function()
            -- EVERY STEP IS SAFE TO RUN AGAIN, so a step that fails does not halt start-up as a schema
            -- change must: it is said, the migration is left unrecorded (false), and the next start
            -- tries again from the top.
            local ok, err = pcall(function()
                -- (1) Saved settings. The two pages share no setting path, so nothing collides.
                MySQL.query.await("UPDATE `whip_settings` SET `owner` = 'whip_autos' WHERE `owner` = 'whip_power'")

                -- (3) Interaction overrides: 'act:whip_power:x' (a prompt, or a car part's '<part>#act:...'),
                -- and a radial's 'whip_power:x'. `\_` so the underscore is not LIKE's any-one-character.
                if Migrations.has.table('interaction_overrides') then
                    MySQL.query.await("UPDATE `interaction_overrides` SET `overrideKey` = "
                        .. "REPLACE(`overrideKey`, 'act:whip_power:', 'act:whip_autos:') "
                        .. "WHERE `overrideKey` LIKE '%act:whip\\_power:%'")
                    MySQL.query.await("UPDATE `interaction_overrides` SET `overrideKey` = "
                        .. "CONCAT('whip_autos:', SUBSTRING(`overrideKey`, 12)) "
                        .. "WHERE `kind` = 'radial' AND `overrideKey` LIKE 'whip\\_power:%'")
                end

                -- (2) and FMC: the cars, a row at a time, read and written as JSON here rather than with
                -- MariaDB's JSON functions (a "@owners" path needs quoting, and the blocks were written by
                -- json.encode). Only rows that mention either. A block that does not read as JSON is
                -- written back as it was.
                local rows = MySQL.query.await("SELECT `vehicleId`, `vehStats`, `vehData` FROM `vehicles` "
                    .. "WHERE `vehData` LIKE '%whip\\_power%' OR `vehData` LIKE '%fmcDistances%' "
                    .. "OR `vehStats` LIKE '%\"fmc%'") or {}
                local FMC_STATS = { 'fmc_seed' }
                for i = 1, 10 do FMC_STATS[#FMC_STATS + 1] = 'fmc' .. i end
                local changed = 0
                for _, r in ipairs(rows) do
                    local okData, data = pcall(json.decode, r.vehData or 'null')
                    local okStats, stats = pcall(json.decode, r.vehStats or 'null')
                    data = okData and type(data) == 'table' and data or nil
                    stats = okStats and type(stats) == 'table' and stats or nil
                    local touched = false
                    if data then
                        if data.fmcDistances ~= nil then data.fmcDistances = nil; touched = true end
                        local owners = data['@owners']
                        if type(owners) == 'table' then
                            if owners.fmcDistances ~= nil then owners.fmcDistances = nil; touched = true end
                            for key, who in pairs(owners) do
                                if who == 'whip_power' then owners[key] = 'whip_autos'; touched = true end
                            end
                            if next(owners) == nil then data['@owners'] = nil end
                        end
                    end
                    if stats then
                        for _, name in ipairs(FMC_STATS) do
                            if stats[name] ~= nil then stats[name] = nil; touched = true end
                        end
                    end
                    if touched then
                        local newData = r.vehData
                        if data then newData = next(data) ~= nil and json.encode(data) or nil end
                        MySQL.query.await('UPDATE `vehicles` SET `vehData` = ?, `vehStats` = ? WHERE `vehicleId` = ?', {
                            newData, stats and json.encode(stats) or r.vehStats, r.vehicleId,
                        })
                        changed = changed + 1
                    end
                end
                print(('[whip_core:migrations] 029: whip_power is whip_autos now: its saved settings and %d car(s) '
                    .. 'handed over, FMC taken off them'):format(changed))
            end)
            if not ok then
                print(('[whip_core:migrations] 029 stopped part way (%s); it runs again at the next start')
                    :format(tostring(err)))
                return false
            end
            return true
        end,
    },
    {
        id   = '030_shop_item_prices',
        note = 'A stocked shop prices per ITEM, not per shelf slot. '
            .. 'shop_item_prices is made by the CREATE in server/shops.lua; this copies the old per-slot '
            .. 'prices across, reading which item each priced slot held. An item on several slots at '
            .. 'different prices keeps the HIGHEST price it was for sale at (so no shop sells for less than '
            .. 'it asked), and is for sale if any of its slots was. A price on an empty slot priced nothing '
            .. 'and is left behind. shop_prices is kept, untouched, as the record of what the slots said. '
            .. 'A fresh database has no shop_prices, so this is a no-op there; INSERT IGNORE makes it safe '
            .. 'to run again.',
        run = function()
            if not Migrations.has.table('shop_prices') then return true end
            local ok, res = pcall(MySQL.query.await, [[
                INSERT IGNORE INTO `shop_item_prices` (`containerId`, `item`, `price`, `forSale`)
                SELECT p.`containerId`, ci.`item`,
                       COALESCE(MAX(CASE WHEN p.`forSale` = 1 THEN p.`price` END), MAX(p.`price`)),
                       MAX(p.`forSale`)
                FROM `shop_prices` p
                JOIN `container_inventory` ci ON ci.`containerId` = p.`containerId` AND ci.`slot` = p.`slot`
                GROUP BY p.`containerId`, ci.`item`
            ]])
            if not ok then
                print(('[whip_core:migrations] 030 could not copy the shelf prices (%s); it runs again at '
                    .. 'the next start, and until then stocked shops sell nothing'):format(tostring(res)))
                return false
            end
            local n = type(res) == 'table' and tonumber(res.affectedRows) or nil
            print(('[whip_core:migrations] 030: stocked shops price per item now (%s item price(s) carried over)')
                :format(n and tostring(n) or 'the'))
            return true
        end,
    },
    {
        id   = '031_activity_log_feed_indexes',
        note = 'The Item Log opens on everything that happened, filtered by what happened '
            .. 'or by which item: the newest rows of one event, or of one item, read off an index instead of '
            .. 'the whole month. The CREATE in server/activity_log.lua has both, so a fresh database skips '
            .. 'them. On a big log the first start after this takes a little longer while they are built.',
        statements = {
            { sql = 'ALTER TABLE `activity_log` ADD INDEX `idx_al_event` (`event`, `id`)',
              unless = { index = { 'activity_log', 'idx_al_event' } } },
            { sql = 'ALTER TABLE `activity_log` ADD INDEX `idx_al_item` (`itemKey`, `id`)',
              unless = { index = { 'activity_log', 'idx_al_item' } } },
        },
    },
    {
        id   = '032_property_stashes',
        note = 'A property\'s stashes: furniture that holds things, opened only by the '
            .. 'owner and the keyholders. A container says which property it belongs to (`propertyId`), and '
            .. 'a piece of furniture which container it is (`containerId`), so the two stay together through '
            .. 'every furniture save. The CREATEs in server/containers.lua and server/property_objects.lua '
            .. 'have both, so a fresh database skips this.',
        statements = {
            { sql = 'ALTER TABLE `containers` ADD COLUMN `propertyId` INT UNSIGNED DEFAULT NULL',
              unless = { column = { 'containers', 'propertyId' } } },
            { sql = 'ALTER TABLE `containers` ADD KEY `idx_container_property` (`propertyId`)',
              unless = { index = { 'containers', 'idx_container_property' } } },
            { sql = 'ALTER TABLE `property_objects` ADD COLUMN `containerId` INT UNSIGNED DEFAULT NULL',
              unless = { column = { 'property_objects', 'containerId' } } },
            { sql = 'ALTER TABLE `property_objects` ADD KEY `idx_pobj_container` (`containerId`)',
              unless = { index = { 'property_objects', 'idx_pobj_container' } } },
        },
    },
    {
        id   = '033_property_themes',
        note = 'A property\'s look: the theme its interior\'s resource offers that its '
            .. 'owner picked, kept through a sale. The CREATE in server/properties.lua has it, so a fresh '
            .. 'database skips this.',
        statements = {
            { sql = 'ALTER TABLE `properties` ADD COLUMN `theme` TINYINT UNSIGNED NULL AFTER `settings`',
              unless = { column = { 'properties', 'theme' } } },
        },
    },
    {
        id   = '034_vehicle_parked_reversed',
        note = 'Which way a car faced in its bay: one backed in comes out of a bay the '
            .. 'same way. The CREATE in server/vehicles.lua has it, so a fresh database skips this.',
        statements = {
            { sql = 'ALTER TABLE `vehicles` ADD COLUMN `parkedReversed` TINYINT NOT NULL DEFAULT 0 AFTER `heading`',
              unless = { column = { 'vehicles', 'parkedReversed' } } },
        },
    },
    {
        id   = '035_director_run_variant',
        note = 'Which variant of a scenario each run played (Multi Run Variants), for its run history. A `run`, '
            .. 'not a statement, as 028: the Director builds its tables after migrations run, so on a fresh '
            .. 'database the table is not there yet (its CREATE in server/director/store.lua has the column).',
        run = function()
            if not Migrations.has.table('director_runs') then return true end
            if Migrations.has.column('director_runs', 'variant') then return true end
            MySQL.query.await('ALTER TABLE `director_runs` ADD COLUMN `variant` VARCHAR(64) NULL')
            return true
        end,
    },
    {
        id   = '036_prop_categories_v2',
        note = 'Every prop in the game went into the furniture catalog (7c4408a01), sorted by 3D Clanker\'s rules; '
            .. 'v2 of those rules re-filed 1,423 of them (a fuel nozzle was in Games, the FIB building\'s walls in '
            .. 'Misc). The seed never re-files a row it already put in, so this moves them: each only while it is '
            .. 'still where v1 put it, so an admin\'s own move stands. The list is data/prop_category_moves_v2.csv. '
            .. 'A database that has not seeded them yet has none of these rows (the catalog seeds after migrations, '
            .. 'from server/prop_catalog_seed_world.lua, which has the v2 categories): nothing to do.',
        run = function()
            if not Migrations.has.table('prop_catalog') then return true end
            local src = LoadResourceFile(GetCurrentResourceName(), 'data/prop_category_moves_v2.csv')
            if not src then error('data/prop_category_moves_v2.csv is missing') end
            -- One statement per move (from, to): 80 of them, not 1,423.
            local byMove, order = {}, {}
            for line in src:gmatch('[^\r\n]+') do
                local model, from, to = line:match('^([%w_]+),([%w_]+),([%w_]+)$')
                if model and model ~= 'model' then
                    local k = from .. '>' .. to
                    if not byMove[k] then
                        byMove[k] = { from = from, to = to, models = {} }
                        order[#order + 1] = k
                    end
                    local list = byMove[k].models
                    list[#list + 1] = model
                end
            end
            local moved = 0
            for _, k in ipairs(order) do
                local m = byMove[k]
                for first = 1, #m.models, 500 do
                    local params, marks = { m.to, m.from }, {}
                    for i = first, math.min(first + 499, #m.models) do
                        params[#params + 1] = m.models[i]
                        marks[#marks + 1] = '?'
                    end
                    local res = MySQL.update.await(('UPDATE `prop_catalog` SET `category` = ? WHERE `category` = ? AND `model` IN (%s)')
                        :format(table.concat(marks, ',')), params)
                    moved = moved + (tonumber(res) or 0)
                end
            end
            print(('[whip_core:migrations] 036: %d prop(s) moved to their v2 category'):format(moved))
            return true
        end,
    },
    {
        id   = '037_prop_categories_v3',
        note = '3D Clanker rendered the first 1,500 prop icons and looked at every one: 303 were filed wrong by the '
            .. 'name rules (benches in Barriers, hand tools in Barriers, the hangar pieces in Clothing because of '
            .. '"hanger"). 295 move to the right category; 8 are not furniture at all (plain cubes, placeholder '
            .. 'blobs, decals) and come out of the furnisher, marked unavailable as /prop remove does. Each only '
            .. 'while it is still where v2 put it, so an admin\'s own move stands. The list is '
            .. 'data/prop_category_moves_v3.csv. A database that has not seeded them yet: nothing to do (the seed '
            .. 'has the v3 categories and leaves the 8 out).',
        run = function()
            if not Migrations.has.table('prop_catalog') then return true end
            local src = LoadResourceFile(GetCurrentResourceName(), 'data/prop_category_moves_v3.csv')
            if not src then error('data/prop_category_moves_v3.csv is missing') end
            -- One statement per move (from, to), as 036. 'hidden' is not a category: those are removed.
            local byMove, order = {}, {}
            for line in src:gmatch('[^\r\n]+') do
                local model, from, to = line:match('^([%w_]+),([%w_]+),([%w_]+)$')
                if model and model ~= 'model' then
                    local k = from .. '>' .. to
                    if not byMove[k] then
                        byMove[k] = { from = from, to = to, models = {} }
                        order[#order + 1] = k
                    end
                    local list = byMove[k].models
                    list[#list + 1] = model
                end
            end
            local moved, removed = 0, 0
            for _, k in ipairs(order) do
                local m = byMove[k]
                local marks = {}
                for i = 1, #m.models do marks[i] = '?' end
                local sql, params
                if m.to == 'hidden' then
                    sql = 'UPDATE `prop_catalog` SET `status` = \'unavailable\' WHERE `category` = ? AND `status` <> \'unavailable\' AND `model` IN (%s)'
                    params = { m.from }
                else
                    sql = 'UPDATE `prop_catalog` SET `category` = ? WHERE `category` = ? AND `model` IN (%s)'
                    params = { m.to, m.from }
                end
                for i = 1, #m.models do params[#params + 1] = m.models[i] end
                local n = tonumber(MySQL.update.await(sql:format(table.concat(marks, ',')), params)) or 0
                if m.to == 'hidden' then removed = removed + n else moved = moved + n end
            end
            print(('[whip_core:migrations] 037: %d prop(s) moved to their v3 category, %d taken out of the furnisher')
                :format(moved, removed))
            return true
        end,
    },
    {
        id   = '038_prop_categories_v4',
        note = 'The furnisher check on an Enhanced client found 962 catalog models the game does not have (608 '
            .. 'interior shell pieces, 202 subway parts, 89 cable meshes, 63 DLC props): 3D Clanker\'s v4 files them '
            .. 'hidden, so they come out of the furnisher (an admin\'s dev-mode client may have marked them '
            .. 'unavailable already). The list is data/prop_category_moves_v4.csv. A database that has not seeded '
            .. 'them yet: nothing to do (the seed leaves them out).',
        run = function()
            if not Migrations.has.table('prop_catalog') then return true end
            local moved, removed = movePropCategories('prop_category_moves_v4.csv')
            print(('[whip_core:migrations] 038: %d prop(s) moved, %d taken out of the furnisher'):format(moved, removed))
            return true
        end,
    },
    {
        id   = '039_prop_categories_v5',
        note = '3D Clanker looked at every icon of batches b02-b10 as at 037: 3,292 were filed wrong by the name rules '
            .. '(security panels in Misc, casino chips in Loot, hospital dividers in Medical). 3,031 move to the right '
            .. 'category; 261 are not furniture (light glow planes and rig helpers, decals, stand-ins, glass-only '
            .. 'parts) and come out of the furnisher. Each only while it is still where v4 left it. The list is '
            .. 'data/prop_category_moves_v5.csv. A database that has not seeded them yet: nothing to do.',
        run = function()
            if not Migrations.has.table('prop_catalog') then return true end
            local moved, removed = movePropCategories('prop_category_moves_v5.csv')
            print(('[whip_core:migrations] 039: %d prop(s) moved to their v5 category, %d taken out of the furnisher')
                :format(moved, removed))
            return true
        end,
    },
    {
        id   = '040_director_lore_columns',
        note = 'A lore character\'s picture, its framing, voice lines, hat and character-editor look were columns '
            .. 'the Director added to director_lore on its own at start-up, each one off if it could not be added. '
            .. 'They are in its CREATE now, and here for a table made before them. A `run`, as 035: on a fresh '
            .. 'database the table is not there yet.',
        run = function()
            if not Migrations.has.table('director_lore') then return true end
            local adds = {
                { 'picture',      'ALTER TABLE `director_lore` ADD COLUMN `picture` VARCHAR(255) NULL AFTER `notes`' },
                { 'pictureFrame', 'ALTER TABLE `director_lore` ADD COLUMN `pictureFrame` VARCHAR(32) NULL AFTER `picture`' },
                { 'voice',        'ALTER TABLE `director_lore` ADD COLUMN `voice` TEXT NULL' },
                { 'props',        'ALTER TABLE `director_lore` ADD COLUMN `props` VARCHAR(64) NULL' },
                { 'look',         'ALTER TABLE `director_lore` ADD COLUMN `look` TEXT NULL' },
            }
            for _, a in ipairs(adds) do
                if not Migrations.has.column('director_lore', a[1]) then MySQL.query.await(a[2]) end
            end
            return true
        end,
    },
    {
        id   = '041_vehicle_meta_on_off',
        note = 'Vehicle Adjustments (the Model storage page, grown categories): a model can have its trunk or its '
            .. 'glovebox off, or on where its category has it off. The CREATE in server/vehicles.lua has both, so a '
            .. 'fresh database skips this; the categories\' own table is new, made by its CREATE.',
        statements = {
            { sql = 'ALTER TABLE `vehicle_meta` ADD COLUMN `hasTrunk` TINYINT DEFAULT NULL',
              unless = { column = { 'vehicle_meta', 'hasTrunk' } } },
            { sql = 'ALTER TABLE `vehicle_meta` ADD COLUMN `hasGlovebox` TINYINT DEFAULT NULL',
              unless = { column = { 'vehicle_meta', 'hasGlovebox' } } },
        },
    },
    {
        id   = '042_one_collation',
        note = 'Every table sorts its text one way. The CREATEs named none, so each table took the database server\'s '
            .. 'default of the day: two kinds on one database, which cannot compare their text with each other, and a '
            .. 'different one again on MySQL. CreateTable (server/helpers.lua) names TABLE_COLLATION now; this brings '
            .. 'a table made before that to it (alignCollation, above). A table that already sorts that way is skipped.',
        run = alignCollation,
    },
    {
        id   = '043_job_and_furniture_keys',
        note = 'A job\'s roles and employees, and an employee\'s character, are tied to them by foreign keys (they '
            .. 'go with them), and a piece of furniture\'s stash to its container (gone, the piece holds nothing). The '
            .. 'CREATEs in server/jobs.lua and server/property_objects.lua have them. A row pointing at something '
            .. 'that is not there would make the key fail, so that is looked for first: it is said, that key waits, '
            .. 'and the migration is tried again at the next start.',
        run = function()
            local keys = {
                { 'job_roles',        'fk_role_job',       'jobId',       'jobs',       'jobId',       'CASCADE' },
                { 'job_employees',    'fk_employee_job',   'jobId',       'jobs',       'jobId',       'CASCADE' },
                { 'job_employees',    'fk_employee_char',  'charId',      'characters', 'charId',      'CASCADE' },
                { 'property_objects', 'fk_pobj_container', 'containerId', 'containers', 'containerId', 'SET NULL' },
            }
            local complete = true
            for _, k in ipairs(keys) do
                local tbl, name, col, ref, refCol, onDelete = table.unpack(k)
                if not Migrations.has.constraint(tbl, name) then
                    local stray = tonumber(MySQL.scalar.await(('SELECT COUNT(*) FROM `%s` c LEFT JOIN `%s` p ON p.`%s` = c.`%s` '
                        .. 'WHERE c.`%s` IS NOT NULL AND p.`%s` IS NULL'):format(tbl, ref, refCol, col, col, refCol))) or 0
                    if stray > 0 then
                        print(('[whip_core:migrations] 043: %d row(s) of `%s` name a `%s` that is not there (%s): the key '
                            .. '%s is added at the first start with none'):format(stray, tbl, ref, col, name))
                        complete = false
                    else
                        MySQL.query.await(('ALTER TABLE `%s` ADD CONSTRAINT `%s` FOREIGN KEY (`%s`) REFERENCES `%s` (`%s`) '
                            .. 'ON DELETE %s'):format(tbl, name, col, ref, refCol, onDelete))
                    end
                end
            end
            return complete
        end,
    },
    {
        id   = '044_vehicle_key_token',
        note = 'A car\'s locks (ChangeVehicleLocks): once changed, only keys cut since fit it, and that lasts through a '
            .. 'restart. NULL is a car whose locks were never changed, which every key of it fits. The CREATE in '
            .. 'server/vehicles.lua has it, so a fresh database skips this.',
        statements = {
            { sql = 'ALTER TABLE `vehicles` ADD COLUMN `keyToken` VARCHAR(24) DEFAULT NULL AFTER `gloveboxMaxWeight`',
              unless = { column = { 'vehicles', 'keyToken' } } },
        },
    },
    {
        id   = '045_containers_reach',
        note = 'How far a container\'s prop reaches out from its spot, so its open range is counted from its edge, '
            .. 'where its prompt is: a large crate opens from its side. NULL is from its spot, as before. The CREATE '
            .. 'in server/containers.lua has it, so a fresh database skips this.',
        statements = {
            { sql = 'ALTER TABLE `containers` ADD COLUMN `reach` FLOAT DEFAULT NULL AFTER `prop`',
              unless = { column = { 'containers', 'reach' } } },
        },
    },
    {
        id   = '046_vehicle_reservation',
        note = 'A resource can hold an owned car against retrieval, spawning, transfer and deletion while it runs. '
            .. 'The CREATE in server/vehicles.lua has the reservation column, so a fresh database skips this.',
        statements = {
            { sql = 'ALTER TABLE `vehicles` ADD COLUMN `reservation` VARCHAR(191) DEFAULT NULL',
              unless = { column = { 'vehicles', 'reservation' } } },
        },
    },
}

-- ============================================
-- Probes (for guards and `run` functions)
-- ============================================

local function tableExists(name)
    return (MySQL.scalar.await(
        'SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?',
        { name }) or 0) > 0
end

local function constraintExists(tbl, name)
    return (MySQL.scalar.await(
        'SELECT COUNT(*) FROM information_schema.TABLE_CONSTRAINTS WHERE CONSTRAINT_SCHEMA = DATABASE() AND TABLE_NAME = ? AND CONSTRAINT_NAME = ?',
        { tbl, name }) or 0) > 0
end

local function indexExists(tbl, name)
    return (MySQL.scalar.await(
        'SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND INDEX_NAME = ?',
        { tbl, name }) or 0) > 0
end

local function columnExists(tbl, col)
    return (MySQL.scalar.await(
        'SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?',
        { tbl, col }) or 0) > 0
end

--- For a migration's `run` function: `Migrations.has.column('vehicles', 'colour')`, and so on.
Migrations.has = {
    table      = tableExists,
    constraint = constraintExists,
    index      = indexExists,
    column     = columnExists,
}

--- Does the thing a statement's `unless` / `onlyIf` names exist?
---@param guard WhipMigrationGuard
---@return boolean
local function guardExists(guard)
    if guard.index      then return indexExists(guard.index[1], guard.index[2]) end
    if guard.column     then return columnExists(guard.column[1], guard.column[2]) end
    if guard.constraint then return constraintExists(guard.constraint[1], guard.constraint[2]) end
    error('a migration guard names nothing (index, column or constraint)')
end

-- ============================================
-- Runner
-- ============================================

local function ensureMigrationsTable()
    return CreateTable('schema_migrations', [[
        CREATE TABLE IF NOT EXISTS `schema_migrations` (
            `id`        VARCHAR(64) NOT NULL,
            `appliedAt` TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
end

---@return table<string, boolean>|nil applied  nil when the read failed
local function loadApplied()
    local applied = {}
    local ok, rows = pcall(MySQL.query.await, 'SELECT `id` FROM `schema_migrations`')
    if not ok then
        print(('[whip_core:migrations] could not read schema_migrations: %s'):format(tostring(rows)))
        return nil
    end
    for _, row in ipairs(rows or {}) do
        applied[row.id] = true
    end
    return applied
end

--- One migration's statements (each skipped when its guard says the change is there), then its `run`.
---@return any failed  the error, or nil
---@return boolean incomplete  `run` said not everything applied (left unrecorded, retried next start)
local function applyMigration(migration)
    for _, statement in ipairs(migration.statements or {}) do
        local sql, skip = statement, false
        if type(statement) == 'table' then
            sql = statement.sql
            local okGuard, why = pcall(function()
                if statement.unless and guardExists(statement.unless) then return true end
                if statement.onlyIf and not guardExists(statement.onlyIf) then return true end
                return false
            end)
            if not okGuard then return why, false end
            skip = why
        end
        if not skip then
            local ok, err = pcall(MySQL.query.await, sql)
            if not ok then return err, false end
        end
    end

    -- A migration may instead supply `run`, for anything that has to LOOK at the database
    -- before deciding what to do (Migrations.has.* probe it).
    --
    -- `run` may return false to mean "did what I could, but not everything applied". That
    -- is NOT a failure — later migrations still run — but the migration is left unrecorded
    -- so it is retried on the next start.
    if migration.run then
        local ok, result = pcall(migration.run)
        if not ok then return result, false end
        if result == false then return nil, true end
    end
    return nil, false
end

--- Is the database new, none of whip's tables made in it yet? Asked before start-up makes them
--- (server/player_lifecycle.lua). Nil when it could not be asked: treated as not new, so nothing is skipped.
---@return boolean|nil
function Migrations.isNewDatabase()
    local ok, n = pcall(MySQL.scalar.await, [[SELECT COUNT(*) FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME IN ('users', 'characters', 'schema_migrations')]])
    if not ok then return nil end
    return (tonumber(n) or 0) == 0
end

--- Record migrations as done without running them: their tables were just made complete. `ids` are as recorded.
---@param ids string[]
---@return boolean
local function recordDone(ids)
    if #ids == 0 then return true end
    local marks = {}
    for i = 1, #ids do marks[i] = '(?)' end
    local ok, err = pcall(MySQL.query.await,
        'INSERT IGNORE INTO `schema_migrations` (`id`) VALUES ' .. table.concat(marks, ', '), ids)
    if not ok then
        print(('[whip_core:migrations] could not record the new tables\' updates as done (%s): they run, and change '
            .. 'nothing, at the next start'):format(tostring(err)))
    end
    return ok
end

--- Apply any migrations this database has not seen.
--- Stops at the first failure rather than continuing — a later migration may depend on an
--- earlier one, so applying them out of order is worse than not applying them at all.
--- `newDatabase` (Migrations.isNewDatabase, asked before the tables were made): every table was made complete just
--- now, so the list is recorded as done, not run.
---@param newDatabase boolean|nil
---@return boolean allApplied
function Migrations.run(newDatabase)
    if not ensureMigrationsTable() then return false end

    if newDatabase then
        local ids = {}
        for i, m in ipairs(Migrations.list) do ids[i] = m.id end
        recordDone(ids)
        print('[whip_core] new database: every table made')
        return true
    end
    if #Migrations.list == 0 then return true end

    -- A failed read is not "nothing applied": that would re-run every migration on a database
    -- that already has them.
    local applied = loadApplied()
    if not applied then return false end
    local ranCount = 0

    -- Counted from 1, whatever their ids: what this database is about to be given.
    local pending = {}
    for _, migration in ipairs(Migrations.list) do
        if not applied[migration.id] then pending[#pending + 1] = migration end
    end
    if #pending == 0 then return true end
    print(('[whip_core:migrations] updating the database: %d change(s)'):format(#pending))

    for n, migration in ipairs(pending) do
        print(('[whip_core:migrations] (%d/%d) %s'):format(n, #pending, migration.id))

        local failed, incomplete = applyMigration(migration)

        if failed then
            print(('[whip_core:migrations] FAILED %s: %s'):format(migration.id, tostring(failed)))
            print('[whip_core:migrations] halting — later migrations may depend on this one')
            return false
        end

        if incomplete then
            print(('[whip_core:migrations] %s not recorded — it will run again next start')
                :format(migration.id))
        else
            local recorded = pcall(MySQL.query.await,
                'INSERT INTO `schema_migrations` (`id`) VALUES (?)', { migration.id })
            if not recorded then
                print(('[whip_core:migrations] WARNING: %s applied but could not be recorded — it will re-run next start')
                    :format(migration.id))
            end
            ranCount = ranCount + 1
        end
    end

    if ranCount == #pending then
        print(('[whip_core:migrations] database up to date (%d change(s))'):format(ranCount))
    else
        print(('[whip_core:migrations] %d of %d change(s) applied; the rest are tried again at the next start')
            :format(ranCount, #pending))
    end
    return true
end

-- ============================================
-- EnsureTable: the same builder for a resource's own tables
-- ============================================

--- A table of your resource's own, built the way whip_core builds its own: `createSql`, a CREATE TABLE IF NOT EXISTS
--- with the table complete, on a database that has none; then `migrations`, the changes since, each run once per
--- database and recorded as '<resource>:<id>' in schema_migrations. The CREATE already has every change, so the call
--- that makes the table records its migrations as done without running them; on a table made before a change, each
--- statement says what it is about and is skipped when that is there:
---     { id = '002_note', statements = { { sql = 'ALTER TABLE `mycafe_orders` ADD COLUMN `note` VARCHAR(200) NULL',
---                                         unless = { column = { 'mycafe_orders', 'note' } } } } }
--- (or `onlyIf`, or a `run` function that looks first). The list is append only, in order. Answers true, or false and
--- why: the first migration that failed, the ones after it left for the next start.
exports('EnsureTable', function(name, createSql, migrations)
    local owner = Registry.caller()   -- first, before anything can yield
    if type(name) ~= 'string' or #name > 64 or not name:match('^[%w_]+$') then
        return false, 'a table name is letters, digits and _ (64 at most)'
    end
    if type(createSql) ~= 'string' or not createSql:upper():find('CREATE TABLE IF NOT EXISTS', 1, true) then
        return false, 'createSql is one CREATE TABLE IF NOT EXISTS statement'
    end
    if migrations ~= nil and type(migrations) ~= 'table' then return false, 'migrations is a list' end
    for i, m in ipairs(migrations or {}) do
        if type(m) ~= 'table' or type(m.id) ~= 'string' or m.id == '' then
            return false, ('migration %d needs an id'):format(i)
        end
        if #owner + 1 + #m.id > 64 then
            return false, ('migration "%s": "%s:%s" is longer than 64'):format(m.id, owner, m.id)
        end
    end
    if not WaitForCoreReady() then return false, NOT_READY end

    -- Made by this call: its CREATE has every change, so the migrations are recorded as done, not run.
    local existed = tableExists(name)
    if not CreateTable(name, createSql) then
        return false, ('could not create `%s`: the server console says why'):format(name)
    end
    if not migrations or #migrations == 0 then return true end
    if not ensureMigrationsTable() then return false, 'could not make the migrations record' end
    if not existed then
        local ids = {}
        for i, m in ipairs(migrations) do ids[i] = owner .. ':' .. m.id end
        recordDone(ids)
        return true
    end
    local applied = loadApplied()
    if not applied then return false, 'could not read the migrations record' end
    local pending = {}
    for _, m in ipairs(migrations) do
        if not applied[owner .. ':' .. m.id] then pending[#pending + 1] = m end
    end
    for n, m in ipairs(pending) do
        print(('[whip_core:migrations] %s: (%d/%d) %s'):format(owner, n, #pending, m.id))
        local failed, incomplete = applyMigration(m)
        if failed then
            print(('[whip_core:migrations] %s: FAILED %s: %s (the ones after it wait)'):format(owner, m.id, tostring(failed)))
            return false, ('migration "%s" failed: %s'):format(m.id, tostring(failed))
        end
        if not incomplete then
            pcall(MySQL.query.await, 'INSERT INTO `schema_migrations` (`id`) VALUES (?)', { owner .. ':' .. m.id })
        end
    end
    return true
end)
