-- ============================================
-- Director — the store: scenarios, their revisions, and what happened in every run
-- ============================================
--
-- Six tables, built and read by the Director ITSELF, after whip_core is up, and never able to stop
-- whip from starting: a failure here switches the Director off and says why, and the rest of whip
-- boots.
--
--   director_scenarios      one row per scenario: its key, name, who made and last changed it,
--                           status (draft / active / disabled), the draft's revision and the active one
--   director_revisions      every saved revision's document, kept (History restores one); the active
--                           revision is never changed, only a newer one saved
--   director_runs           one row per run: scenario, revision, test or not, outcome, how long, paid
--   director_run_players    who was in it, and how it ended for them
--   director_run_events     "who interacted": what each player did in a run (newest 200 per run)
--   director_takes          cars' recorded drives (server/director/takes.lua)
--
-- SAVES ARE REVISION-CHECKED: a save names the revision it was made from, and one that someone else
-- has saved past answers false, 'changed by <name>' (one shared draft per scenario). The check holds
-- in the database too: a revision's key is (scenario, rev), so two saves of the same revision cannot
-- both land. Scenario writes are admin actions and answer at once; run history is sent without
-- waiting, so a slow database never holds a run up.

DirectorStore = { ready = false }

local MAX_DOC = 512 * 1024
-- With variants (each a copy of the job): about four seconds down at 217 ms ping, inside a callback's ten.
local MAX_DOC_VARIANTS = 1024 * 1024
local KEEP_EVENTS = 200
local KEEP_DAYS = 90

local scenarios = {}   -- [key] = row (a cache of director_scenarios)
local saving = {}      -- [key] = true while a save is with the database
local summaries = {}   -- [key] = what its DRAFT says about itself (DirectorStore.summarize), for the API

local function say(fmt, ...) print(('[whip_core:director] ' .. fmt):format(...)) end

local q = DirectorKit.query
local cut = DirectorKit.cut   -- (text to a column's length, never half a character: the database refuses that)

-- ============================================
-- Tables
-- ============================================

function DirectorStore.ensureTables()
    local ok = CreateTable('director_scenarios', [[
        CREATE TABLE IF NOT EXISTS `director_scenarios` (
            `id`            INT UNSIGNED NOT NULL AUTO_INCREMENT,
            `key`           VARCHAR(64)  NOT NULL,
            `name`          VARCHAR(80)  NOT NULL,
            `description`   VARCHAR(500) NULL,
            `status`        VARCHAR(10)  NOT NULL DEFAULT 'draft',
            `source`        VARCHAR(80)  NOT NULL DEFAULT 'db',
            `draftRev`      INT UNSIGNED NOT NULL DEFAULT 0,
            `activeRev`     INT UNSIGNED NULL,
            `createdBy`     INT UNSIGNED NULL,
            `createdByName` VARCHAR(80)  NULL,
            `createdAt`     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `updatedBy`     INT UNSIGNED NULL,
            `updatedByName` VARCHAR(80)  NULL,
            `updatedAt`     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `deletedAt`     TIMESTAMP    NULL,
            `cardProviders` TEXT         NULL,
            PRIMARY KEY (`id`),
            UNIQUE KEY `uq_director_key` (`key`)
        )
    ]])
    ok = CreateTable('director_revisions', [[
        CREATE TABLE IF NOT EXISTS `director_revisions` (
            `scenarioId`   INT UNSIGNED NOT NULL,
            `rev`          INT UNSIGNED NOT NULL,
            `doc`          MEDIUMTEXT   NOT NULL,
            `hash`         INT UNSIGNED NULL,
            `editedBy`     INT UNSIGNED NULL,
            `editedByName` VARCHAR(80)  NULL,
            `note`         VARCHAR(200) NULL,
            `createdAt`    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`scenarioId`, `rev`),
            CONSTRAINT `fk_director_rev_scenario` FOREIGN KEY (`scenarioId`)
                REFERENCES `director_scenarios` (`id`) ON DELETE CASCADE
        )
    ]]) and ok
    ok = CreateTable('director_runs', [[
        CREATE TABLE IF NOT EXISTS `director_runs` (
            `id`         INT UNSIGNED NOT NULL,
            `scenarioId` INT UNSIGNED NOT NULL,
            `rev`        INT UNSIGNED NOT NULL,
            `test`       TINYINT(1)   NOT NULL DEFAULT 0,
            `startedBy`  INT UNSIGNED NULL,
            `startedAt`  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `endedAt`    TIMESTAMP    NULL,
            `outcome`    VARCHAR(12)  NOT NULL DEFAULT 'running',
            `reason`     VARCHAR(200) NULL,
            `faultNode`  VARCHAR(64)  NULL,
            `durationS`  INT UNSIGNED NULL,
            `payout`     INT UNSIGNED NOT NULL DEFAULT 0,
            `variant`    VARCHAR(64)  NULL,
            PRIMARY KEY (`id`),
            KEY `ix_director_runs_scenario` (`scenarioId`, `startedAt`),
            CONSTRAINT `fk_director_run_scenario` FOREIGN KEY (`scenarioId`)
                REFERENCES `director_scenarios` (`id`) ON DELETE CASCADE
        )
    ]]) and ok
    ok = CreateTable('director_run_players', [[
        CREATE TABLE IF NOT EXISTS `director_run_players` (
            `runId`    INT UNSIGNED NOT NULL,
            `charId`   INT UNSIGNED NOT NULL,
            `userId`   INT UNSIGNED NULL,
            `name`     VARCHAR(80)  NULL,
            `joinedAt` TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `outcome`  VARCHAR(12)  NULL,
            PRIMARY KEY (`runId`, `charId`),
            KEY `ix_director_players_char` (`charId`),
            CONSTRAINT `fk_director_player_run` FOREIGN KEY (`runId`)
                REFERENCES `director_runs` (`id`) ON DELETE CASCADE
        )
    ]]) and ok
    ok = CreateTable('director_run_events', [[
        CREATE TABLE IF NOT EXISTS `director_run_events` (
            `id`     BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            `runId`  INT UNSIGNED NOT NULL,
            `at`     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `nodeId` VARCHAR(64)  NULL,
            `kind`   VARCHAR(30)  NOT NULL,
            `charId` INT UNSIGNED NULL,
            `detail` VARCHAR(200) NULL,
            PRIMARY KEY (`id`),
            KEY `ix_director_events_run` (`runId`),
            CONSTRAINT `fk_director_event_run` FOREIGN KEY (`runId`)
                REFERENCES `director_runs` (`id`) ON DELETE CASCADE
        )
    ]]) and ok
    -- A car's recorded drives (server/director/takes.lua): kept beside the scenario, not in it (a take is tens of
    -- KB), named by id from the car's def.takes. Kept when a take is taken off a car (an older revision may name it),
    -- till no live scenario names it and it is older than the history (DirectorTakes.prune, at loadAll).
    ok = CreateTable('director_takes', [[
        CREATE TABLE IF NOT EXISTS `director_takes` (
            `id`          INT UNSIGNED NOT NULL AUTO_INCREMENT,
            `scenarioKey` VARCHAR(64)  NOT NULL,
            `worldId`     VARCHAR(64)  NOT NULL,
            `model`       VARCHAR(64)  NOT NULL,
            `lengthMs`    INT UNSIGNED NOT NULL,
            `samples`     INT UNSIGNED NOT NULL,
            `data`        MEDIUMTEXT   NOT NULL,
            `madeBy`      INT UNSIGNED NULL,
            `madeByName`  VARCHAR(80)  NULL,
            `createdAt`   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            KEY `ix_director_takes_scenario` (`scenarioKey`)
        )
    ]]) and ok
    return ok
