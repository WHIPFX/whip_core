-- ============================================
-- Audience — one way to say "these players"
-- ============================================
--
-- Whoever something is FOR: who an NPC fights, who sees a point, who a blip is shown to. Every
-- module takes the same shape and reads it here, so a run's player list is written once:
--
--   'everyone'                                  every loaded player
--   { people = { 3, 7, { charId = 12 } } }      these: a server id, or a character (when online)
--   { job = 'police', onDuty = true }           a job's people: on duty there (onDuty), or all who
--                                               work there; only where it is asked for (jobOk)
--   { except = { 3, { charId = 12 } } }         every loaded player but these; only where it is asked
--                                               for (exceptOk: an NPC kept to a range round its post)
--
-- A server id counts only while it has a loaded character, and a character only while it is
-- online, so an audience can name someone who logs in later. At most 64 people.
--
-- A job audience is for what someone can see and press, a
-- blip and a point, which follow it as people clock on and off, are hired and fired (Jobs.onLife:
-- blips.lua, runtime_points.lua). Never who an NPC fights: guards target the run's players.

Audience = {}

local MAX_PEOPLE = 64

--- A list of people, cleaned: server ids and { charId = n }. Answers the list, or nil and why.
local function readPeople(list)
    local people = {}
    for i, who in ipairs(list) do
        if i > MAX_PEOPLE then return nil, ('an audience is at most %d people'):format(MAX_PEOPLE) end
        if type(who) == 'table' then
            local id = Sanitize.id(who.charId)
            if not id then return nil, 'a character is { charId = n }' end
            people[#people + 1] = { charId = id }
        else
            local s = Sanitize.id(who)
            if not s then return nil, 'a person is a server id or { charId = n }' end
            people[#people + 1] = s
        end
    end
    return people
end

--- Is player `src` (character `charId`) one of `people`?
local function named(people, src, charId)
    for _, who in ipairs(people) do
        if type(who) == 'table' then
            if who.charId == charId then return true end
        elseif who == src then
            return true
        end
    end
    return false
end

--- An audience from a caller, cleaned. Answers the audience, or nil when none was given, or false
--- and why. `everyoneOk` false refuses 'everyone' (who an NPC fights: never the whole server);
--- `jobOk` takes a job's people (where the module follows them as they change); `exceptOk` takes everyone
--- but some (an NPC that fights whoever is not a run's, round its post only: server/npcs.lua).
---@param a any
---@param everyoneOk boolean|nil
---@param jobOk boolean|nil
---@param exceptOk boolean|nil
---@return table|string|nil|false audience
---@return string|nil why
function Audience.read(a, everyoneOk, jobOk, exceptOk)
    if a == nil or a == false then return nil end
    if a == 'everyone' then
        if everyoneOk then return 'everyone' end
        return false, "'everyone' is not allowed here: name the people"
    end
    if type(a) == 'table' and a.except ~= nil then
        if not exceptOk then return false, 'everyone but some is not an audience here: name the people' end
        if type(a.except) ~= 'table' then return false, 'except is a list of people' end
        local people, why = readPeople(a.except)
        if not people then return false, why end
        return { except = people }
    end
    if type(a) == 'table' and a.job ~= nil then
        if not jobOk then return false, 'a job\'s people are not an audience here: name the people' end
        if type(a.job) ~= 'string' or not (Jobs and Jobs.getByKey and Jobs.getByKey(a.job)) then
            return false, ('no job called %s'):format(tostring(a.job))
        end
        if a.onDuty ~= nil and type(a.onDuty) ~= 'boolean' then return false, 'onDuty is true or false' end
        return { job = a.job, onDuty = a.onDuty == true }
    end
    if type(a) ~= 'table' or type(a.people) ~= 'table' then
        return false, "an audience is 'everyone', { people = { serverId | { charId = n }, ... } } or { job = 'police', onDuty = true }"
    end
    local people, why = readPeople(a.people)
    if not people then return false, why end
    return { people = people }
end

--- Is it everyone but some?
---@param a table|string|nil
---@return boolean
function Audience.isExcept(a)
    return type(a) == 'table' and a.except ~= nil
end

--- Is this character one of the job's people now (on duty there, when the audience says so)?
local function inJob(a, charId)
    local job = Jobs and Jobs.getByKey and Jobs.getByKey(a.job)
    if not job then return false end
    if a.onDuty then return Jobs.isClockedOn(charId, job.jobId) == true end
    return Jobs.getPlayerRole(charId, job.jobId) ~= nil
end

--- Is this player in it right now? A loaded character only.
---@param a table|string|nil  an audience from Audience.read
---@param src number
---@return boolean
function Audience.has(a, src)
    local p = Players and Players[src]
    if p == nil or p.charId == nil then return false end
    if a == 'everyone' then return true end
    if type(a) == 'table' and a.job ~= nil then return inJob(a, p.charId) end
    if type(a) == 'table' and a.except ~= nil then return not p.phantom and not named(a.except, src, p.charId) end
    if type(a) ~= 'table' or type(a.people) ~= 'table' then return false end
    return named(a.people, src, p.charId)
end

--- Is it a job's people (it changes as they clock on and off)?
---@param a table|string|nil
---@return boolean
function Audience.isJob(a)
    return type(a) == 'table' and a.job ~= nil
end

--- The server ids it names right now, as a set: [src] = true. Offline people are left out.
---@param a table|string|nil
---@return table<number, boolean>
function Audience.sources(a)
    local out = {}
    if a == 'everyone' or Audience.isJob(a) or Audience.isExcept(a) then
        local job, but = Audience.isJob(a), Audience.isExcept(a)
        for src, p in pairs(Players or {}) do
            if p.charId ~= nil and not p.phantom and (not job or inJob(a, p.charId))
                and not (but and named((a --[[@as table]]).except, src, p.charId)) then
                out[src] = true
            end
        end
        return out
    end
    if type(a) ~= 'table' or type(a.people) ~= 'table' then return out end
    for _, who in ipairs(a.people) do
        local charId, src = WhoIs(who)
        if charId and type(src) == 'number' then out[src] = true end   -- offline: WhoIs answers a reason
    end
    return out
end
