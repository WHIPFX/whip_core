-- ============================================
-- Update checks — server/updates.lua
-- ============================================
--
-- Is a newer release out on GitHub? For whip_core and any resource that names its repository in its fxmanifest.lua:
--
--     whip_updates 'WHIPFX/whip_phone'
--
-- whip_core asks GitHub for that repository's latest release and compares its tag with the resource's own `version`.
-- A newer one is said in the server console, in the setup report, by `whipupdates`, and to an admin turning
-- developer mode on. A resource reads its own result with GetUpdate.
--
-- WHAT LEAVES THE SERVER: one request per repository to api.github.com, asking for its latest release, with a generic
-- User-Agent. GitHub sees the server's address and which repositories it asked about; nothing else is sent.
-- `set whip_update_check false` in server.cfg turns the checks off.
--
-- GITHUB'S LIMIT is 60 requests an hour for an address without a token, shared with anything else on it (a 304 counts
-- too, without a token). So each repository is asked at most once every CHECK_HOURS (the answer is kept in a server KVP,
-- across restarts: WHIP's own resources are about 17 requests in 12 hours), the requests go one at a time, an unchanged
-- answer is asked with its ETag (a short 304 instead of the whole release), and a limit reached stops every check until
-- GitHub's reset.

Updates = {}

local CHECK_HOURS = 12
local FIRST_WAIT_MS = 30000   -- after whip_core is ready: the starts settle, and a start isn't slowed by it
local SPACING_MS = 1500       -- between two requests
local API = 'https://api.github.com/repos/%s/releases/latest'
local KVP = 'whip_core:update:'   -- .. repository: { tag, url, etag, at, problem }

--- [repository] = what GitHub last said, read from the KVP and kept up to date.
local known = {}
--- os.time() before which nothing is asked (GitHub's limit was reached), and whether that was said.
local pausedUntil, pauseSaid = 0, false
--- [resource .. ' ' .. tag] = true: a newer release already said in the console this run.
local said = {}
local checking = false

local function enabled()
    return GetConvar('whip_update_check', 'true') ~= 'false'
end

--- 'owner/repo' from a resource's whip_updates line (a github.com URL works too), or nil.
---@param res string
---@return string|nil
local function repositoryOf(res)
    local v = GetResourceMetadata(res, 'whip_updates', 0)
    if type(v) ~= 'string' then return nil end
    v = v:gsub('^%s+', ''):gsub('%s+$', ''):gsub('^https?://github%.com/', ''):gsub('%.git$', ''):gsub('/$', '')
    if v:match('^[%w%-%._]+/[%w%-%._]+$') then return v end
    return nil
end

local function versionOf(res)
    local v = GetResourceMetadata(res, 'version', 0)
    return type(v) == 'string' and v ~= '' and v or nil
end

--- The numbers in a version or tag: 'v1.2.0' and '1.2' both read as 1.2.0.
local function numbers(v)
    local out = {}
    for n in (tostring(v or ''):gsub('^[vV]', '')):gmatch('%d+') do out[#out + 1] = tonumber(n) end
    return out
end

--- Is `tag` a newer version than `current`? nil when either has no numbers to compare.
---@return boolean|nil
local function isNewer(tag, current)
    local a, b = numbers(tag), numbers(current)
    if #a == 0 or #b == 0 then return nil end
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x ~= y then return x > y end
    end
    return false
end

local function remember(repository, entry)
    known[repository] = entry
    SetResourceKvp(KVP .. repository, json.encode(entry))
end

local function recall(repository)
    if known[repository] == nil then
        local ok, entry = pcall(json.decode, GetResourceKvpString(KVP .. repository) or '')
        known[repository] = ok and type(entry) == 'table' and entry or false
    end
    return known[repository] or nil
end

--- A response header, whatever case GitHub sent it in.
local function header(headers, name)
    if type(headers) ~= 'table' then return nil end
    name = name:lower()
    for k, v in pairs(headers) do
        if type(k) == 'string' and k:lower() == name then return v end
    end
    return nil
end

--- Ask GitHub about one repository and keep the answer. Waits for it (call from a thread).
---@param repository string
local function ask(repository)
    local before = recall(repository) or {}
    local headers = {
        ['User-Agent'] = 'whip_core-update-check',
        ['Accept'] = 'application/vnd.github+json',
        ['X-GitHub-Api-Version'] = '2022-11-28',
    }
    if before.etag and before.tag then headers['If-None-Match'] = before.etag end

    local p = promise.new()
    PerformHttpRequest(API:format(repository), function(status, body, respHeaders)
        p:resolve({ status = tonumber(status) or 0, body = body, headers = respHeaders })
    end, 'GET', '', headers)
    local r = Citizen.Await(p)
    local now = os.time()

    if r.status == 200 then
        local ok, release = pcall(json.decode, r.body or '')
        if ok and type(release) == 'table' and type(release.tag_name) == 'string' then
            remember(repository, { tag = release.tag_name, url = release.html_url, etag = header(r.headers, 'etag'), at = now })
        else
            remember(repository, { tag = before.tag, url = before.url, at = now, problem = 'GitHub\'s answer could not be read' })
        end
    elseif r.status == 304 then
        before.at, before.problem = now, nil
        remember(repository, before)
    elseif r.status == 404 then
        -- Private, misspelt, or no release yet: asked again after CHECK_HOURS like any other answer.
        remember(repository, { at = now, problem = 'no public release (the repository is private, misspelt, or has none)' })
    elseif (r.status == 403 or r.status == 429) and header(r.headers, 'x-ratelimit-remaining') == '0' then
        pausedUntil = tonumber(header(r.headers, 'x-ratelimit-reset')) or (now + 3600)
    else
        -- Nothing kept: the next round asks again.
        known[repository] = before.at and before or false
        if before.at then before.problem = ('GitHub did not answer (%d)'):format(r.status) end
    end
end

--- Every resource that declares a repository: { resource, repository }, started ones only.
local function declared()
    local out = {}
    for i = 0, GetNumResources() - 1 do
        local res = GetResourceByFindIndex(i)
        local state = res and GetResourceState(res)
        if state == 'started' or state == 'starting' then
            local repository = repositoryOf(res)
            if repository then out[#out + 1] = { resource = res, repository = repository } end
        end
    end
    table.sort(out, function(a, b) return a.resource < b.resource end)
    return out
end

--- One resource's update status, from what GitHub last said; nil when it declares no repository.
---@param res string
---@return table|nil
function Updates.statusOf(res)
    local repository = repositoryOf(res)
    if not repository then return nil end
    local entry = recall(repository) or {}
    local current = versionOf(res)
    local newer = entry.tag ~= nil and current ~= nil and isNewer(entry.tag, current) == true
    return {
        resource = res, repository = repository, current = current, latest = entry.tag, url = entry.url,
        newer = newer, checkedAt = entry.at, problem = entry.problem,
    }
end

--- Every declared resource's status, by name.
---@return table[]
function Updates.all()
    local out = {}
    for _, d in ipairs(declared()) do out[#out + 1] = Updates.statusOf(d.resource) end
    return out
end

--- The resources with a newer release.
---@return table[]
function Updates.available()
    local out = {}
    for _, s in ipairs(Updates.all()) do
        if s.newer then out[#out + 1] = s end
    end
    return out
end

--- Check every declared repository that is due (or all of them with `force`), one at a time, then say what is newer.
--- Waits (call from a thread).
---@param force boolean|nil  ask even when the last answer is younger than CHECK_HOURS
function Updates.check(force)
    if checking or not enabled() then return end
    checking = true
    local asked, seen = 0, {}
    for _, d in ipairs(declared()) do
        if not seen[d.repository] then
            seen[d.repository] = true
            local entry = recall(d.repository)
            local due = force or not entry or not entry.at or os.time() - entry.at >= CHECK_HOURS * 3600
            if os.time() < pausedUntil then
                if not pauseSaid then
                    pauseSaid = true
                    print(('[whip] update checks paused: GitHub\'s limit for this address is reached until %s')
                        :format(os.date('%H:%M', pausedUntil)))
                end
                break
            end
            if due then
                if asked > 0 then Wait(SPACING_MS) end
                asked = asked + 1
                local ok, err = pcall(ask, d.repository)
                if not ok then print(('[whip] the update check for %s failed: %s'):format(d.repository, tostring(err))) end
            end
        end
    end
    pauseSaid = os.time() < pausedUntil and pauseSaid or false
    checking = false

    for _, s in ipairs(Updates.available()) do
        local key = s.resource .. ' ' .. s.latest
        if not said[key] then
            said[key] = true
            print(('^3[whip] update available: %s %s (this server has %s): %s^0')
                :format(s.resource, s.latest, s.current, s.url or ('https://github.com/' .. s.repository .. '/releases')))
        end
    end
end

--- For the setup report (server/setup_report.lua): its lines about updates.
---@param add fun(level: string, fmt: string, ...)
function Updates.reportLines(add)
    if not enabled() then
        add('note', 'Update checks are off (set whip_update_check false)')
        return
    end
    local all, newer, checked = Updates.all(), {}, 0
    for _, s in ipairs(all) do
        if s.newer then newer[#newer + 1] = s end
        if s.latest then checked = checked + 1 end
    end
    for _, s in ipairs(newer) do
        add('note', 'Update available: %s %s (this server has %s): %s', s.resource, s.latest, s.current or '?',
            s.url or ('https://github.com/' .. s.repository .. '/releases'))
    end
    if #newer == 0 and checked > 0 then
        add('ok', 'Up to date: %d resource%s checked on GitHub', checked, checked == 1 and '' or 's')
    end
end

-- The first round once the starts have settled, then every hour: a repository is only asked when its last answer is
-- older than CHECK_HOURS.
AddEventHandler('whip_core:onReady', function(info)
    if not info or info.reason ~= 'coreStarted' then return end
    CreateThread(function()
        Wait(FIRST_WAIT_MS)
        while true do
            Updates.check(false)
            Wait(3600000)
        end
    end)
end)

-- An admin turning developer mode on hears about updates once per session.
local told = {}
DevTools.onModeChange(function(source, on)
    if not on or told[source] then return end
    local n = #Updates.available()
    if n > 0 then
        told[source] = true
        NotifyPlayer(source, ('%d update%s available: type whipupdates in the server console'):format(n, n == 1 and ' is' or 's are'), 'info', 8000)
    end
end)
AddEventHandler('playerDropped', function() told[source] = nil end)

-- whipupdates: every declared resource and what GitHub said. whipupdates check: ask GitHub again now.
RegisterCommand('whipupdates', function(source, args)
    if source ~= 0 then return end
    CreateThread(function()
        if args[1] == 'check' then
            if not enabled() then print('[whip] update checks are off (set whip_update_check false)') return end
            print('[whip] asking GitHub...')
            Updates.check(true)
        end
        local all = Updates.all()
        if #all == 0 then
            print('[whip] no running resource names a repository (whip_updates \'owner/repo\' in its fxmanifest.lua)')
            return
        end
        for _, s in ipairs(all) do
            local state
            if s.newer then state = ('^3%s is out^0: %s'):format(s.latest, s.url or s.repository)
            elseif s.latest then state = ('^2up to date^0 (latest %s)'):format(s.latest)
            else state = s.problem or 'not checked yet' end
            local when = s.checkedAt and os.date('%Y-%m-%d %H:%M', s.checkedAt) or 'never'
            print(('[whip] %-28s %-9s %s  [%s, checked %s]'):format(s.resource, s.current or '?', state, s.repository, when))
        end
        if not enabled() then print('[whip] update checks are off (set whip_update_check false)') end
    end)
end, true)

--- Another resource's update status, or its own when `resource` is left out. nil when it declares no repository.
exports('GetUpdate', function(resource)
    resource = type(resource) == 'string' and resource or GetInvokingResource() or GetCurrentResourceName()
    return Updates.statusOf(resource)
end)

--- Every running resource that declares a repository, with its update status.
exports('GetUpdates', function()
    return Updates.all()
end)
