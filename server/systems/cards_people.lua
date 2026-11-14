-- ============================================
-- Systems — cards about people: who they are, what they carry, their jobs, their stats
-- ============================================
--
-- Reads, each over whip_core's internal function (never its export),
-- with server/systems/cards_server.lua's rules: a player only through ctx:source (it fails closed on
-- an old session, and in a Test sees only the tester), anything that waits inside ctx:call. These
-- read and never change anything, so none has a power. `api` names the export each one stands for
-- (dev/systems_cards.js reports which exports have a card).

local C = SystemCards

local function define(def)
    def.side = 'server'
    local ok, why = C.define(def)
    if not ok then print('^1[whip_core:systems] card type refused: ' .. tostring(why) .. '^0') end
end

local CALL_TIMEOUT_S = 15

--- A player value's loaded player: src and the live record, or nil.
local function playerOf(ctx, pv)
    local src = ctx:source(pv)
    local p = src and Players[src]
    if not p or not p.charId then return nil end
    return src, p
end

--- A list of server ids as player values, as this pulse may see them (ctx:source: in a Test only the
--- tester), nearest first when `from` is a place (flat, as PlayersInRange measures), at most C.MAX_LIST.
local function playerList(ctx, ids, from)
    local out = {}
    for _, src in ipairs(ids) do
        local pv = Systems.playerValue(src)
        if pv and ctx:source(pv) then
            local d = 0
            if from then
                local ped = GetPlayerPed(src)
                local c = ped and ped ~= 0 and GetEntityCoords(ped)
                if c then d = (c.x - from.x) ^ 2 + (c.y - from.y) ^ 2 end
            end
            out[#out + 1] = { pv = pv, d = d, src = src }
        end
    end
    table.sort(out, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.src < b.src end)
    local list = {}
    for i = 1, math.min(#out, C.MAX_LIST) do list[i] = out[i].pv end
    return list, #out
end
C.playerList = playerList

--- The one name helper: every name a system gives a thing in whip is `s_<short id>_<name>` (`s_` is
--- the systems' prefix). A Test's are its own (`s_<short id>_t<tester>-<name>`), so a Test never moves
--- or takes down what the switched-on system made. `name` keeps letters, digits and _, so the "-" is a
--- Test's alone (a live name can't be read as a tester's).
--- C.name(shortId, tester, name) is the rule itself, for a card's standing() (no ctx there); C.nameFor
--- reads both from a card's ctx.
---@return string
function C.name(short, tester, name)
    name = tostring(name or ''):gsub('[^%w_]', ''):sub(1, 24)
    if name == '' then name = 'x' end
    short = tostring(short or 'x')
    if tester then return ('s_%s_t%s-%s'):format(short, tostring(tester), name) end
    return ('s_%s_%s'):format(short, name)
end

function C.nameFor(ctx, name) return C.name(ctx:meta().shortId, ctx:tester(), name) end

--- How many things whip_core holds under a tag in one registry ('blip', 'tempVehicle'): what a card
--- that makes things counts against its system's cap (server load, not money).
function C.liveUnder(tag, registry)
    local n = 0
    for _, e in ipairs(Registry.listTagged('whip_core', tag)) do if e.registry == registry then n = n + 1 end end
    return n
end

-- ============================================
-- Triggers: from core's own hooks (server/systems/main.lua), never public events
-- ============================================

define({
    type = 'when.playerDown', category = 'when', kind = 'trigger', title = 'When a Player Goes Down',
    desc = 'A player is downed (killed). Killer is the player the server found did it, when it was one.',
    trigger = { name = 'player.down', match = function(_, p)
        if type(p) ~= 'table' or not p.player then return nil end
        return { player = p.player, killer = p.killer }, { player = p.player }
    end },
    values = { outputs = { { key = 'player', type = 'player', label = 'Player' }, { key = 'killer', type = 'player', label = 'Killer' } } },
})

define({
    type = 'when.playerRevived', category = 'when', kind = 'trigger', title = 'When a Player Gets Up',
    desc = 'A downed player is up again: revived by someone, or respawned.',
    trigger = { name = 'player.revived', match = function(_, p)
        if type(p) ~= 'table' or not p.player then return nil end
        return { player = p.player, respawned = p.how == 'respawned' }, { player = p.player }
    end },
    values = { outputs = { { key = 'player', type = 'player', label = 'Player' }, { key = 'respawned', type = 'bool', label = 'Respawned' } } },
})

define({
    type = 'when.playerHurt', category = 'when', kind = 'trigger', title = 'When a Player Is Hurt',
    desc = 'A player loses health (a fall, a crash, a fight), at least this much at once. Health is out of 200; their game reports it.',
    props = { { key = 'least', kind = 'number', label = 'At least (health)', default = 5, min = 1, max = 200 } },
    trigger = { name = 'player.hurt', match = function(ctx, p)
        if type(p) ~= 'table' or not p.player then return nil end
        if (tonumber(p.lost) or 0) < (tonumber(ctx:prop('least')) or 5) then return nil end
        return { player = p.player, health = p.health, lost = p.lost }, { player = p.player }
    end },
    -- Their game reports their health: both numbers are claims (compile.lua holds them from amounts).
    values = { outputs = { { key = 'player', type = 'player', label = 'Player' }, { key = 'health', type = 'number', label = 'Health now', claim = true },
                           { key = 'lost', type = 'number', label = 'Lost', claim = true } } },
})

--- Has the game clock passed `target` (minutes into the day) going from `last` to `now`? Through
--- midnight too. Stopped (frozen), or turned back, it passes nothing.
local function clockPassed(last, now, target)
    if last == now then return false end
    if last < now then return last < target and target <= now end
    -- Through midnight (23:59 -> 00:01), or set back: only a short step counts as midnight.
    if last - now < 720 then return false end
    return target > last or target <= now
end
C.clockPassed = clockPassed

define({
    type = 'when.clock', category = 'when', kind = 'trigger', title = 'When the Clock Reaches',
    desc = 'The game\'s clock (the one every player sees) reaches a time: 18:00 for the shops to close. Once each game day; never while time is stopped.',
    props = { { key = 'hour', kind = 'number', label = 'Hour (0-23)', default = 18, min = 0, max = 23 },
              { key = 'minute', kind = 'number', label = 'Minute', default = 0, min = 0, max = 59 } },
    values = { outputs = { { key = 'hour', type = 'number', label = 'Hour' }, { key = 'minute', type = 'number', label = 'Minute' } } },
    watch = {
        -- A game minute is two seconds at the normal pace: checked every second, none is missed.
        every = function() return 1000 end,
        perPlayer = function() return false end,
        check = function(ctx, last)
            local h, m = TimeWeather.now()
            local now = (tonumber(h) or 0) * 60 + (tonumber(m) or 0)
            local th = math.floor(math.max(0, math.min(23, tonumber(ctx:prop('hour')) or 0)))
            local tm = math.floor(math.max(0, math.min(59, tonumber(ctx:prop('minute')) or 0)))
            local fire = last ~= nil and clockPassed(last, now, th * 60 + tm)
            return now, fire and { hour = th, minute = tm } or nil
        end,
    },
})

-- ============================================
-- Players
-- ============================================

define({
    type = 'player.sheet', category = 'players', kind = 'value', title = 'About Them', api = 'GetPlayer',
    desc = 'What whip knows about a player now: their character, cash in their pockets, health and armour, and whether they are down. Found is no when they are not here.',
    values = { inputs = { { key = 'player', type = 'player', label = 'Player' } },
               outputs = { { key = 'found', type = 'bool', label = 'Found' }, { key = 'name', type = 'text', label = 'Name' },
                           { key = 'character', type = 'character', label = 'Character' }, { key = 'cash', type = 'number', label = 'Cash' },
                           { key = 'health', type = 'number', label = 'Health' }, { key = 'armour', type = 'number', label = 'Armour' },
                           { key = 'down', type = 'bool', label = 'Down' } } },
    value = function(ctx)
        local src, p = playerOf(ctx, ctx:need('player'))
        if not src or not p then return { found = false, name = '', cash = 0, health = 0, armour = 0, down = false } end
        return { found = true, name = p.fullName or '', character = p.charId, cash = p:getCash() or 0,
                 health = Stats.get(src, 'health') or 0, armour = Stats.get(src, 'armour') or 0, down = p.isDead == true }
    end,
})

define({
    type = 'player.ofCharacter', category = 'players', kind = 'value', title = 'Their Player', api = 'GetPlayer',
    desc = 'The player who is on as a character now (a car\'s owner, a job\'s boss), if they are. Found is no while they are not.',
    values = { inputs = { { key = 'character', type = 'character', label = 'Character' } },
               outputs = { { key = 'player', type = 'player', label = 'Player' }, { key = 'found', type = 'bool', label = 'Found' } } },
    value = function(ctx)
        local p = PlayersByCharId[ctx:need('character')]
        local pv = p and Systems.playerValue(p.source)
        if not pv or not ctx:source(pv) then return { found = false } end
        return { player = pv, found = true }
    end,
})

define({
    type = 'player.near', category = 'players', kind = 'value', title = 'Players Near', api = 'GetPlayersInRange',
    desc = 'The players within a distance of a place (measured flat, as on the map), nearest first. 64 at most.',
    values = { inputs = { { key = 'place', type = 'vector', label = 'Place' }, { key = 'range', type = 'number', label = 'Within (m)', default = 25 } },
               outputs = { { key = 'players', type = 'list', label = 'Players' }, { key = 'count', type = 'number', label = 'How many' },
                           { key = 'nearest', type = 'player', label = 'Nearest' } } },
    value = function(ctx)
        local at = ctx:need('place')
        local range = math.max(1, math.min(Config.NetworkRange or 424, ctx:need('range')))
        local list, n = playerList(ctx, PlayersInRange(at.x, at.y, range), at)
        return { players = list, count = n, nearest = list[1] }
    end,
})

define({
    type = 'player.hasPermission', category = 'players', kind = 'value', title = 'Has Permission?', api = 'HasPermission',
    desc = 'Yes or no: does a player hold a whip permission (one given in game, like systems.build or a resource\'s own).',
    props = { { key = 'permission', kind = 'text', label = 'Permission', required = true, maxLength = 64 } },
    values = { inputs = { { key = 'player', type = 'player', label = 'Player' } },
               outputs = { { key = 'result', type = 'bool', label = 'Yes?' } } },
    value = function(ctx)
        local src = ctx:source(ctx:need('player'))
        local name = ctx:prop('permission')
        if not src or type(name) ~= 'string' then return { result = false } end
        return { result = Permissions.has(src, name) == true }
    end,
})

define({
    type = 'player.flag', category = 'players', kind = 'value', title = 'Their Flag', api = 'GetPlayerFlag',
    desc = 'A flag on a player\'s character (set by a resource or a mission: "met_the_mechanic"). Set says if it is there at all.',
    props = { { key = 'flag', kind = 'text', label = 'Flag', required = true, maxLength = 64 } },
    values = { inputs = { { key = 'player', type = 'player', label = 'Player' } },
               outputs = { { key = 'value', type = 'any', label = 'Value' }, { key = 'set', type = 'bool', label = 'Set' } } },
    value = function(ctx)
        local src = playerOf(ctx, ctx:need('player'))
        if not src then return { set = false } end
        local v = PlayerFlags.get(src, ctx:prop('flag'))
        return { value = v, set = v ~= nil }
    end,
})

-- ============================================
-- Money (reads: nothing moves)
-- ============================================

define({
    type = 'money.cash', category = 'money', kind = 'value', title = 'Cash Carried', api = 'GetPlayerCash',
    desc = 'How much cash a player has on them (every pocket, bags too).',
    values = { inputs = { { key = 'player', type = 'player', label = 'Player' } },
               outputs = { { key = 'cash', type = 'number', label = 'Cash' } } },
    value = function(ctx)
        local _, p = playerOf(ctx, ctx:need('player'))
        return { cash = p and p:getCash() or 0 }
    end,
})

-- HAS MONEY? asks what Charge would: by the same rule (money.lua's charge). Cash it answers at once;
-- the bank waits on the database, so the card waits. THIS pulse's player only, as Charge: someone
-- else's bank balance is theirs.
define({
    type = 'money.has', category = 'money', kind = 'wait', title = 'Has Money?', api = 'GetDefaultBankAccount',
    desc = 'Can THIS pulse\'s player pay this much: from cash, from the bank, or either (as Charge would take it). Says what they have. A bank that cannot be reached is Could Not Tell.',
    outputs = { 'yes', 'no', 'timeout' },
    labels = { yes = 'Yes', no = 'No', timeout = 'Could not tell' },
    props = { { key = 'method', kind = 'select', label = 'From', options = { 'auto', 'cash', 'bank' }, default = 'auto' } },
    values = { inputs = { { key = 'amount', type = 'number', label = 'Amount ($)' } },
               outputs = { { key = 'cash', type = 'number', label = 'Cash' }, { key = 'bank', type = 'number', label = 'In the bank' } } },
    run = function(ctx)
        local amount = math.max(0, math.floor(ctx:need('amount')))
        local me = ctx:player()
        local _, p = playerOf(ctx, me)
        if not p or not p.inventory then return 'no', { cash = 0, bank = 0 } end
        local cash = p:getCash() or 0
        local method = ctx:prop('method')
        if method == 'cash' then return cash >= amount and 'yes' or 'no', { cash = cash } end
        if method == 'auto' and cash >= amount then return 'yes', { cash = cash } end
        local charId = p.charId
        ctx:call(function()
            if not ctx:source(me) then return 'no', { cash = cash, bank = 0 } end
            local acct, err = Bank.GetDefaultAccount(charId)
            if not acct and err then ctx:log('the bank could not be reached: %s', tostring(err)) return 'timeout', { cash = cash } end
            local balance = acct and not DbBool(acct.frozen) and tonumber(acct.balance) or 0
            return balance >= amount and 'yes' or 'no', { cash = cash, bank = balance }
        end)
        ctx:after(CALL_TIMEOUT_S * 1000, 'timeout')
        return nil
    end,
})

-- ============================================
-- Jobs
-- ============================================

--- A job prop's job (by key or id), or nil.
local function jobOf(ctx, key)
    local ref = ctx:prop(key)
    if type(ref) ~= 'string' or ref == '' then return nil end
    return Jobs.resolve(tonumber(ref) or ref)
end

define({
    type = 'job.onDuty', category = 'jobs', kind = 'value', title = 'Is On Duty?', api = 'IsPlayerClockedOn',
    desc = 'Yes or no: is a player clocked on, at this job (its key) or, left empty, at any. Job says which they are on duty at.',
    props = { { key = 'job', kind = 'text', label = 'Job (empty: any)', maxLength = 50 } },
    values = { inputs = { { key = 'player', type = 'player', label = 'Player' } },
               outputs = { { key = 'result', type = 'bool', label = 'Yes?' }, { key = 'job', type = 'job', label = 'Job' } } },
    value = function(ctx)
        local _, p = playerOf(ctx, ctx:need('player'))
        if not p then return { result = false } end
        local want = ctx:prop('job')
        if type(want) == 'string' and want ~= '' then
            local job = jobOf(ctx, 'job')
            if not job then return nil, ('there is no job "%s"'):format(want) end
            local on = Jobs.isClockedOn(p.charId, job.jobId)
            return { result = on, job = on and job.key or nil }
        end
        local current = Jobs.currentDutyJob(p.charId)
        local job = current and Jobs.cache[current]
        return { result = current ~= nil, job = job and job.key or nil }
    end,
})

define({
    type = 'job.current', category = 'jobs', kind = 'value', title = 'Their Job Now', api = 'GetPlayerJob',
    desc = 'The job a player is on duty at now (the one they clocked on at last), with their role there. On Duty is no when they are at none.',
    values = { inputs = { { key = 'player', type = 'player', label = 'Player' } },
               outputs = { { key = 'onDuty', type = 'bool', label = 'On duty' }, { key = 'job', type = 'job', label = 'Job' },
                           { key = 'name', type = 'text', label = 'Job name' }, { key = 'role', type = 'text', label = 'Role' },
                           { key = 'level', type = 'number', label = 'Role level' } } },
    value = function(ctx)
        local _, p = playerOf(ctx, ctx:need('player'))
        local info = p and Jobs.dutyJobInfo(p.charId)
        if not info then return { onDuty = false, name = '', role = '', level = 0 } end
        return { onDuty = true, job = info.key, name = info.name or '', role = info.roleName or '', level = tonumber(info.roleLevel) or 0 }
    end,
})

define({
    type = 'job.role', category = 'jobs', kind = 'value', title = 'Their Role', api = 'GetPlayerRole',
    desc = 'A player\'s role at a job (its key), on duty or not. An owner has the top role. Found is no when they have none there.',
    props = { { key = 'job', kind = 'text', label = 'Job', required = true, maxLength = 50 } },
    values = { inputs = { { key = 'player', type = 'player', label = 'Player' } },
               outputs = { { key = 'found', type = 'bool', label = 'Found' }, { key = 'role', type = 'text', label = 'Role' },
                           { key = 'level', type = 'number', label = 'Level' } } },
    value = function(ctx)
        local job = jobOf(ctx, 'job')
        if not job then return nil, ('there is no job "%s"'):format(tostring(ctx:prop('job'))) end
        local _, p = playerOf(ctx, ctx:need('player'))
        local role = p and Jobs.getPlayerRole(p.charId, job.jobId)
        if not role then return { found = false, role = '', level = 0 } end
        return { found = true, role = role.name or '', level = tonumber(role.level) or 0 }
    end,
})

define({
    type = 'job.may', category = 'jobs', kind = 'value', title = 'Allowed at Job?', api = 'HasJobPermission',
    desc = 'Yes or no: may a player do this at a job (a permission its roles give, like "cuff" or "stock"). Ticked On Duty Only, they must be clocked on there too.',
    props = { { key = 'job', kind = 'text', label = 'Job', required = true, maxLength = 50 },
              { key = 'permission', kind = 'text', label = 'Permission', required = true, maxLength = 64 },
              { key = 'onDuty', kind = 'bool', label = 'On duty only', default = false } },
    values = { inputs = { { key = 'player', type = 'player', label = 'Player' } },
               outputs = { { key = 'result', type = 'bool', label = 'Yes?' } } },
    value = function(ctx)
        local job = jobOf(ctx, 'job')
        if not job then return nil, ('there is no job "%s"'):format(tostring(ctx:prop('job'))) end
        local _, p = playerOf(ctx, ctx:need('player'))
        if not p then return { result = false } end
        if ctx:prop('onDuty') == true and not Jobs.isClockedOn(p.charId, job.jobId) then return { result = false } end
        return { result = Jobs.hasPermission(p.charId, job.jobId, ctx:prop('permission')) == true }
    end,
})

define({
    type = 'job.info', category = 'jobs', kind = 'value', title = 'Job Info', api = { 'GetJob', 'GetJobRoles' },
    desc = 'A job by its key: its name, whose business it is, and its roles, highest first.',
    props = { { key = 'job', kind = 'text', label = 'Job', required = true, maxLength = 50 } },
    values = { outputs = { { key = 'found', type = 'bool', label = 'Found' }, { key = 'name', type = 'text', label = 'Name' },
                           { key = 'owner', type = 'character', label = 'Owner' }, { key = 'roles', type = 'list', label = 'Roles' } } },
    value = function(ctx)
        local job = jobOf(ctx, 'job')
        if not job then return { found = false, name = '', roles = {} } end
        local roles = {}
        for _, r in ipairs(Jobs.getRoles(job.jobId) or {}) do
            if #roles >= C.MAX_LIST then break end
            roles[#roles + 1] = tostring(r.name or '')
        end
        return { found = true, name = tostring(job.name or job.key), owner = job.ownerCharId, roles = roles }
    end,
})

define({
    type = 'job.staffOnDuty', category = 'jobs', kind = 'value', title = 'On-Duty Staff', api = 'GetClockedOnEmployees',
    desc = 'The players on duty at a job now (its owner too, when they are), 64 at most.',
    props = { { key = 'job', kind = 'text', label = 'Job', required = true, maxLength = 50 } },
    values = { outputs = { { key = 'players', type = 'list', label = 'Players' }, { key = 'count', type = 'number', label = 'How many' } } },
    value = function(ctx)
        local job = jobOf(ctx, 'job')
        if not job then return nil, ('there is no job "%s"'):format(tostring(ctx:prop('job'))) end
        local ids = {}
        -- The charIds on duty (jobs.lua: bare numbers, the owner too).
        for _, charId in ipairs(Jobs.getClockedOnEmployees(job.jobId) or {}) do
            local p = PlayersByCharId[charId]
            if p then ids[#ids + 1] = p.source end
        end
        table.sort(ids)
        local list, n = playerList(ctx, ids)
        return { players = list, count = n }
    end,
})

-- Clocking on and off is THIS pulse's player's own, as a duty point's press is: no power. Clock On
-- keeps the job's own rule (a job that does not let people clock themselves on refuses), which the
-- export leaves to its callers (jobs.lua's ClockOn).
define({
    type = 'job.clockOn', category = 'jobs', kind = 'action', title = 'Clock On', api = 'ClockOn',
    desc = 'Puts THIS pulse\'s player on duty at a job (its key) they work at or own. A job that does not let people clock themselves on is Refused.',
    props = { { key = 'job', kind = 'text', label = 'Job', required = true, maxLength = 50 } },
    outputs = { 'out', 'refused' },
    labels = { refused = 'Refused' },
    run = function(ctx)
        local job = jobOf(ctx, 'job')
        if not job then ctx:log('there is no job "%s"', tostring(ctx:prop('job'))) return 'refused' end
        if not Jobs.allowsSelfClockOn(job.jobId) then ctx:log('%s does not let people clock themselves on', tostring(job.key)) return 'refused' end
        local src, p = playerOf(ctx, ctx:player())
        if not p then return 'refused' end
        local ok, why = Jobs.clockOn(p.charId, job.jobId, src)
        if not ok then ctx:log('clock on: %s', tostring(why)) return 'refused' end
        return 'out'
    end,
})

define({
    type = 'job.clockOff', category = 'jobs', kind = 'action', title = 'Clock Off', api = 'ClockOff',
    desc = 'Takes THIS pulse\'s player off duty at a job (its key), or, left empty, at every job.',
    props = { { key = 'job', kind = 'text', label = 'Job (empty: all)', maxLength = 50 } },
    run = function(ctx)
        local src, p = playerOf(ctx, ctx:player())
        if not p then return 'out' end
        local want = ctx:prop('job')
        if type(want) ~= 'string' or want == '' then Jobs.clockOffAll(p.charId, src) return 'out' end
        local job = jobOf(ctx, 'job')
        if job and Jobs.isClockedOn(p.charId, job.jobId) then Jobs.clockOff(p.charId, job.jobId, src) end
        return 'out'
    end,
})

-- ============================================
-- Items
-- ============================================

define({
    type = 'item.fits', category = 'items', kind = 'value', title = 'Will It Fit?', api = 'CanFitItem',
    desc = 'Yes or no: is there room on a player for this many of an item (slots and weight). Room says how many would fit.',
    props = { { key = 'item', kind = 'item', label = 'Item', required = true } },
    values = { inputs = { { key = 'player', type = 'player', label = 'Player' }, { key = 'amount', type = 'number', label = 'How many', default = 1 } },
               outputs = { { key = 'result', type = 'bool', label = 'Yes?' }, { key = 'room', type = 'number', label = 'Room for' } } },
    value = function(ctx)
        local item = ctx:prop('item')
        if not (Config.Items and Config.Items[item]) then return nil, ('%s is not an item on this server'):format(tostring(item)) end
        local _, p = playerOf(ctx, ctx:need('player'))
        if not p or not p.inventory then return { result = false, room = 0 } end
        local fits, room = Inventory.canFitItem(p.inventory, item, math.max(1, math.floor(ctx:need('amount'))))
        return { result = fits == true, room = tonumber(room) or 0 }
    end,
})

define({
    type = 'item.info', category = 'items', kind = 'value', title = 'Item Info', api = 'GetItemDef',
    desc = 'What an item is called and weighs, as this server defines it.',
    props = { { key = 'item', kind = 'item', label = 'Item', required = true } },
    values = { outputs = { { key = 'found', type = 'bool', label = 'Found' }, { key = 'name', type = 'text', label = 'Name' },
                           { key = 'weight', type = 'number', label = 'Weight' } } },
    value = function(ctx)
        local def = Config.Items and Config.Items[ctx:prop('item')]
        if not def then return { found = false, name = '', weight = 0 } end
        return { found = true, name = tostring(def.name or ctx:prop('item')), weight = tonumber(def.weight) or 0 }
    end,
})

-- ============================================
-- Stats and effects
-- ============================================

define({
    type = 'stat.get', category = 'players', kind = 'value', title = 'Their Stat', api = 'GetStat',
    desc = 'One of a player\'s stats now: health, armour, hunger, thirst, or one a resource added. Found is no for a stat this server does not have.',
    props = { { key = 'stat', kind = 'text', label = 'Stat', required = true, default = 'hunger', maxLength = 40 } },
    values = { inputs = { { key = 'player', type = 'player', label = 'Player' } },
               outputs = { { key = 'value', type = 'number', label = 'Value' }, { key = 'found', type = 'bool', label = 'Found' } } },
    value = function(ctx)
        local src = playerOf(ctx, ctx:need('player'))
        local v = src and Stats.get(src, ctx:prop('stat'))
        return { value = tonumber(v) or 0, found = v ~= nil }
    end,
})

define({
    type = 'effect.has', category = 'players', kind = 'value', title = 'Has Effect?', api = 'HasEffect',
    desc = 'Yes or no: is an effect on a player now (drunk, bleeding, or one a resource made).',
    props = { { key = 'effect', kind = 'text', label = 'Effect', required = true, maxLength = 64 } },
    values = { inputs = { { key = 'player', type = 'player', label = 'Player' } },
               outputs = { { key = 'result', type = 'bool', label = 'Yes?' } } },
    value = function(ctx)
        local src = playerOf(ctx, ctx:need('player'))
        return { result = src ~= nil and Stats.hasEffect(src, ctx:prop('effect')) == true }
    end,
})

-- ============================================
-- The world
-- ============================================

define({
    type = 'world.clock', category = 'world', kind = 'value', title = 'World Clock', api = { 'GetTime', 'GetWeather', 'IsTimeFrozen', 'IsBlackout', 'GetTimeScale' },
    desc = 'The game\'s time and weather now, as every player sees it.',
    values = { outputs = { { key = 'hour', type = 'number', label = 'Hour' }, { key = 'minute', type = 'number', label = 'Minute' },
                           { key = 'weather', type = 'text', label = 'Weather' }, { key = 'frozen', type = 'bool', label = 'Time stopped' },
                           { key = 'blackout', type = 'bool', label = 'Blackout' }, { key = 'speed', type = 'number', label = 'Clock speed (1 normal)' } } },
    value = function()
        local h, m = TimeWeather.now()
        local st = TimeWeather.state or {}
        return { hour = h, minute = m, weather = tostring(st.weather or ''), frozen = st.frozen == true, blackout = st.blackout == true,
                 speed = tonumber(st.timeScale) or 1 }
    end,
})

-- ============================================
-- Missions (the Director's runs)
-- ============================================

define({
    type = 'mission.isIn', category = 'missions', kind = 'value', title = 'In a Mission?', api = 'IsPlayerInScenarioRun',
    desc = 'Yes or no: is a player in a running mission: this one (its key), or, left empty, any. A builder\'s Test of a mission does not count.',
    props = { { key = 'mission', kind = 'text', label = 'Mission (empty: any)', maxLength = 64 } },
    values = { inputs = { { key = 'player', type = 'player', label = 'Player' } },
               outputs = { { key = 'result', type = 'bool', label = 'Yes?' } } },
    value = function(ctx)
        local src = playerOf(ctx, ctx:need('player'))
        if not src or not DirectorRuntime then return { result = false } end
        local key = ctx:prop('mission')
        if key == '' then key = nil end
        for _, run in ipairs(DirectorRuntime.list()) do
            if run.players and run.players[src] and not run.test and (key == nil or run.scenarioId == key) then return { result = true } end
        end
        return { result = false }
    end,
})