end

-- ============================================
-- Loading
-- ============================================

local function remember(row)
    scenarios[row.key] = row
end

--- What a scenario document says about itself, for other resources (the Director API): kept in
--- memory for every draft, so asking about a scenario never waits on the database. Plain data only.
---@return table  { kinds, where, startMode, cards = {types}, world = { {id, kind, layer, label, coords} },
---                vars = { {id, type, default} } }
function DirectorStore.summarize(doc)
    doc = type(doc) == 'table' and doc or {}
    local settings = type(doc.settings) == 'table' and doc.settings or {}
    local start = type(settings.start) == 'table' and settings.start or {}
    -- Every variant's cards and things (its shared things once).
    local cards, seen = {}, {}
    local world, had = {}, {}
    local variants = {}
    for i, v in ipairs(DirectorGraph.variantsOf(doc)) do
        variants[i] = { id = v.id, name = (type(v.name) == 'string' and v.name ~= '') and v.name or ('Variant ' .. i) }
        local d = v.doc
        for _, n in ipairs(type(d.nodes) == 'table' and d.nodes or {}) do
            local t = type(n) == 'table' and n.type
            if type(t) == 'string' and not seen[t] then seen[t] = true cards[#cards + 1] = t end
        end
        for _, w in ipairs(type(d.world) == 'table' and d.world or {}) do
            if type(w) == 'table' and type(w.id) == 'string' and not had[w.id] then
                had[w.id] = true
                local c = type(w.def) == 'table' and type(w.def.coords) == 'table' and w.def.coords or nil
                world[#world + 1] = { id = w.id, kind = w.kind, layer = w.layer, label = type(w.label) == 'string' and w.label or nil,
                                      coords = c and tonumber(c.x) and { x = tonumber(c.x), y = tonumber(c.y), z = tonumber(c.z) } or nil }
            end
        end
    end
    table.sort(cards)
    local vars = {}
    for _, v in ipairs(type(doc.vars) == 'table' and doc.vars or {}) do
        if type(v) == 'table' and type(v.id) == 'string' then
            local d = v.default
            vars[#vars + 1] = { id = v.id, type = v.type, default = (type(d) == 'string' or type(d) == 'number' or type(d) == 'boolean') and d or nil }
        end
    end
    return { name = type(doc.name) == 'string' and doc.name or nil,
             description = type(doc.description) == 'string' and doc.description or nil,
             kinds = (DirectorGraph.kindsOf(settings)), where = DirectorGraph.whereOf(doc),
             startMode = type(start.mode) == 'string' and start.mode or 'admin', cards = cards, world = world, vars = vars,
             variants = variants }
end

--- The summary of a scenario's draft (nil: no such scenario, or its draft could not be read at start).
function DirectorStore.summary(key)
    return summaries[key]
end

--- Read every scenario (not deleted), tidy the history, and answer the highest run id ever used.
--- Answers false and why when the database would not answer.
---@return number|false maxRunId
---@return string|nil why
function DirectorStore.loadAll()
    local rows, err = q('SELECT * FROM `director_scenarios` WHERE `deletedAt` IS NULL')
    if not rows then return false, err end
    scenarios = {}
    for _, r in ipairs(rows) do remember(r) end

    -- A run the server stopped in the middle of (txAdmin restarts with no stop handler) is over.
    q("UPDATE `director_runs` SET `outcome` = 'aborted', `reason` = 'the server restarted', `endedAt` = NOW() WHERE `outcome` = 'running'")
    q("UPDATE `director_run_players` SET `outcome` = 'aborted' WHERE `outcome` IS NULL")
    -- History is kept for KEEP_DAYS (its players and events go with it).
    q(('DELETE FROM `director_runs` WHERE `startedAt` < NOW() - INTERVAL %d DAY'):format(KEEP_DAYS))

    local m = q('SELECT COALESCE(MAX(`id`), 0) AS `m` FROM `director_runs`')
    local maxRun = m and m[1] and tonumber(m[1].m) or 0

    -- Every draft's summary (DirectorStore.summarize), in one read with the switched-on revisions. One that cannot be
    -- read is left out (GetScenario then says less about it), never a reason to stop.
    summaries = {}
    local docs = q([[SELECT s.`key`, s.`draftRev`, r.`rev`, r.`doc` FROM `director_scenarios` s
                       JOIN `director_revisions` r ON r.`scenarioId` = s.`id` AND (r.`rev` = s.`draftRev` OR r.`rev` = s.`activeRev`)
                      WHERE s.`deletedAt` IS NULL]])
    -- The recorded drives they name: the rest go once older than the history (DirectorTakes.prune). Only when every
    -- one of them was read: a document that could not be would lose its takes.
    local named, readAll = {}, docs ~= nil
    for _, d in ipairs(docs or {}) do
        local ok, doc = pcall(json.decode, d.doc)
        if ok and type(doc) == 'table' then
            if tonumber(d.rev) == tonumber(d.draftRev) and scenarios[d.key] then summaries[d.key] = DirectorStore.summarize(doc) end
            DirectorTakes.idsOfDoc(doc, named)
        else
            readAll = false
        end
    end
    if readAll then CreateThread(function() DirectorTakes.prune(named, KEEP_DAYS) end) end
    DirectorStore.ready = true
    return maxRun
end

-- ============================================
-- Reading
-- ============================================

--- A scenario row as anyone may read it.
local function view(r)
    return { id = r.id, key = r.key, name = r.name, description = r.description, status = r.status,
             source = r.source, draftRev = r.draftRev, activeRev = r.activeRev,
             createdBy = r.createdByName, createdAt = r.createdAt, updatedBy = r.updatedByName, updatedAt = r.updatedAt }
end

--- Who made a scenario: their account (userId; nil for the server or a pack) and the name they had then.
function DirectorStore.creatorOf(key)
    local r = scenarios[key]
    if not r then return nil, nil end
    return r.createdBy, r.createdByName
end

--- The database ids of the scenarios with these keys (one not stored is left out): the Overview's filter.
function DirectorStore.idsOf(keys)
    local out = {}
    for _, key in ipairs(keys) do
        local r = scenarios[key]
        if r then out[#out + 1] = r.id end
    end
    return out
end

--- The database ids of every scenario `userId` made (a deleted one is not counted).
function DirectorStore.madeBy(userId)
    local out = {}
    for _, r in pairs(scenarios) do
        if r.createdBy == userId then out[#out + 1] = r.id end
    end
    return out
end

function DirectorStore.get(key)
    local r = scenarios[key]
    return r and view(r) or nil
end

function DirectorStore.list()
    local out = {}
    for _, r in pairs(scenarios) do out[#out + 1] = view(r) end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

--- A revision's document, decoded. Answers the doc, or nil and why.
function DirectorStore.revision(key, rev)
    local r = scenarios[key]
    if not r then return nil, 'no such scenario' end
    rev = math.tointeger(tonumber(rev) or r.draftRev)
    local rows, err = q('SELECT `doc` FROM `director_revisions` WHERE `scenarioId` = ? AND `rev` = ?', { r.id, rev })
    if not rows then return nil, err end
    if not rows[1] then return nil, 'no such revision' end
    local ok, doc = pcall(json.decode, rows[1].doc)
    if not ok or type(doc) ~= 'table' then return nil, 'that revision cannot be read' end
    -- Read the one way (doc.lua): one from before the Director was rebuilt is refused here, for everyone that asks.
    local loaded, why = DirectorDoc.load(doc)
    if not loaded then return nil, why end
    return loaded, rev
end

--- The hub's numbers: [scenarioId] = { runs, succeeded, aborted, lastAt }, test runs left out.
--- `aborted` (called off, stopped, cut short by a restart) is neither a success nor a failure. Answers
--- an empty table when the database does not answer (the hub then shows no numbers, not an error).
function DirectorStore.stats()
    local rows = q([[SELECT `scenarioId`, COUNT(*) AS `runs`, SUM(`outcome` = 'succeeded') AS `ok`,
                            SUM(`outcome` = 'aborted') AS `off`, MAX(`startedAt`) AS `lastAt`
                     FROM `director_runs` WHERE `test` = 0 GROUP BY `scenarioId`]])
    local out = {}
    for _, r in ipairs(rows or {}) do
        out[tonumber(r.scenarioId)] = { runs = tonumber(r.runs) or 0, succeeded = tonumber(r.ok) or 0,
                                        aborted = tonumber(r.off) or 0, lastAt = r.lastAt }
    end
    return out
end

--- One scenario's numbers (the Director API's GetScenarioStats): { runs, succeeded, aborted, lastAt },
--- test runs left out, or nil and why when the database does not answer (never zeros for a failure).
function DirectorStore.statsOf(scenarioId)
    local rows, err = q([[SELECT COUNT(*) AS `runs`, SUM(`outcome` = 'succeeded') AS `ok`, SUM(`outcome` = 'aborted') AS `off`,
                                 MAX(`startedAt`) AS `lastAt`
                            FROM `director_runs` WHERE `test` = 0 AND `scenarioId` = ?]], { scenarioId })
    if not rows then return nil, 'The database did not answer: ' .. tostring(err) end
    local r = rows[1] or {}
    return { runs = tonumber(r.runs) or 0, succeeded = tonumber(r.ok) or 0, aborted = tonumber(r.off) or 0, lastAt = r.lastAt }
end

--- Revisions of a scenario, newest first: { rev, editedBy, createdAt, note }.
function DirectorStore.history(key, limit)
    local r = scenarios[key]
    if not r then return {} end
    local rows = q('SELECT `rev`, `editedByName`, `createdAt`, `note` FROM `director_revisions` WHERE `scenarioId` = ? ORDER BY `rev` DESC LIMIT ?',
        { r.id, math.tointeger(tonumber(limit) or 50) or 50 })
    local out = {}
    for _, x in ipairs(rows or {}) do out[#out + 1] = { rev = x.rev, editedBy = x.editedByName, createdAt = x.createdAt, note = x.note } end
    return out
end

-- ============================================
-- A scenario's detail tabs (the /whip Director section)
-- ============================================
--
-- Players, Runs and Interactions, read from the run history. Test runs are left out of Players
-- (a builder testing is not someone who played it) and shown, marked, in Runs. Every list is
-- bounded, newest first, and pages with `before` (an id: rows older than it).

local function int(v, default) return math.tointeger(tonumber(v)) or default end

--- Who has played it: one row per character. { charId, userId, name, account, times, succeeded,
--- lastAt, lastOutcome }
function DirectorStore.players(key, limit)
    local r = scenarios[key]
    if not r then return {} end
    local rows = q([[
        SELECT rp.`charId`, MAX(rp.`userId`) AS `userId`, MAX(rp.`name`) AS `name`, MAX(u.`name`) AS `account`,
               COUNT(*) AS `times`, SUM(rp.`outcome` = 'succeeded') AS `succeeded`, MAX(r.`startedAt`) AS `lastAt`,
               SUBSTRING_INDEX(GROUP_CONCAT(COALESCE(rp.`outcome`, 'running') ORDER BY r.`startedAt` DESC), ',', 1) AS `lastOutcome`
          FROM `director_run_players` rp
          JOIN `director_runs` r ON r.`id` = rp.`runId`
          LEFT JOIN `users` u ON u.`userId` = rp.`userId`
         WHERE r.`scenarioId` = ? AND r.`test` = 0
         GROUP BY rp.`charId`
         ORDER BY `lastAt` DESC
         LIMIT ?]], { r.id, int(limit, 100) })
    local out = {}
    for _, x in ipairs(rows or {}) do
        out[#out + 1] = { charId = tonumber(x.charId), userId = tonumber(x.userId), name = x.name, account = x.account,
                          times = tonumber(x.times) or 0, succeeded = tonumber(x.succeeded) or 0, lastAt = x.lastAt,
                          lastOutcome = x.lastOutcome }
    end
    return out
end

--- Its runs, newest first: { id, rev, test, startedAt, endedAt, outcome, reason, faultNode, durationS,
--- payout, players (names, comma separated) }. `before`: older than that run id (0: the newest).
function DirectorStore.runs(key, before, limit)
    local r = scenarios[key]
    if not r then return {} end
    before = int(before, 0)
    local rows = q([[
        SELECT r.`id`, r.`rev`, r.`test`, r.`startedAt`, r.`endedAt`, r.`outcome`, r.`reason`, r.`faultNode`,
               r.`durationS`, r.`payout`, r.`variant`,
               (SELECT GROUP_CONCAT(rp.`name` ORDER BY rp.`joinedAt` SEPARATOR ', ')
                  FROM `director_run_players` rp WHERE rp.`runId` = r.`id`) AS `players`
          FROM `director_runs` r
         WHERE r.`scenarioId` = ? AND (? = 0 OR r.`id` < ?)
         ORDER BY r.`id` DESC
         LIMIT ?]], { r.id, before, before, int(limit, 50) })
    local out = {}
    for _, x in ipairs(rows or {}) do
        out[#out + 1] = { id = tonumber(x.id), rev = tonumber(x.rev), test = x.test == 1 or x.test == true,
                          startedAt = x.startedAt, endedAt = x.endedAt, outcome = x.outcome, reason = x.reason,
                          faultNode = x.faultNode, durationS = tonumber(x.durationS), payout = tonumber(x.payout) or 0,
                          players = x.players, variant = x.variant }
    end
    return out
end

--- What players did in its runs ("who interacted"): { id, runId, at, nodeId, kind, charId, name,
--- detail }, newest first. `runId` (0: every run); `before`: older than that event id.
function DirectorStore.events(key, runId, before, limit)
    local r = scenarios[key]
    if not r then return {} end
    runId, before = int(runId, 0), int(before, 0)
    local rows = q([[
        SELECT e.`id`, e.`runId`, e.`at`, e.`nodeId`, e.`kind`, e.`charId`, e.`detail`,
               (SELECT rp.`name` FROM `director_run_players` rp
                 WHERE rp.`runId` = e.`runId` AND rp.`charId` = e.`charId` LIMIT 1) AS `name`
          FROM `director_run_events` e
          JOIN `director_runs` r ON r.`id` = e.`runId`
         WHERE r.`scenarioId` = ? AND (? = 0 OR e.`runId` = ?) AND (? = 0 OR e.`id` < ?)
         ORDER BY e.`id` DESC
         LIMIT ?]], { r.id, runId, runId, before, before, int(limit, 100) })
    local out = {}
    for _, x in ipairs(rows or {}) do
        out[#out + 1] = { id = tonumber(x.id), runId = tonumber(x.runId), at = x.at, nodeId = x.nodeId, kind = x.kind,
                          charId = tonumber(x.charId), name = x.name, detail = x.detail }
    end
    return out
end

--- A deleted scenario's key as it was made (DirectorStore.delete keeps a freed key behind the row's id).
local function keyAsMade(key)
    return type(key) == 'string' and (key:gsub('^~%d+~', '')) or key
end

--- EVERY SCENARIO AT ONCE, over the last `days` (the /whip Director section's Overview). Test runs are left out of
--- every number, and shown, marked, among the recent runs. A deleted scenario's runs still count, under its name.
---   totals    { runs, succeeded, failed, faulted, calledOff, paid, avgS, players }
---   days      { { day = 'YYYY-MM-DD', runs, succeeded, failed, calledOff } }, oldest first, only days with runs
---   scenarios { { key, name, deleted, runs, succeeded, calledOff, paid, players } }, most run first
---   players   { { charId, name, account, times, succeeded, lastAt } }, the ten who played most
---   reasons   { { reason, n } }, why runs failed or went wrong most often
---   recent    { { id, key, name, deleted, rev, test, startedAt, outcome, reason, durationS, payout, players } }, newest first
--- `ids`: only those scenarios' runs (their database ids: idsOf, madeBy); nil for every scenario's.
--- Answers nil and why when the database does not answer.
function DirectorStore.overview(days, ids)
    days = math.max(1, math.min(KEEP_DAYS, int(days, 14)))
    -- The filter is whole numbers only, written into the query (an empty list matches no run).
    local only
    if ids then
        local list = {}
        for _, id in ipairs(ids) do
            local n = math.tointeger(tonumber(id))
            if n then list[#list + 1] = n end
        end
        only = ('r.`scenarioId` IN (%s)'):format(#list > 0 and table.concat(list, ',') or '0')
    end
    local since = 'r.`startedAt` >= NOW() - INTERVAL ? DAY' .. (only and ' AND ' .. only or '')
    local t, err = q(([[
        SELECT COUNT(*) AS `runs`, SUM(r.`outcome` = 'succeeded') AS `ok`, SUM(r.`outcome` = 'failed') AS `failed`,
               SUM(r.`outcome` = 'faulted') AS `faulted`, SUM(r.`outcome` = 'aborted') AS `off`, SUM(r.`payout`) AS `paid`,
               AVG(CASE WHEN r.`outcome` <> 'running' THEN r.`durationS` END) AS `avgS`
          FROM `director_runs` r WHERE r.`test` = 0 AND %s]]):format(since), { days })
    if not t then return nil, 'The database did not answer: ' .. tostring(err) end
    t = t[1] or {}
    local who = q(([[SELECT COUNT(DISTINCT rp.`charId`) AS `n` FROM `director_run_players` rp
                       JOIN `director_runs` r ON r.`id` = rp.`runId` WHERE r.`test` = 0 AND %s]]):format(since), { days })
    local totals = { runs = tonumber(t.runs) or 0, succeeded = tonumber(t.ok) or 0, failed = tonumber(t.failed) or 0,
                     faulted = tonumber(t.faulted) or 0, calledOff = tonumber(t.off) or 0, paid = tonumber(t.paid) or 0,
                     avgS = t.avgS and math.floor(tonumber(t.avgS) + 0.5) or nil,
                     players = who and who[1] and tonumber(who[1].n) or 0 }

    local out = { days = {}, scenarios = {}, players = {}, reasons = {}, recent = {}, totals = totals, period = days }
    -- The database's own today, as its days below are grouped: the page counts back from it, not from the viewer's
    -- clock (another time zone would put runs on the wrong day, or on none)
    local today = q("SELECT DATE_FORMAT(NOW(), '%Y-%m-%d') AS `today`")
    out.today = today and today[1] and today[1].today or nil
    for _, x in ipairs(q(([[
        SELECT DATE_FORMAT(r.`startedAt`, '%%Y-%%m-%%d') AS `day`, COUNT(*) AS `runs`, SUM(r.`outcome` = 'succeeded') AS `ok`,
               SUM(r.`outcome` IN ('failed', 'faulted')) AS `bad`, SUM(r.`outcome` = 'aborted') AS `off`
          FROM `director_runs` r WHERE r.`test` = 0 AND %s GROUP BY `day` ORDER BY `day`]]):format(since), { days }) or {}) do
        out.days[#out.days + 1] = { day = x.day, runs = tonumber(x.runs) or 0, succeeded = tonumber(x.ok) or 0,
                                    failed = tonumber(x.bad) or 0, calledOff = tonumber(x.off) or 0 }
    end
    for _, x in ipairs(q(([[
        SELECT s.`key`, s.`name`, s.`deletedAt` IS NOT NULL AS `gone`, COUNT(*) AS `runs`, SUM(r.`outcome` = 'succeeded') AS `ok`,
               SUM(r.`outcome` = 'aborted') AS `off`, SUM(r.`payout`) AS `paid`,
               (SELECT COUNT(DISTINCT rp.`charId`) FROM `director_run_players` rp JOIN `director_runs` r2 ON r2.`id` = rp.`runId`
                 WHERE r2.`scenarioId` = s.`id` AND r2.`test` = 0 AND r2.`startedAt` >= NOW() - INTERVAL ? DAY) AS `players`
          FROM `director_runs` r JOIN `director_scenarios` s ON s.`id` = r.`scenarioId`
         WHERE r.`test` = 0 AND %s GROUP BY s.`id` ORDER BY `runs` DESC LIMIT 50]]):format(since), { days, days }) or {}) do
        out.scenarios[#out.scenarios + 1] = { key = keyAsMade(x.key), name = x.name, deleted = x.gone == 1 or x.gone == true,
            runs = tonumber(x.runs) or 0, succeeded = tonumber(x.ok) or 0, calledOff = tonumber(x.off) or 0,
            paid = tonumber(x.paid) or 0, players = tonumber(x.players) or 0 }
    end
    for _, x in ipairs(q(([[
        SELECT rp.`charId`, MAX(rp.`name`) AS `name`, MAX(u.`name`) AS `account`, COUNT(*) AS `times`,
               SUM(rp.`outcome` = 'succeeded') AS `ok`, MAX(r.`startedAt`) AS `lastAt`
          FROM `director_run_players` rp JOIN `director_runs` r ON r.`id` = rp.`runId`
          LEFT JOIN `users` u ON u.`userId` = rp.`userId`
         WHERE r.`test` = 0 AND %s GROUP BY rp.`charId` ORDER BY `times` DESC, `lastAt` DESC LIMIT 10]]):format(since), { days }) or {}) do
        out.players[#out.players + 1] = { charId = tonumber(x.charId), name = x.name, account = x.account,
            times = tonumber(x.times) or 0, succeeded = tonumber(x.ok) or 0, lastAt = x.lastAt }
    end
    for _, x in ipairs(q(([[
        SELECT COALESCE(r.`reason`, '') AS `reason`, COUNT(*) AS `n` FROM `director_runs` r
         WHERE r.`test` = 0 AND r.`outcome` IN ('failed', 'faulted') AND %s GROUP BY `reason` ORDER BY `n` DESC LIMIT 6]]):format(since),
        { days }) or {}) do
        out.reasons[#out.reasons + 1] = { reason = x.reason, n = tonumber(x.n) or 0 }
    end
    for _, x in ipairs(q(([[
        SELECT r.`id`, s.`key`, s.`name`, s.`deletedAt` IS NOT NULL AS `gone`, r.`rev`, r.`test`, r.`startedAt`, r.`outcome`,
               r.`reason`, r.`durationS`, r.`payout`,
               (SELECT GROUP_CONCAT(rp.`name` ORDER BY rp.`joinedAt` SEPARATOR ', ')
                  FROM `director_run_players` rp WHERE rp.`runId` = r.`id`) AS `players`
          FROM `director_runs` r JOIN `director_scenarios` s ON s.`id` = r.`scenarioId`
         %s ORDER BY r.`id` DESC LIMIT 25]]):format(only and 'WHERE ' .. only or '')) or {}) do
        out.recent[#out.recent + 1] = { id = tonumber(x.id), key = keyAsMade(x.key), name = x.name,
            deleted = x.gone == 1 or x.gone == true, rev = tonumber(x.rev),
            test = x.test == 1 or x.test == true, startedAt = x.startedAt, outcome = x.outcome, reason = x.reason,
            durationS = tonumber(x.durationS), payout = tonumber(x.payout) or 0, players = x.players }
    end
    return out
end

-- ============================================
-- Writing a scenario (admin actions: they answer)
-- ============================================

local function who(by)
    local p = by and Players[by]
    if p then return p.userId, p.fullName end
    return nil, 'the server'
end

local function encode(doc)
    if type(doc) ~= 'table' then return nil, 'a scenario is a document (a table)' end
    if doc.format ~= DirectorDoc.FORMAT then return nil, ('a scenario is format %d'):format(DirectorDoc.FORMAT) end
    -- The editor's view of one variant (html/js/director/doc.js unpackDoc), never the scenario itself.
    if doc.variantOpen ~= nil then return nil, 'the editor sent half a scenario: save again' end
    local ok, s = pcall(json.encode, doc)
    if not ok or type(s) ~= 'string' then return nil, 'that scenario cannot be written down' end
    local most = (type(doc.variants) == 'table' and #doc.variants > 0) and MAX_DOC_VARIANTS or MAX_DOC
    if #s > most then return nil, ('a scenario is at most %d KB'):format(most // 1024) end
    return s
end

local function validKey(key)
    return type(key) == 'string' and #key >= 2 and #key <= 64 and key:match('^[%w_%-]+$') ~= nil
end

--- Make a new scenario from a document: answers its row, or false and why.
---@param by number|nil  the player making it (nil: the server)
---@param source string|nil  'db' (made here, the default) or 'pack:<resource>' (shipped: read-only)
function DirectorStore.create(key, name, doc, by, source)
    if not validKey(key) then return false, 'a scenario key is 2-64 letters, digits, _ and -' end
    if scenarios[key] then return false, 'there is already a scenario called ' .. key end
    if type(name) ~= 'string' or name == '' or #name > 80 then return false, 'a name is up to 80 characters' end
    -- A resource's name as FiveM allows it (letters, digits, _ - and .): the hub's own rule for one.
    source = type(source) == 'string' and source:match('^pack:[%w_%-%.]+$') and source or 'db'
    local s, why = encode(doc)
    if not s then return false, why end
    -- A shipped scenario deleted here keeps its key (DirectorStore.delete): said, not left to the unique key to refuse.
    local held = q('SELECT `source` FROM `director_scenarios` WHERE `key` = ?', { key })
    if not held then return false, DB_ERROR end
    if held[1] then
        local pack = type(held[1].source) == 'string' and held[1].source:match('^pack:(.+)$')
        if pack then return false, ('%s was shipped by %s and deleted here: its key is not used again'):format(key, pack) end
        return false, 'there is already a scenario called ' .. key
    end
    local userId, uname = who(by)
    local ok, id = pcall(MySQL.insert.await, [[
        INSERT INTO `director_scenarios` (`key`, `name`, `description`, `draftRev`, `createdBy`, `createdByName`, `updatedBy`, `updatedByName`, `source`)
        VALUES (?, ?, ?, 1, ?, ?, ?, ?, ?)
    ]], { key, name, type(doc.description) == 'string' and cut(doc.description, 500) or nil, userId, uname, userId, uname, source })
    if not ok or not id then return false, DB_ERROR end
    local okR = pcall(MySQL.insert.await, [[
        INSERT INTO `director_revisions` (`scenarioId`, `rev`, `doc`, `hash`, `editedBy`, `editedByName`, `note`) VALUES (?, 1, ?, ?, ?, ?, ?)
    ]], { id, s, GetHashKey(s) % 4294967296, userId, uname, 'created' })
    if not okR then
        q('DELETE FROM `director_scenarios` WHERE `id` = ?', { id })
        return false, DB_ERROR
    end
    local rows = q('SELECT * FROM `director_scenarios` WHERE `id` = ?', { id })
    if rows and rows[1] then remember(rows[1]) end
    summaries[key] = DirectorStore.summarize(doc)
    return view(scenarios[key])
end

--- Save the draft: a new revision on top of `baseRev`. Answers the new revision, or false and why
--- ('changed by <name>' when someone saved since `baseRev`).
function DirectorStore.save(key, baseRev, doc, by, note)
    local r = scenarios[key]
    if not r then return false, 'no such scenario' end
    baseRev = math.tointeger(tonumber(baseRev) or -1)
    if baseRev ~= r.draftRev then
        return false, ('changed by %s since you opened it (revision %d)'):format(tostring(r.updatedByName or 'someone'), r.draftRev)
    end
    if saving[key] then return false, 'another save of this scenario is under way' end
    local s, why = encode(doc)
    if not s then return false, why end
    local userId, uname = who(by)
    local rev = baseRev + 1
    -- The list's description is the draft's, as its name is (the Blueprint changes it). None is '', never nil: a
    -- nil would leave a hole in the query's values.
    local desc = type(doc.description) == 'string' and cut(doc.description, 500) or ''
    saving[key] = true
    local committed, err = Stores.runTransaction({
        { query = 'UPDATE `director_scenarios` SET `draftRev` = ?, `name` = ?, `description` = ?, `updatedBy` = ?, `updatedByName` = ?, `updatedAt` = NOW() WHERE `id` = ? AND `draftRev` = ?',
          values = { rev, type(doc.name) == 'string' and cut(doc.name, 80) or r.name, desc, userId, uname, r.id, baseRev } },
        { query = 'INSERT INTO `director_revisions` (`scenarioId`, `rev`, `doc`, `hash`, `editedBy`, `editedByName`, `note`) VALUES (?, ?, ?, ?, ?, ?, ?)',
          values = { r.id, rev, s, GetHashKey(s) % 4294967296, userId, uname, type(note) == 'string' and cut(note, 200) or nil } },
    })
    saving[key] = nil
    if not committed then
        say('saving %s revision %d failed: %s', key, rev, tostring(err))
        return false, 'Could not save that: someone else may have saved it, or the database said no'
    end
    r.draftRev, r.updatedBy, r.updatedByName, r.updatedAt = rev, userId, uname, os.time() * 1000
    if type(doc.name) == 'string' then r.name = cut(doc.name, 80) end
    r.description = desc
    summaries[key] = DirectorStore.summarize(doc)
    return rev
end

--- Set a scenario's status ('active' with the revision that is live, 'disabled', 'draft').
function DirectorStore.setStatus(key, status, activeRev, by)
    local r = scenarios[key]
    if not r then return false, 'no such scenario' end
    if status ~= 'active' and status ~= 'disabled' and status ~= 'draft' then return false, 'unknown status' end
    local userId, uname = who(by)
    local res = q('UPDATE `director_scenarios` SET `status` = ?, `activeRev` = ?, `updatedBy` = ?, `updatedByName` = ?, `updatedAt` = NOW() WHERE `id` = ?',
        { status, activeRev, userId, uname, r.id })
    if not res then return false, DB_ERROR end
    r.status, r.activeRev, r.updatedBy, r.updatedByName, r.updatedAt = status, activeRev, userId, uname, os.time() * 1000
    return true
end

--- Which resource provided each of its cards when a person last switched it on:
--- { [cardType] = resource }, or nil when none was recorded. The server brings it back by itself only
--- from the same resources (server/director/cards_api.lua).
---@return table|nil
function DirectorStore.cardProviders(key)
    local r = scenarios[key]
    if not r or type(r.cardProviders) ~= 'string' or r.cardProviders == '' then return nil end
    local ok, t = pcall(json.decode, r.cardProviders)
    return ok and type(t) == 'table' and t or nil
end

--- Record it. Answers true, or false and why.
function DirectorStore.setCardProviders(key, map)
    local r = scenarios[key]
    if not r then return false, 'no such scenario' end
    local text = (type(map) == 'table' and next(map) ~= nil) and json.encode(map) or nil
    if text == r.cardProviders then return true end
    local res = q('UPDATE `director_scenarios` SET `cardProviders` = ? WHERE `id` = ?', { text, r.id })
    if not res then return false, DB_ERROR end
    r.cardProviders = text
    return true
end

--- Is this scenario shipped by a pack (read-only here)? Answers the pack's resource, or nil.
function DirectorStore.packOf(key)
    local r = scenarios[key]
    local res = r and type(r.source) == 'string' and r.source:match('^pack:([%w_%-%.]+)$')
    return res or nil
end

--- Is a key taken, by a scenario here or a shipped one deleted (its tombstone keeps its key)? Waits on the database.
function DirectorStore.keyTaken(key)
    if scenarios[key] then return true end
    local rows = q('SELECT `id` FROM `director_scenarios` WHERE `key` = ?', { key })
    return rows == nil or rows[1] ~= nil
end

--- Delete a scenario (a tombstone: its rows stay, and its runs still count in the Overview). One made here frees its
--- key for a new scenario: the row keeps it behind its id (~<id>~<key>), as the key is unique. A shipped one keeps
--- its key, so its pack never makes it again (DirectorPacks.accept asks keyTaken).
function DirectorStore.delete(key, by)
    local r = scenarios[key]
    if not r then return false, 'no such scenario' end
    local userId, uname = who(by)
    local kept = DirectorStore.packOf(key) and key or ('~%d~%s'):format(r.id, key):sub(1, 64)
    local res = q("UPDATE `director_scenarios` SET `deletedAt` = NOW(), `status` = 'disabled', `key` = ?, `updatedBy` = ?, `updatedByName` = ? WHERE `id` = ?",
        { kept, userId, uname, r.id })
    if not res then return false, DB_ERROR end
    scenarios[key], summaries[key] = nil, nil
    return true
end

-- ============================================
-- Run history (sent without waiting: a run never waits on it)
-- ============================================
--
-- In order, a run at a time: oxmysql runs queries on a pool of connections at once, so a run's first
-- event could race the run's own row (fk_director_event_run). Each run's writes go out one after
-- another from a small worker, the next once the last has answered: the run's row, then its players,
-- its events and its end, in the order they happened. The run itself never waits.
--
-- AWAITED IN A PCALL, NOT CHAINED ON CALLBACKS: oxmysql does not call a plain callback when a query
-- fails, so a chain would stop at the first failure and keep the rest for good. A failed write is
-- said, and the next one still goes.

local queues = {}   -- [runId] = the writes of that run still to send, while its worker is going

local function fire(runId, sql, params)
    local queue = queues[runId]
    if queue then queue[#queue + 1] = { sql, params } return end
    queue = { { sql, params } }
    queues[runId] = queue
    CreateThread(function()
        while #queue > 0 do
            local w = table.remove(queue, 1)
            local ok, err = pcall(MySQL.query.await, w[1], w[2])
            if not ok then say('history write failed: %s', tostring(err)) end
        end
        queues[runId] = nil
    end)
end

--- A run of a stored scenario started: its row and its players.
function DirectorStore.runStarted(run)
    local sc = run.scenario
    local r = sc and sc.dbId and scenarios[sc.id]
    if not r or r.id ~= sc.dbId then return end   -- a scenario from a file (/director load): nothing to file it under
    run.dbScenario, run.events, run.payout = r.id, 0, run.payout or 0
    local starter = Players[run.starter]
    fire(run.id, 'INSERT INTO `director_runs` (`id`, `scenarioId`, `rev`, `test`, `startedBy`, `variant`) VALUES (?, ?, ?, ?, ?, ?)',
        { run.id, r.id, tonumber(run.rev) or 0, run.test and 1 or 0, starter and starter.charId or nil, run.variantName })
    for s in pairs(run.players) do DirectorStore.playerJoined(run, s) end
end

function DirectorStore.playerJoined(run, src)
    if not run.dbScenario then return end
    local p = Players[src]
    if not p or not p.charId then return end
    -- Back in a run they had left (a script took them out, or they disconnected, and AddPlayerToScenarioRun
    -- put them back): their row is open again, so the run's outcome is theirs when it ends.
    fire(run.id, 'INSERT INTO `director_run_players` (`runId`, `charId`, `userId`, `name`) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE `outcome` = NULL',
        { run.id, p.charId, p.userId, p.fullName })
end

--- Something a player did in a run, for the scenario's Interactions tab. At most KEEP_EVENTS a run.
function DirectorStore.event(run, nodeId, kind, src, detail)
    if not run.dbScenario then return end
    run.events = (run.events or 0) + 1
    if run.events > KEEP_EVENTS then return end
    local p = src and Players[src]
    fire(run.id, 'INSERT INTO `director_run_events` (`runId`, `nodeId`, `kind`, `charId`, `detail`) VALUES (?, ?, ?, ?, ?)',
        { run.id, nodeId, cut(tostring(kind), 30), p and p.charId or nil, detail and cut(tostring(detail), 200) or nil })
end

--- A player LEFT a run before it ended (logged out, disconnected): their row says so, rather than
--- taking the run's outcome when it ends (they were not there for it).
function DirectorStore.playerLeft(run, src)
    if not run.dbScenario then return end
    local cid = (run.charOf and run.charOf[src]) or (Players[src] and Players[src].charId)
    if not cid then return end
    fire(run.id, "UPDATE `director_run_players` SET `outcome` = 'left' WHERE `runId` = ? AND `charId` = ? AND `outcome` IS NULL",
        { run.id, cid })
end

function DirectorStore.runEnded(run, outcome, reason)
    if not run.dbScenario then return end
    -- (The job's length: from when it began, its row's own start, not from when its run opened and waited for a player.)
    local from = run.begunAt or run.startedAt or 0
    local secs = math.max(0, math.floor(((run.endedAt or GetGameTimer()) - from) / 1000))
    fire(run.id, 'UPDATE `director_runs` SET `endedAt` = NOW(), `outcome` = ?, `reason` = ?, `faultNode` = ?, `durationS` = ?, `payout` = ? WHERE `id` = ?',
        { outcome, reason and cut(tostring(reason), 200) or nil, run.faultNode, secs, math.floor(run.payout or 0), run.id })
    fire(run.id, 'UPDATE `director_run_players` SET `outcome` = ? WHERE `runId` = ? AND `outcome` IS NULL', { outcome, run.id })
end
