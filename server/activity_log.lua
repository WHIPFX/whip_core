-- ============================================
-- Activity log — who did what, and what happened to which item
-- ============================================
--
-- Two timelines out of one table:
--
--   PLAYER: every logged action a character took — logins, inventory opens, moves,
--   gives, throws, placements, uses, deaths, lockpicks — readable in the /whip
--   Player Manager as "recent activity" with paging back through the lifetime.
--
--   ITEM: because whip item METADATA travels untouched through every move, give,
--   drop, ground row and pickup, an item instance can carry its own identity. The
--   first time an instance crosses any logged choke point, Log.item stamps a `uid`
--   into its metadata and writes a `first_seen` row ("entered the economy: how, by
--   whom"); from then on the uid rides the metadata for free and every event that
--   names it becomes one timeline for that specific wallet, gun, or cash stack.
--
--   Stackables get the honest version of identity: a split leaves the uid on both
--   halves (their timelines share a past), a merge absorbs into the surviving
--   stack.
--
--   GAINED / LOST: the rows for items entering or leaving the game rather than
--   moving within it — shops, admin gives, satellite AddItem/RemoveItem, cash at
--   the ATM and the pump. See Log.gained below; they are what makes a dupe visible.
--
-- Saved with what they describe: rows are a save unit on the Stores engine. A player action's rows
-- go into that action's own log unit, tied to it (secure.lua Actions), so they land in the same
-- transaction as the change they explain. Rows from outside any action go into one shared unit,
-- written with the next save pass. The panel's views write what is owed and then read the database
-- (Log.playerRows / Log.itemRows).

Log = Log or {}

--- A log unit's handle: its name and the rows it owes. The shared one, for rows no action owns.
local globalRows = { name = 'global', rows = {} }

--- Handles with rows still owed, so Log.flush and the final save can find every one.
local _owed = {}

local _logSeq = 0   -- names each action's own log unit
local _rowSeq = 0   -- row.seq: Log.flush writes the oldest owed rows first

local uidCounter = 0

--- A short id unique for this server's lifetime and beyond: seconds since epoch in
--- hex plus a monotonic counter. Not a GUID on purpose — it lives inside item
--- metadata forever, so every byte is paid for on every save of every slot.
function Log.newUid()
    uidCounter = uidCounter + 1
    return ('%x-%x'):format(os.time(), uidCounter)
end

---@return boolean ok
function Log.ensureTable()
    return CreateTable('activity_log', [[
        CREATE TABLE IF NOT EXISTS `activity_log` (
            `id`      BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            `ts`      INT UNSIGNED    NOT NULL,
            `charId`  INT UNSIGNED    DEFAULT NULL,
            `event`   VARCHAR(32)     NOT NULL,
            `itemKey` VARCHAR(50)     DEFAULT NULL,
            `itemUid` VARCHAR(24)     DEFAULT NULL,
            `amount`  INT             DEFAULT NULL,
            `detail`  VARCHAR(191)    DEFAULT NULL,
            `x`       FLOAT           DEFAULT NULL,
            `y`       FLOAT           DEFAULT NULL,
            `z`       FLOAT           DEFAULT NULL,
            `hostKey` VARCHAR(50)     DEFAULT NULL,
            `hostUid` VARCHAR(24)     DEFAULT NULL,
            PRIMARY KEY (`id`),
            KEY `idx_al_char` (`charId`, `id`),
            KEY `idx_al_uid`  (`itemUid`, `id`),
            KEY `idx_al_host` (`hostUid`, `id`),
            KEY `idx_al_ts`   (`ts`),
            KEY `idx_al_event` (`event`, `id`),
            KEY `idx_al_item`  (`itemKey`, `id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])
end

--- Text that fits its column: at most `n` bytes, and never ending half-way through a character.
---
--- Every row goes into one INSERT, so one row the database refuses fails the whole batch, and the
--- batch is retried with every row behind it: an over-long `event` (VARCHAR(32)) or a `detail` cut
--- through a multi-byte character would stop the log for good. Byte length is the safe side of each
--- column's character limit.
---@param s any
---@param n number
---@return string|nil
local function clip(s, n)
    if s == nil then return nil end
    s = tostring(s)
    if #s > n then s = s:sub(1, n) end
    while #s > 0 and not utf8.len(s) do s = s:sub(1, -2) end
    return s
end

--- A whole number that fits the signed INT `amount` column, or nil. Same one-bad-row reason as clip
--- (an amount past 2^31, or not a number).
local INT_MAX, INT_MIN = 2147483647, -2147483648
---@param v any
---@return integer|nil
local function int(v)
    v = tonumber(v)
    if not v or v ~= v then return nil end
    if v >= INT_MAX then return INT_MAX end
    if v <= INT_MIN then return INT_MIN end
    return math.floor(v)
end

--- A coordinate the FLOAT columns take, or nil (NaN and infinity are refused like a bad amount).
---@param v any
---@return number|nil
local function coord(v)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return nil end
    return v
end

--- The base write. charId may be nil (system events). opts: itemKey, uid, amount,
--- detail, and x/y/z — coords make the row's location clickable in the panel
--- (thrown/placed/dropped items carry their landing spot).
function Log.write(charId, event, opts)
    opts = opts or {}
    local row = {
        ts      = os.time(),
        charId  = charId,
        event   = clip(event, 32) or '?',
        itemKey = clip(opts.itemKey, 50),
        itemUid = clip(opts.uid, 24),
        amount  = int(opts.amount),
        detail  = clip(opts.detail, 191),
        x       = coord(opts.x),
        y       = coord(opts.y),
        z       = coord(opts.z),
        hostKey = clip(opts.hostKey, 50),
        hostUid = clip(opts.hostUid, 24),
    }
    Log.queue(row)
end

--- [uid] = true for an instance that has been minted but whose first_seen row is still owed.
---
--- The mint and the log are not the same call: movers pre-stamp the uid (server/events_inventory.lua)
--- BEFORE the move they log, so whoever mints records the debt, and the next Log.item for that
--- instance pays it, whichever path that is. Normally a handful, cleared as each is written (a uid
--- from an operation that aborted before logging waits until that instance is next touched).
local _firstSeenOwed = {}

--- Stamp an item instance's uid into its metadata, creating the metadata table when
--- the item has none. Returns the uid and whether it was newly minted.
---
--- Works because the references are live: player-inventory slots, container slots, basket lines
--- and ground cache rows all hand back the actual stored table, so a key added here is saved with
--- the next write-behind flush and travels with every move. A store kind that returned COPIES from
--- get() would lose stamps (its items would re-stamp on the next touch, history starting over).
function Log.ensureUid(slotData)
    if not slotData then return nil, false end
    if not slotData.metadata then slotData.metadata = {} end
    if slotData.metadata.uid then return slotData.metadata.uid, false end
    local uid = Log.newUid()
    slotData.metadata.uid = uid
    _firstSeenOwed[uid] = true
    return uid, true
end

--- The item-event write: stamps the uid (logging first_seen the moment an instance
--- is born into the log's view), then writes the event against both timelines.
---@param charId number|nil   the acting character
---@param event string        e.g. 'moved', 'gave', 'placed', 'used'
---@param slotData table|nil  { item, amount, metadata } — a LIVE slot/row reference
---@param opts table|nil      amount override, detail
function Log.item(charId, event, slotData, opts)
    opts = opts or {}
    local uid, isNew = Log.ensureUid(slotData)
    -- `isNew` or a debt left by whoever minted it (see _firstSeenOwed): the caller has almost always
    -- stamped the uid already.
    if uid and slotData and (isNew or _firstSeenOwed[uid]) then
        _firstSeenOwed[uid] = nil
        Log.write(charId, 'first_seen', {
            itemKey = slotData.item,
            uid     = uid,
            amount  = opts.amount or (slotData and slotData.amount),
            detail  = event .. (opts.detail and (' · ' .. opts.detail) or ''),
        })
    end
    Log.write(charId, event, {
        itemKey = slotData and slotData.item,
        uid     = uid,
        amount  = opts.amount or (slotData and slotData.amount),
        detail  = opts.detail,
        x       = opts.x,
        y       = opts.y,
        z       = opts.z,
        hostKey = opts.hostKey,
        hostUid = opts.hostUid,
    })
end

-- ---- items entering and leaving the game ----
--
-- Everything above logs items a player moves. These are the moments an item is CREATED or DESTROYED
-- (a shop handing over goods, an admin spawn, a satellite's AddItem, the ATM, a pump taking cash):
-- exactly the moments a duplication bug happens in.
--
-- `why` is written for an admin reading the timeline: 'ATM withdrawal', 'paid at Burger Shot',
-- 'by whip_gunny', 'admin: Jane Smith'. Bank money already has its own ledger
-- (bank_transactions); these rows are the cash and item side.

--- An item came into a player's possession from outside the game world.
---@param charId number|nil
---@param itemKey string
---@param amount number|nil
---@param why string|nil
function Log.gained(charId, itemKey, amount, why)
    Log.write(charId, 'gained', { itemKey = itemKey, amount = amount, detail = why })
end

--- An item left a player's possession and the game world with it — spent, consumed, confiscated.
---@param charId number|nil
---@param itemKey string
---@param amount number|nil
---@param why string|nil
function Log.lost(charId, itemKey, amount, why)
    Log.write(charId, 'lost', { itemKey = itemKey, amount = amount, detail = why })
end

--- A timeline note the CLIENT decides the pace of — opening and closing the inventory, using an
--- interaction point. Capped per character per minute: every other row is written because the
--- server did something, but these are written because a client said so, and a macro or a
--- modified client could write several a second for as long as it liked (kept for 30 days).
--- Past the cap the rest of that minute's notes are dropped; nothing else is affected.
local PACED_PER_MINUTE = 60
local _paced = {}   -- [charId] = { minute, count }

---@param charId number
---@param event string
---@param opts table|nil
function Log.paced(charId, event, opts)
    if not charId then return end
    local minute = os.time() // 60
    local p = _paced[charId]
    if not p or p.minute ~= minute then
        p = { minute = minute, count = 0 }
        _paced[charId] = p
    end
    p.count = p.count + 1
    if p.count > PACED_PER_MINUTE then return end
    Log.write(charId, event, opts)
end

--- 'by <resource>' when another resource asked for this through an export; nil for whip_core's own
--- code. Call it inside the export (or anything it calls), where GetInvokingResource still knows.
---@return string|nil
function Log.byCaller()
    local res = GetInvokingResource()
    if res and res ~= GetCurrentResourceName() then return 'by ' .. res end
    return nil
end

--- The log reason for a change an EXPORT was asked to make: the caller's own words AND who asked,
--- e.g. 'rental refund · by ai_rentals'. Either half alone when that is all there is.
---
--- So an admin can tell a sale from a refund from a wage. The resource name stays in, because a
--- reason is the caller's claim and the name is the part it cannot choose.
---
--- Read at the TOP of the export, before anything yields — GetInvokingResource only names the
--- caller until then (house rule 10).
---
--- A string or `{ reason = '...' }`, wherever it is taken: every export hands its argument here.
---@param why any  the caller's reason: a string, or a table carrying `reason`; anything else is ignored
---@return string|nil
function Log.reasonFrom(why)
    local by = Log.byCaller()
    if type(why) == 'table' then why = rawget(why, 'reason') end
    why = Sanitize.string(why, 120)   -- '' for anything that is not a usable string
    if why == '' then why = nil end
    if why and by then return why .. ' · ' .. by end
    return why or by
end

--- A store, described the way an admin reads it: 'Player Inventory', 'Accessories',
--- 'Trunk of AB123CD', 'Container: Warehouse Stash', 'Panel: Wallet', 'Basket'. Every
--- kind already declares a label(_, handle); this dresses the few whose raw label is
--- tuned for debugging rather than reading.
function Log.storeLabel(store)
    if not store or not store.kind then return '?' end
    local kid = store.kind.id
    local h = store.handle

    if kid == 'player' then
        local container = h and h.container
        if container == 'accessory' then return 'Accessories' end
        return 'Player Inventory'
    end
    if kid == 'vehicle' and h then
        local storage = tostring(h.storageType or 'storage')
        local plate = (h.def and h.def.plate) or '?'
        return storage:sub(1, 1):upper() .. storage:sub(2) .. ' of ' .. plate
    end
    if kid == 'container' and h then
        return 'Container: ' .. ((h.def and h.def.name) or ('#' .. tostring(store.id)))
    end

    local ok, label = pcall(store.kind.label, nil, h)
    label = (ok and label) and tostring(label) or kid
    if kid == 'panel' then return 'Panel: ' .. label end
    return label
end

-- ---- flush ----

local FIELDS = { 'ts', 'charId', 'event', 'itemKey', 'itemUid', 'amount', 'detail', 'x', 'y', 'z', 'hostKey', 'hostUid' }

--- Build one multi-row INSERT with a DENSE parameter array.
---
--- The nil trap: `params[#params + 1] = nil` is a no-op in Lua, so an absent field (a login has no
--- item, a system row has no charId) would shift every later value into the wrong column. Absent
--- fields are written as literal NULL in the SQL and never enter the params array.
local function buildInsert(rows)
    local values, params = {}, {}
    local n = 0
    for _, r in ipairs(rows) do
        local ph = {}
        for i, f in ipairs(FIELDS) do
            local v = r[f]
            if v == nil then
                ph[i] = 'NULL'
            else
                ph[i] = '?'
                n = n + 1
                params[n] = v
            end
        end
        values[#values + 1] = '(' .. table.concat(ph, ', ') .. ')'
    end
    return 'INSERT INTO `activity_log` (`ts`, `charId`, `event`, `itemKey`, `itemUid`, `amount`, `detail`, `x`, `y`, `z`, `hostKey`, `hostUid`) VALUES '
        .. table.concat(values, ', '), params
end

--- Rows per INSERT. After a long database outage the shared unit can hold thousands, and one statement
--- with twelve parameters a row for all of them is a packet the server may refuse outright.
local FLUSH_CHUNK = 500

--- The most rows held while the database is refusing them. Past this the OLDEST are dropped (and
--- said so): an outage should cost some history, not the server's memory.
local BUFFER_MAX = 20000

--- The log unit: its rows, chunked INSERTs, and a confirm that takes off exactly
--- the rows that write carried (rows added during it stay owed). Defined at the first row, because
--- this file loads before stores.lua. No `every`: timelines are read in id order, and a log unit
--- waiting 10 s let a later action's rows land before an earlier one's.
local LOG_UNIT = {
    faultMode = 'activity_log',   -- a log write alone must not use up a test's 'transaction' fault
    unitKey   = function(h) return 'log:' .. h.name end,
    label     = function(h) return 'activity log (' .. h.name .. ')' end,
    writeOrder = function(h) return h.rows[1] and h.rows[1].seq or math.huge end,
    persist = function(h)
        local rows = h.rows
        if #rows == 0 then
            _owed[h] = nil
            return {}
        end
        local sent, queries = {}, {}
        for i = 1, #rows, FLUSH_CHUNK do
            local chunk = table.move(rows, i, math.min(i + FLUSH_CHUNK - 1, #rows), 1, {})
            local sql, params = buildInsert(chunk)
            queries[#queries + 1] = { query = sql, values = params }
        end
        for _, r in ipairs(rows) do sent[r] = true end
        return queries, function()
            local kept = {}
            for _, r in ipairs(h.rows) do
                if not sent[r] then kept[#kept + 1] = r end
            end
            h.rows = kept
            if #kept == 0 then _owed[h] = nil end
        end
    end,
}
local unitDefined = false

---@param h table  a log unit's handle
---@return table store
local function logUnit(h)
    if not unitDefined then
        unitDefined = true
        Stores.defineUnit('log', LOG_UNIT)
    end
    return Stores.unit('log', h) --[[@as table]]   -- the kind is defined just above, and h is a handle
end

--- Queue a row with what it describes. Inside ONE action: that action's own log unit, tied to it, so
--- the row lands in the same transaction as the change. Several candidates: a unit of its own, tied to
--- all of them (over-tying only batches more). None: the shared unit, capped at BUFFER_MAX through an
--- outage — the oldest go, said — so an outage costs some history, not the server's memory.
---@param row table
function Log.queue(row)
    -- The row's player's action, of a satellite's several.
    local who = row.charId and PlayersByCharId and PlayersByCharId[row.charId]
    local recs = Actions and Actions.current(who and who.source) or {}
    local h
    if #recs == 1 then
        h = recs[1].logRows
        if not h then
            _logSeq = _logSeq + 1
            h = { name = 'a' .. _logSeq, rows = {} }
            recs[1].logRows = h
        end
    elseif #recs > 1 then
        _logSeq = _logSeq + 1
        h = { name = 'a' .. _logSeq, rows = {}, src = who and who.source or nil }   -- tied as the row was (Stores)
    else
        h = globalRows
        if #h.rows >= BUFFER_MAX then
            local drop = #h.rows - BUFFER_MAX + 1
            print(('[whip_core:log] %d activity rows waiting — dropping the %d oldest'):format(#h.rows, drop))
            table.move(h.rows, drop + 1, #h.rows, 1)
            for j = #h.rows, #h.rows - drop + 1, -1 do h.rows[j] = nil end
        end
    end
    _rowSeq = _rowSeq + 1
    row.seq = _rowSeq
    h.rows[#h.rows + 1] = row
    _owed[h] = true
    Stores.markDirty(logUnit(h))
end

--- Write the log rows still owed, now. False when some did not land (they stay owed). Rows of an
--- action still running wait for it unless `all` (the final save, FlushActivityLog): writing them
--- early would write that action half done.
---@param all boolean|nil
---@return boolean ok
function Log.flush(all)
    local ok = true
    local handles = {}
    for h in pairs(_owed) do
        if #h.rows > 0 then handles[#handles + 1] = h end
    end
    table.sort(handles, function(a, b) return a.rows[1].seq < b.rows[1].seq end)
    for _, h in ipairs(handles) do
        local key = 'log:' .. h.name
        if #h.rows > 0 and (all or not Stores.isHeld(key)) then
            Stores.markDirty(logUnit(h))
            if not Stores.settle(key) then ok = false end
        end
    end
    return ok
end

--- Retention: a busy server writes a lot of rows and nobody reads last quarter's. Start-up runs it
--- (player_lifecycle.lua), after the schema.
---
--- After ready, by the index, in chunks: `idx_al_ts` (migration 024) finds the rows; each DELETE
--- takes at most PRUNE_CHUNK of them, with a pause between, and the whole run is bounded (this is
--- the biggest table whip has).
local PRUNE_CHUNK, PRUNE_MAX_CHUNKS = 10000, 500
function Log.prune()
    local days = Config.ActivityLogDays or 30
    local cutoff = os.time() - days * 86400
    local total = 0
    for _ = 1, PRUNE_MAX_CHUNKS do
        local ok, removed = pcall(MySQL.update.await,
            'DELETE FROM `activity_log` WHERE `ts` < ? LIMIT ' .. PRUNE_CHUNK, { cutoff })
        if not ok then
            print('[whip_core:log] could not prune the activity log: ' .. tostring(removed))
            return
        end
        removed = tonumber(removed) or 0
        total = total + removed
        if removed < PRUNE_CHUNK then break end
        Wait(250)
    end
    if total > 0 then
        print(('[whip_core:log] pruned %d row(s) older than %d days'):format(total, days))
    end
end

-- Log rows are save units: the engine's 1 s pass writes them (with their action's change), and the
-- stop's dispatch (step 60, after every step that logs) sends what is left.

-- Step 60 of the final save (server/lifecycle.lua): after the kicked players' logout rows, waited for.
FinalSave.add(60, 'activity log rows', function()
    return Log.flush(true)
end, function()
    local n = 0
    for h in pairs(_owed) do n = n + #h.rows end
    return n
end)

-- ---- queries (panel-facing; each flushes first so "recent" includes this second) ----

local function displayName(itemKey)
    local def = itemKey and Config.Items[itemKey]
    return def and def.name or itemKey
end

local function wireRows(rows)
    for _, r in ipairs(rows) do
        r.itemName = displayName(r.itemKey)
        if r.hostKey then r.hostName = displayName(r.hostKey) end
    end
    return rows
end

--- Lifetime page for a set of characters (one player = all their charIds), newest
--- first. beforeId pages backward; 0/nil = from the top.
function Log.playerRows(charIds, beforeId, limit)
    Log.flush()
    if not charIds or #charIds == 0 then return {} end
    local marks = {}
    for i = 1, #charIds do marks[i] = '?' end
    local sql = 'SELECT a.`id`, a.`ts`, a.`charId`, a.`event`, a.`itemKey`, a.`itemUid`, a.`amount`, a.`detail`, a.`x`, a.`y`, a.`z`, a.`hostKey`, a.`hostUid`, '
        .. "CONCAT(c.`firstName`, ' ', c.`lastName`) AS who "
        .. 'FROM `activity_log` a LEFT JOIN `characters` c ON c.`charId` = a.`charId` '
        .. 'WHERE a.`charId` IN (' .. table.concat(marks, ',') .. ')'
    local params = { table.unpack(charIds) }
    if beforeId and beforeId > 0 then
        sql = sql .. ' AND a.`id` < ?'
        params[#params + 1] = beforeId
    end
    sql = sql .. ' ORDER BY a.`id` DESC LIMIT ?'
    params[#params + 1] = limit or 30
    local ok, rows = pcall(MySQL.query.await, sql, params)
    return ok and wireRows(rows or {}) or {}
end

--- The same page, only the cash coming and going (the /whip Banks page's log): not moved about inside
--- their own pockets and stashes.
local CASH_EVENTS = { 'gained', 'lost', 'gave', 'received', 'bought', 'destroyed', 'threw', 'dropped', 'picked_up', 'first_seen' }
function Log.cashRows(charIds, beforeId, limit)
    Log.flush()
    if not charIds or #charIds == 0 then return {} end
    local sql = 'SELECT a.`id`, a.`ts`, a.`charId`, a.`event`, a.`itemKey`, a.`itemUid`, a.`amount`, a.`detail`, a.`x`, a.`y`, a.`z`, a.`hostKey`, a.`hostUid`, '
        .. "CONCAT(c.`firstName`, ' ', c.`lastName`) AS who "
        .. 'FROM `activity_log` a LEFT JOIN `characters` c ON c.`charId` = a.`charId` '
        .. "WHERE a.`itemKey` = 'cash' AND a.`charId` IN (" .. string.rep('?', #charIds, ',') .. ') '
        .. 'AND a.`event` IN (' .. string.rep('?', #CASH_EVENTS, ',') .. ')'
    local params = { table.unpack(charIds) }
    for _, event in ipairs(CASH_EVENTS) do params[#params + 1] = event end
    if beforeId and beforeId > 0 then
        sql = sql .. ' AND a.`id` < ?'
        params[#params + 1] = beforeId
    end
    sql = sql .. ' ORDER BY a.`id` DESC LIMIT ?'
    params[#params + 1] = limit or 30
    local ok, rows = pcall(MySQL.query.await, sql, params)
    return ok and wireRows(rows or {}) or {}
end

--- One item instance's whole life, newest first — including every row where it was
--- the HOST: a duffle bag's timeline shows the cash that went into it, a pistol's
--- shows the magazines loaded through its panel.
function Log.itemRows(uid, beforeId, limit)
    Log.flush()
    if not uid or uid == '' then return {} end
    local sql = 'SELECT a.`id`, a.`ts`, a.`charId`, a.`event`, a.`itemKey`, a.`itemUid`, a.`amount`, a.`detail`, a.`x`, a.`y`, a.`z`, a.`hostKey`, a.`hostUid`, '
        .. "CONCAT(c.`firstName`, ' ', c.`lastName`) AS who "
        .. 'FROM `activity_log` a LEFT JOIN `characters` c ON c.`charId` = a.`charId` '
        .. 'WHERE (a.`itemUid` = ? OR a.`hostUid` = ?)'
    local params = { uid, uid }
    if beforeId and beforeId > 0 then
        sql = sql .. ' AND a.`id` < ?'
        params[#params + 1] = beforeId
    end
    sql = sql .. ' ORDER BY a.`id` DESC LIMIT ?'
    params[#params + 1] = limit or 50
    local ok, rows = pcall(MySQL.query.await, sql, params)
    return ok and wireRows(rows or {}) or {}
end

-- ---- the Item Log: everything, and the economy ----
--
-- The Item Log opens on everything that happened, newest first, and narrows it: by what happened,
-- by one item, one person or one item's id, by when, by how many. Its Economy tab adds up what came
-- into the game and what left it. Each read is bounded twice: a row limit, and a time limit the
-- database enforces (MAX_EXECUTION_TIME; a database without it reads the hint as a comment).

--- What happened, in the groups the Item Log's buttons name. 'used' also takes every ctx_ event
--- (a context menu option).
Log.GROUPS = {
    came_in  = { 'gained', 'bought', 'first_seen' },
    went_out = { 'lost', 'destroyed' },
    traded   = { 'gave', 'received' },
    ground   = { 'threw', 'dropped', 'placed', 'picked_up' },
    used     = { 'used' },
    moves    = { 'moved', 'organised', 'merged' },
}

local FEED_COLUMNS = 'SELECT /*+ MAX_EXECUTION_TIME(4000) */ a.`id`, a.`ts`, a.`charId`, a.`event`, a.`itemKey`, '
    .. 'a.`itemUid`, a.`amount`, a.`detail`, a.`x`, a.`y`, a.`z`, a.`hostKey`, a.`hostUid`, '
    .. "c.`userId` AS userId, CONCAT(c.`firstName`, ' ', c.`lastName`) AS who "
    .. 'FROM `activity_log` a LEFT JOIN `characters` c ON c.`charId` = a.`charId` '

--- A page of what happened to items, newest first: only rows naming an item, so a login, dev mode or opening the
--- inventory is never on the Item Log (the Player Manager's timeline has those). Narrowed by `f` (each part
--- optional; anything unreadable is left out rather than refused):
---   group      a key of Log.GROUPS
---   itemKey    one item          charId   one character        uid   one item instance (or its host)
---   since      unix seconds      minAmount  rows moving at least this many
---   beforeId   older than this row (paging back)   afterId   newer than this row (the live poll)
---@param f table|nil
---@return table rows
function Log.feedRows(f)
    Log.flush()
    f = type(f) == 'table' and f or {}
    local where, params = { "a.`itemKey` IS NOT NULL AND a.`itemKey` <> ''" }, {}
    local group = type(f.group) == 'string' and Log.GROUPS[f.group] or nil
    if group then
        local marks = {}
        for i, ev in ipairs(group) do marks[i] = '?'; params[#params + 1] = ev end
        local clause = 'a.`event` IN (' .. table.concat(marks, ',') .. ')'
        if f.group == 'used' then clause = '(' .. clause .. " OR a.`event` LIKE 'ctx\\_%')" end
        where[#where + 1] = clause
    end
    if type(f.itemKey) == 'string' and #f.itemKey <= 50 and f.itemKey:match('^[%w_%-%.]+$') then
        where[#where + 1] = 'a.`itemKey` = ?'
        params[#params + 1] = f.itemKey
    end
    local charId = math.tointeger(tonumber(f.charId))
    if charId and charId > 0 then
        where[#where + 1] = 'a.`charId` = ?'
        params[#params + 1] = charId
    end
    if type(f.uid) == 'string' and #f.uid <= 24 and f.uid:match('^[%w%-]+$') then
        where[#where + 1] = '(a.`itemUid` = ? OR a.`hostUid` = ?)'
        params[#params + 1] = f.uid
        params[#params + 1] = f.uid
    end
    local since = math.tointeger(tonumber(f.since))
    if since and since > 0 then
        where[#where + 1] = 'a.`ts` >= ?'
        params[#params + 1] = since
    end
    local minAmount = math.tointeger(tonumber(f.minAmount))
    if minAmount and minAmount > 1 then
        where[#where + 1] = 'a.`amount` >= ?'
        params[#params + 1] = minAmount
    end
    local beforeId = math.tointeger(tonumber(f.beforeId))
    if beforeId and beforeId > 0 then
        where[#where + 1] = 'a.`id` < ?'
        params[#params + 1] = beforeId
    end
    local afterId = math.tointeger(tonumber(f.afterId))
    if afterId and afterId > 0 then
        where[#where + 1] = 'a.`id` > ?'
        params[#params + 1] = afterId
    end
    local sql = FEED_COLUMNS .. (#where > 0 and ('WHERE ' .. table.concat(where, ' AND ')) or '')
        .. ' ORDER BY a.`id` DESC LIMIT 50'
    local ok, rows = pcall(MySQL.query.await, sql, params)
    if not ok then
        print('[whip_core:log] the Item Log could not be read: ' .. tostring(rows))
        return {}
    end
    return wireRows(rows or {})
end

--- Which items moved since `since`, busiest first: every row naming the item counts (bought, given,
--- dropped, used...). For the Economy's item picker (moved today / this week / this month / all).
--- nil when it could not be read.
---@param since number  unix seconds
---@return table|nil { { itemKey, n } }
function Log.itemActivity(since)
    Log.flush()
    local floor = os.time() - ((Config.ActivityLogDays or 30) + 1) * 86400
    since = math.tointeger(tonumber(since)) or (os.time() - 86400)
    if since < floor then since = floor end
    local ok, rows = pcall(MySQL.query.await, 'SELECT /*+ MAX_EXECUTION_TIME(5000) */ `itemKey`, COUNT(*) AS n '
        .. 'FROM `activity_log` WHERE `ts` >= ? AND `itemKey` IS NOT NULL GROUP BY `itemKey` ORDER BY n DESC LIMIT 500', { since })
    if not ok then
        print('[whip_core:log] which items moved could not be read: ' .. tostring(rows))
        return nil
    end
    for _, r in ipairs(rows or {}) do r.n = tonumber(r.n) or 0 end
    return rows or {}
end

--- One item instance at a glance, for the head of its life on the Item Log: the first row (how it
--- came to be), the newest (where it was last), and how many rows it has.
---@param uid string
---@return table|nil { first, last, count }
function Log.itemInfo(uid)
    Log.flush()
    if type(uid) ~= 'string' or uid == '' or #uid > 24 then return nil end
    local function one(order)
        local ok, rows = pcall(MySQL.query.await, FEED_COLUMNS
            .. 'WHERE a.`itemUid` = ? ORDER BY a.`id` ' .. order .. ' LIMIT 1', { uid })
        return ok and rows and rows[1] and wireRows({ rows[1] })[1] or nil
    end
    local ok, count = pcall(MySQL.scalar.await,
        'SELECT COUNT(*) FROM `activity_log` WHERE `itemUid` = ? OR `hostUid` = ?', { uid, uid })
    return { first = one('ASC'), last = one('DESC'), count = ok and tonumber(count) or 0 }
end

--- What came into the game and what left it since `since`: per item, and for one item (`itemKey`,
--- cash by default) where it came from and went, and who gained the most of it.
---   in   gained (made: admin gives, scripts, the ATM, starting cash) + bought (from a catalog shop, which makes
---        what it sells; a stocked shop's goods were on its shelf already and are logged 'received')
---   out  lost (spent, used up, paid in) + destroyed
--- A reason is the row's detail up to its first " · " — "admin: Jane Smith", "at 24/7 Store",
--- "ATM withdrawal" — so one shop's sales add up together whatever each thing cost.
---
--- `series`: that item's in and out per `bucket` seconds from `since` (an hour or a day), for the
--- Economy tab's graphs ("how many burgers made a day").
--- Bucket 0 starts at `since`, which the page sets to its own midnight, so a day is the admin's day.
---@param since number   unix seconds
---@param itemKey string|nil
---@param bucket number|nil  3600 or 86400
---@return table
function Log.economy(since, itemKey, bucket)
    Log.flush()
    local floor = os.time() - ((Config.ActivityLogDays or 30) + 1) * 86400
    since = math.tointeger(tonumber(since)) or (os.time() - 86400)
    if since < floor then since = floor end
    if type(itemKey) ~= 'string' or not itemKey:match('^[%w_%-%.]+$') then itemKey = 'cash' end
    bucket = math.tointeger(tonumber(bucket)) == 3600 and 3600 or 86400
    local hint = 'SELECT /*+ MAX_EXECUTION_TIME(5000) */ '
    local events = "('gained', 'bought', 'lost', 'destroyed')"

    local okS, series = pcall(MySQL.query.await, hint
        .. 'FLOOR((a.`ts` - ?) / ?) AS b, a.`event`, CAST(COALESCE(SUM(a.`amount`), 0) AS SIGNED) AS total, COUNT(*) AS n '
        .. 'FROM `activity_log` a WHERE a.`itemKey` = ? AND a.`ts` >= ? AND a.`event` IN ' .. events
        .. ' GROUP BY b, a.`event`', { since, bucket, itemKey, since })
    if not okS then
        print('[whip_core:log] the economy\'s graph could not be read: ' .. tostring(series))
        series = {}
    end
    local buckets = {}   -- [b] = { b, gained, bought, lost, destroyed }
    for _, r in ipairs(series or {}) do
        local b = math.tointeger(tonumber(r.b)) or 0
        local e = buckets[b]
        if not e then
            e = { b = b, gained = 0, bought = 0, lost = 0, destroyed = 0 }
            buckets[b] = e
        end
        e[r.event] = (e[r.event] or 0) + (tonumber(r.total) or 0)
    end
    local seriesList = {}
    for _, e in pairs(buckets) do seriesList[#seriesList + 1] = e end
    table.sort(seriesList, function(a, b) return a.b < b.b end)

    local okA, perItem = pcall(MySQL.query.await, hint
        .. 'a.`itemKey`, a.`event`, CAST(COALESCE(SUM(a.`amount`), 0) AS SIGNED) AS total, COUNT(*) AS n '
        .. 'FROM `activity_log` a WHERE a.`ts` >= ? AND a.`itemKey` IS NOT NULL AND a.`event` IN ' .. events
        .. ' GROUP BY a.`itemKey`, a.`event`', { since })
    local okB, reasons = pcall(MySQL.query.await, hint
        .. "a.`event`, SUBSTRING_INDEX(COALESCE(a.`detail`, ''), ' · ', 1) AS why, "
        .. 'CAST(COALESCE(SUM(a.`amount`), 0) AS SIGNED) AS total, COUNT(*) AS n '
        .. 'FROM `activity_log` a WHERE a.`ts` >= ? AND a.`itemKey` = ? AND a.`event` IN ' .. events
        .. ' GROUP BY a.`event`, why ORDER BY total DESC LIMIT 40', { since, itemKey })
    local okC, gainers = pcall(MySQL.query.await, hint
        .. "a.`charId`, MAX(c.`userId`) AS userId, MAX(CONCAT(c.`firstName`, ' ', c.`lastName`)) AS who, "
        .. 'CAST(COALESCE(SUM(a.`amount`), 0) AS SIGNED) AS total, COUNT(*) AS n '
        .. 'FROM `activity_log` a LEFT JOIN `characters` c ON c.`charId` = a.`charId` '
        .. "WHERE a.`ts` >= ? AND a.`itemKey` = ? AND a.`event` IN ('gained', 'bought') AND a.`charId` IS NOT NULL "
        .. 'GROUP BY a.`charId` ORDER BY total DESC LIMIT 15', { since, itemKey })
    if not (okA and okB and okC) then
        print('[whip_core:log] the economy could not be read: '
            .. tostring((not okA and perItem) or (not okB and reasons) or gainers))
        return { ok = false, why = 'The log could not be read (it may be too big for that period): try a shorter one' }
    end

    local items = {}
    for _, r in ipairs(perItem or {}) do
        local k = r.itemKey
        local it = items[k]
        if not it then
            it = { itemKey = k, itemName = displayName(k), gained = 0, bought = 0, lost = 0, destroyed = 0, n = 0 }
            items[k] = it
        end
        it[r.event] = (it[r.event] or 0) + (tonumber(r.total) or 0)
        it.n = it.n + (tonumber(r.n) or 0)
    end
    local list = {}
    for _, it in pairs(items) do list[#list + 1] = it end
    table.sort(list, function(a, b) return a.n > b.n end)

    for _, r in ipairs(reasons or {}) do r.total = tonumber(r.total) or 0; r.n = tonumber(r.n) or 0 end
    for _, r in ipairs(gainers or {}) do r.total = tonumber(r.total) or 0; r.n = tonumber(r.n) or 0 end
    return { ok = true, since = since, itemKey = itemKey, itemName = displayName(itemKey), bucket = bucket,
             items = list, reasons = reasons or {}, gainers = gainers or {}, series = seriesList }
end

-- ---- exports ----

--- Satellite-facing: log an action for a player. whip_autos entering a Whiplash bay, a lockpick
--- minigame, a radial option — anything a satellite considers worth a timeline row.
---
--- To tie the row to an item, give its address: `{ kind = 'player', id = source, sub = 'player',
--- slot = 4 }`, the address a use handler or FindItem hands you, or any store's (a gun in a stash).
--- It is resolved HERE, against the real slot: everything crossing an export is a copy, and a uid
--- minted into a copy would belong to nothing.
---
--- A slot TABLE (a copy, `{ item, amount, metadata }`) is still accepted. Its uid is used if it has
--- one, which is correct — that is the real item's uid. If it has none, nothing is minted: a uid put
--- into a copy belongs to nothing.
exports('LogActivity', function(source, event, opts)
    if type(event) ~= 'string' or event == '' then return false, 'event name required' end
    if opts ~= nil and type(opts) ~= 'table' then return false, 'opts is { detail?, slotData? }' end
    local detail, slotData = opts and opts.detail, opts and opts.slotData
    local player = Players and Players[source]
    local charId = player and player.charId or nil

    if type(slotData) == 'table' and slotData.kind ~= nil then
        local store, slot, err = Stores.fromAddr(slotData)
        if not store then return false, err end
        if slot > store.kind.slots(store.handle) then return false, 'Invalid slot' end

        local live = store.kind.get(store.handle, slot)
        if not live or not live.item then return false, 'Empty slot' end

        local hadUid = live.metadata and live.metadata.uid
        Log.item(charId, event, live, { detail = detail })

        -- A uid minted just now is metadata like any other: it has to reach disk with the item, or
        -- a restart hands back the item without it and its history starts again.
        if not hadUid then
            -- A resource's own kind answers `get` with a copy, so the uid is written back through it.
            if StoreKindOwners and StoreKindOwners[store.kind.id] then
                store.kind.set(store.handle, slot, live.item, live.amount, live.metadata)
            end
            if store.kind.persist ~= nil then Stores.markDirty(store) end
        end
        return true
    end

    -- A `{ container, slot }` table is refused out loud rather than logged as a row tied to no item.
    if type(slotData) == 'table' and slotData.container ~= nil and slotData.item == nil then
        return false, "name the slot with an address: { kind = 'player', id = source, sub = 'player', slot = n }"
    end

    if type(slotData) == 'table' and slotData.item then
        Log.write(charId, event, {
            itemKey = slotData.item,
            uid     = slotData.metadata and slotData.metadata.uid or nil,
            amount  = slotData.amount,
            detail  = detail,
        })
        return true
    end

    Log.write(charId, event, { detail = detail })
    return true
end)

--- Test/ops-facing: write every owed row now, and say whether it all landed. A write already in
--- flight is waited for (Stores.settle), and a failed one is false: still owed is not written.
---@return boolean
exports('FlushActivityLog', function()
    return Log.flush(true)
end)
