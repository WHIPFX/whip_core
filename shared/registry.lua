-- ============================================
-- REGISTRY — one rule for everything a resource registers with whip
-- ============================================
--
-- whip keeps about forty registries (items, stats, secure events, panels, store kinds, context
-- actions, item flags...). They all follow one rule, implemented here:
--
--   * An entry belongs to the resource that registered it first. The owner is read at the call
--     (Registry.caller), never taken from an argument a caller could fill in.
--   * The same owner registering the same thing again does NOTHING. onReady re-fires, and a
--     re-run registration must not rebroadcast, re-seed or reset anything.
--   * The same owner registering something different REPLACES it.
--   * Another resource is REFUSED, with the owner's name in the reason. A resource that has
--     stopped no longer holds anything, so its names are free again.
--   * A resource's entries are swept when it stops (unless the registry says otherwise, as items
--     do: players are still carrying them).
--   * Every add and remove answers (true) or (false, reason).
--   * Removing only ever removes the caller's own entries.
--
-- Registry.list() answers "who registered what" for the /whip panel and for whip_test.
--
-- RUN TAGS. A registration may carry a TAG (`{ tag = 'run:42' }`):
-- the caller's label for "everything one scenario run made". Registry.releaseTag(owner, tag) removes
-- every entry that owner holds under that tag, in every registry, AND tells the modules that keep
-- their own owners (temp cars, ground rows, ...) through Registry.onRelease, in a fixed order. A
-- released tag is CLOSED for its owner: a later add under it is refused ("... has ended"), so a
-- spawn answered after its run was reset cannot leave something behind. Tags belong to the caller
-- like everything else here; a resource can only release its own.
--
-- SHARED: the server and the client each get their own copy, with their own registries.
--
-- It does not own the data's shape: most registries pass their existing table as `store`, so
-- readers read that table directly and only writes go through here.

Registry = {}

local CORE = GetCurrentResourceName()

--- [name] = registry, and the order they were created in, for Registry.list.
local _all   = {}
local _order = {}

--- Deep structural equality, with functions compared by identity.
---
--- A re-run registration rebuilds its tables, so identity alone would call every re-run a change.
--- A fresh closure still counts as changed (functions only compare by identity), which is cheap.
---
--- rawget, never `b[k]`: a satellite's function arrives as a table whose metatable throws on unknown
--- keys ("Cannot index a funcref").
---@return boolean
local function deepEquals(a, b, depth)
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    depth = (depth or 0) + 1
    if depth > 16 then return false end
    for k, v in next, a do
        if not deepEquals(v, rawget(b, k), depth) then return false end
    end
    for k in next, b do
        if rawget(a, k) == nil then return false end
    end
    return true
end
Registry.deepEquals = deepEquals

--- Who is calling. Read it FIRST THING in an export, before anything can yield: after a yield
--- GetInvokingResource no longer names the caller.
---@return string
function Registry.caller()
    return GetInvokingResource() or CORE
end

--- Can this owner still hold names? whip_core always; any other resource only while it runs.
---@param owner string
---@return boolean
local function alive(owner)
    if owner == CORE then return true end
    local state = GetResourceState(owner)
    return state == 'started' or state == 'starting'
end
Registry.alive = alive

-- ============================================
-- Run tags: closed tags
-- ============================================

--- [owner .. '\0' .. tag] = true once that owner's tag has been released.
local _closed = {}
--- [tag] = true once a tag has been released for EVERYONE (Registry.releaseTagEverywhere): a Director
--- run's, whose id is never used again.
local _closedAll = {}
--- [tag] = { [owner] = true }: who has made something under a tag, so all of it can go at once.
local _tagUsers = {}

local function closedKey(owner, tag) return owner .. '\0' .. tag end

--- Close a tag: from now on, adds under it by this owner are refused.
---@param owner string
---@param tag string
function Registry.closeTag(owner, tag)
    _closed[closedKey(owner, tag)] = true
end

---@param owner string
---@param tag string
---@return boolean
function Registry.isClosed(owner, tag)
    return _closedAll[tag] == true or _closed[closedKey(owner, tag)] == true
end

local function noteUser(owner, tag)
    local users = _tagUsers[tag]
    if not users then users = {}; _tagUsers[tag] = users end
    users[owner] = true
end

--- About to make something under `tag` for `owner` outside a registry (the tag-release joiners: a
--- skill check, a server bar, a temporary car): false when the tag has ended; otherwise it is noted
--- as theirs, so releasing the tag everywhere finds it.
---@return boolean open
function Registry.claimTag(owner, tag)
    if Registry.isClosed(owner, tag) then return false end
    noteUser(owner, tag)
    return true
end

--- A tag is a short, non-empty string ('run:42'). Answers a reason when it is not.
local function badTag(tag)
    if type(tag) ~= 'string' or tag == '' or #tag > 100 then return 'a tag is a short piece of text, like "run:42"' end
    return nil
end
Registry.badTag = badTag

---@class WhipRegistry
---@field name string
---@field label string
---@field entries table
---@field owners table
---@field tags table
---@field releaseOrder number
---@field scoped boolean
---@field shared boolean
---@field prefixed boolean
---@field reserved string|nil
---@field sweep boolean
---@field same (fun(old: any, new: any): boolean)|false|nil
---@field validate function|nil
---@field onAdd function|nil
---@field onRemove function|nil
local Reg = {}
Reg.__index = Reg

--- Make a registry.
---
--- opts:
---   label      string    what one entry is called in a reason: 'item', 'stat', 'event'
---   store      table     the table entries live in; defaults to a new one. Pass the table the
---                        rest of whip already reads, so nothing else has to change.
---   scoped     boolean   keys are '<owner>:<id>', so two resources may both use the same id
---                        without meeting. For listeners and hooks.
---   shared     boolean   several resources may hold the same key if they register the SAME
---                        value; it goes when the last of them stops. For sets (ignition keys).
---   reserved   string    a prefix only whip_core may register under ('whip_core:')
---   sweep      boolean   false keeps a stopped owner's entries (items); they are free to be
---                        taken over, but not deleted. Default true.
---   same       function|false  function(old, new) → boolean, the "nothing changed" test.
---                        Defaults to deep equality; false means every registration replaces.
---   validate   function  function(id, value, owner) → ok, reason; runs before anything else
---   onAdd      function  function(key, value, owner, old) — after an add or a replace
---   onRemove   function  function(key, value, owner, why) — why is 'removed', 'stopped' or
---                        'released' (its run tag was released). MUST NOT YIELD: a sweep or a
---                        release calls it in a loop; slow work goes in its own thread.
---   releaseOrder number  where this registry's entries go in a tag release (lower first);
---                        default 50. See Registry.releaseTag.
---   prefixed   boolean   one list for the whole server (items, stats, permissions): a key that does not
---                        start with its resource's name is warned about, once per resource (noteUnprefixed)
---@param name string  unique, shown by Registry.list
---@param opts table|nil
---@return WhipRegistry registry
function Registry.new(name, opts)
    opts = opts or {}
    local reg = setmetatable({
        name     = name,
        label    = opts.label or name,
        entries  = opts.store or {},
        owners   = {},   -- [key] = owner, or for a shared registry [key] = { [owner] = true }
        tags     = {},   -- [key] = the owner's run tag, for entries added with one
        releaseOrder = tonumber(opts.releaseOrder) or 50,
        scoped   = opts.scoped == true,
        shared   = opts.shared == true,
        prefixed = opts.prefixed == true,
        reserved = opts.reserved,
        sweep    = opts.sweep ~= false,
        same     = opts.same,
        validate = opts.validate,
        onAdd    = opts.onAdd,
        onRemove = opts.onRemove,
    }, Reg)

    if not _all[name] then _order[#_order + 1] = name end
    _all[name] = reg
    return reg
end

--- The key an owner's id is stored under.
---@param owner string
---@param id string|number
---@return string|number
function Reg:keyOf(owner, id)
    if self.scoped then return owner .. ':' .. tostring(id) end
    return id
end

-- A PREFIXED registry is one list for the whole server, first come first served, so a resource's keys should start
-- with its name ('mycafe_coffee', 'mycafe:tip', 'mycafe.manage'). One that does not is said once per resource and
-- registry, in one line a few seconds after its registrations settle: a warning, never a refusal. whip_core and
-- whip's own resources (whip_*) are exempt: their bare keys are whip's, listed in the docs.
local _unprefixed = {}   -- ['<registry>|<owner>'] = { list of keys }
local SEPARATORS = { ['_'] = true, [':'] = true, ['.'] = true, ['-'] = true }

local function noteUnprefixed(self, owner, id)
    if type(id) ~= 'string' or type(owner) ~= 'string' then return end
    if owner == CORE or owner:sub(1, 5) == 'whip_' then return end
    local o, k = owner:lower(), id:lower()
    if k:sub(1, #o) == o and SEPARATORS[k:sub(#o + 1, #o + 1)] then return end
    local slot = self.name .. '|' .. owner
    local keys = _unprefixed[slot]
    if keys then keys[#keys + 1] = id; return end
    keys = { id }
    _unprefixed[slot] = keys
    SetTimeout(3000, function()
        local shown = {}
        for i = 1, math.min(#keys, 5) do shown[i] = keys[i] end
        print(('^3[%s] %s registers %d %s%s whose names do not start with "%s" (%s%s). Every resource shares one list of them, so another may use the same name and whichever starts first wins: start yours with your resource\'s name, as "%s_%s"^0')
            :format(CORE, owner, #keys, self.label, #keys == 1 and '' or 's', owner, table.concat(shown, ', '),
                #keys > 5 and ', ...' or '', owner, keys[1]))
    end)
end

--- Is this value the same as what is there? (the no-op test)
local function unchanged(self, old, value)
    if self.same == false then return false end
    return (self.same or deepEquals)(old, value)
end

-- A refusal for a resource other than whip_core is said in the console (F8 on a game) once per reason, naming the
-- resource: most callers drop the answer, and a registration that silently did not happen is the hardest bug to
-- find. Registry.refusals() lists them for the setup report.
local _saidRefusal, _refusals = {}, {}

--- Say a refused registration once (Reg:add calls it for every refusal; an export's own checks may too).
---@param owner string|nil
---@param why any
function Registry.sayRefused(owner, why)
    -- whip_test asks for refusals on purpose, hundreds of them: its own report says which it got.
    if type(owner) ~= 'string' or owner == CORE or owner == 'whip_test' then return end
    local k = owner .. '|' .. tostring(why)
    if _saidRefusal[k] then return end
    _saidRefusal[k] = true
    _refusals[#_refusals + 1] = { owner = owner, why = tostring(why) }
    print(('^3[%s] %s: refused: %s^0'):format(CORE, owner, tostring(why)))   -- CORE: whip_core, or the satellite whose Whip.registry this is
end

--- Every refusal said so far: { { owner, why }, ... }.
---@return table[]
function Registry.refusals()
    return _refusals
end

--- Register `value` under `id` for `owner` (Reg:add, below, says a refusal).
local function addEntry(self, owner, id, value, opts)
    local tid = type(id)
    if (tid ~= 'string' and tid ~= 'number') or id == '' then
        return false, ('a %s needs a name (a string or a number)'):format(self.label)
    end
    if value == nil then
        return false, ('%s "%s": nothing to register'):format(self.label, tostring(id))
    end
    local tag = opts and opts.tag
    if tag ~= nil then
        local why = badTag(tag)
        if why then return false, ('%s "%s": %s'):format(self.label, tostring(id), why) end
        if self.shared then
            return false, ('%s "%s": this kind of registration cannot take a tag'):format(self.label, tostring(id))
        end
        if Registry.isClosed(owner, tag) then
            return false, ('%s "%s": %s has ended'):format(self.label, tostring(id), tag)
        end
        noteUser(owner, tag)
    end
    if self.validate then
        local ok, why = self.validate(id, value, owner)
        if not ok then return false, why end
    end
    if self.reserved and owner ~= CORE and tid == 'string'
        and id:sub(1, #self.reserved) == self.reserved then
        return false, ('%s "%s" is reserved: names starting "%s" belong to whip_core')
            :format(self.label, id, self.reserved)
    end

    local key = self:keyOf(owner, id)
    local old = self.entries[key]

    if self.shared then
        local holders = self.owners[key]
        if holders and old ~= nil and not unchanged(self, old, value) then
            for holder in pairs(holders) do
                if holder ~= owner and alive(holder) then
                    return false, ('%s "%s" is already registered differently by %s')
                        :format(self.label, tostring(id), holder)
                end
            end
        end
        if not holders then holders = {}; self.owners[key] = holders end
        local already = holders[owner] and old ~= nil and unchanged(self, old, value)
        holders[owner] = true
        if already then return true, key end
        self.entries[key] = value
        if self.onAdd then self.onAdd(key, value, owner, old) end
        return true, key
    end

    local current = self.owners[key]
    if old ~= nil and current ~= nil and current ~= owner and alive(current) then
        return false, ('%s "%s" belongs to %s'):format(self.label, tostring(id), current)
    end
    if old ~= nil and current == owner and unchanged(self, old, value) then
        self.tags[key] = tag   -- the same thing again: nothing to do, beyond following its tag
        return true, key
    end

    self.entries[key] = value
    self.owners[key]  = owner
    self.tags[key]    = tag
    if self.prefixed and current ~= owner then noteUnprefixed(self, owner, id) end
    if self.onAdd then self.onAdd(key, value, owner, old) end
    return true, key
end

--- Register `value` under `id` for `owner`.
---@param owner string   from Registry.caller(), read at the top of the export
---@param id string|number
---@param value any      nil is not a value; use remove
---@param opts table|nil { tag = 'run:42' }: the owner's run label (see RUN TAGS at the top)
---@return boolean ok
---@return string|number|nil keyOrReason  the stored key on success, the reason on refusal
function Reg:add(owner, id, value, opts)
    local ok, keyOrWhy = addEntry(self, owner, id, value, opts)
    if not ok then Registry.sayRefused(owner, keyOrWhy) end
    return ok, keyOrWhy
end

--- Take one of the caller's own entries out. Never someone else's.
---@param owner string
---@param id string|number
---@return boolean ok
---@return string|nil reason
function Reg:remove(owner, id)
    local key = self:keyOf(owner, id)
    local old = self.entries[key]
    if old == nil then
        return false, ('%s "%s" is not registered'):format(self.label, tostring(id))
    end

    if self.shared then
        local holders = self.owners[key]
        if not (holders and holders[owner]) then
            return false, ('%s "%s" was not registered by %s'):format(self.label, tostring(id), owner)
        end
        holders[owner] = nil
        if next(holders) then return true end
    else
        local current = self.owners[key]
        if current ~= owner then
            return false, ('%s "%s" belongs to %s'):format(self.label, tostring(id), tostring(current))
        end
    end

    self.entries[key] = nil
    self.owners[key]  = nil
    self.tags[key]    = nil
    if self.onRemove then self.onRemove(key, old, owner, 'removed') end
    return true
end

--- Everything one owner holds here under one tag: { key, ... }, in a fixed order.
---@param owner string
---@param tag string
---@return table keys
function Reg:keysTagged(owner, tag)
    local out = {}
    for key, t in pairs(self.tags) do
        if t == tag and self.owners[key] == owner then out[#out + 1] = key end
    end
    table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
    return out
end

--- Remove one owner's entries under one tag. The keys are taken first, so an onRemove that adds
--- something cannot upset the walk. Answers how many went.
---@param owner string
---@param tag string
---@return number count
function Reg:releaseTag(owner, tag)
    local n = 0
    for _, key in ipairs(self:keysTagged(owner, tag)) do
        local old = self.entries[key]
        if old ~= nil and self.owners[key] == owner and self.tags[key] == tag then
            self.entries[key] = nil
            self.owners[key]  = nil
            self.tags[key]    = nil
            n = n + 1
            if self.onRemove then self.onRemove(key, old, owner, 'released') end
        end
    end
    return n
end

--- Put an entry in place for whip_core without asking anyone (config seeds, re-seeding after a
--- sweep). Internal only: never reachable from an export.
---@param key string|number
---@param value any
function Reg:seed(key, value)
    local old = self.entries[key]
    self.entries[key] = value
    self.tags[key] = nil
    if self.shared then
        self.owners[key] = self.owners[key] or {}
        self.owners[key][CORE] = true
    else
        self.owners[key] = CORE
    end
    if self.onAdd then self.onAdd(key, value, CORE, old) end
end

--- Record who owns an entry that was put in the store some other way (config seeds loaded
--- before the registry existed). Internal only.
---@param key string|number
---@param owner string
function Reg:setOwner(key, owner)
    if self.shared then
        self.owners[key] = self.owners[key] or {}
        self.owners[key][owner] = true
    else
        self.owners[key] = owner
    end
end

---@param key string|number
---@return any value
function Reg:get(key) return self.entries[key] end

--- Who holds a key. For a shared registry, the first holder found.
---@param key string|number
---@return string|nil owner
function Reg:ownerOf(key)
    local o = self.owners[key]
    if type(o) == 'table' then return next(o) end
    return o
end

--- Everything one owner holds here: { key, ... }.
---@param owner string
---@return table keys
function Reg:keysOf(owner)
    local out = {}
    for key, o in pairs(self.owners) do
        if o == owner or (type(o) == 'table' and o[owner]) then out[#out + 1] = key end
    end
    return out
end

--- A stopping resource's entries go (or, with sweep = false, stop being held by it).
---
--- The keys are collected first, then removed: adding to a table during pairs() (an onRemove may) is
--- undefined in Lua and can end the walk early.
---@param res string
function Reg:sweepOwner(res)
    local keys = {}
    for key, o in pairs(self.owners) do
        if o == res or (self.shared and type(o) == 'table' and o[res]) then keys[#keys + 1] = key end
    end
    for _, key in ipairs(keys) do
        local o = self.owners[key]
        if self.shared and type(o) == 'table' and o[res] then
            o[res] = nil
            if not next(o) then
                local old = self.entries[key]
                self.entries[key] = nil
                self.owners[key]  = nil
                if self.onRemove then self.onRemove(key, old, res, 'stopped') end
            end
        elseif o == res then
            if self.sweep then
                local old = self.entries[key]
                self.entries[key] = nil
                self.owners[key]  = nil
                self.tags[key]    = nil
                if self.onRemove then self.onRemove(key, old, res, 'stopped') end
            end
            -- sweep = false: the entry stays and so does the owner's name on it, but alive()
            -- now answers false for that owner, so the next registrant may take it over.
        end
    end
end

-- The lists whip keeps by hand rather than as registries (listeners, client hooks, settings and dev pages, held
-- props): each shows itself in Registry.list, so GetRegistrations is everything a resource holds.
local _listers = {}   -- { { name, fn }, ... }

--- Show a hand-kept list with the registries. `fn()` answers { { key, owner }, ... }; it must not wait.
---@param name string
---@param fn function
function Registry.addLister(name, fn)
    _listers[#_listers + 1] = { name = name, fn = fn }
end

--- Every registration, optionally just one resource's: { { registry, key, owner }, ... }.
---@param resource string|nil
---@return table
function Registry.list(resource)
    local out = {}
    for _, name in ipairs(_order) do
        local reg = _all[name]
        for key, o in pairs(reg.owners) do
            if type(o) == 'table' then
                for holder in pairs(o) do
                    if not resource or holder == resource then
                        out[#out + 1] = { registry = name, key = key, owner = holder }
                    end
                end
            elseif not resource or o == resource then
                out[#out + 1] = { registry = name, key = key, owner = o }
            end
        end
    end
    for _, l in ipairs(_listers) do
        local ok, list = pcall(l.fn)
        if ok and type(list) == 'table' then
            for _, e in ipairs(list) do
                if not resource or e.owner == resource then
                    out[#out + 1] = { registry = l.name, key = e.key, owner = e.owner }
                end
            end
        end
    end
    return out
end

---@param name string
---@return table|nil
function Registry.get(name) return _all[name] end

-- ============================================
-- Run tags: releasing a whole run
-- ============================================

--- Modules that keep their own owners (temp cars, ground rows, door managers...) join a release here.
--- [i] = { name, order, release = fn(owner, tag) -> count, list = fn(owner, tag) -> { {registry, key} } }
local _releasers = {}

--- Join tag releases. whip_core files only; `release` must not yield (slow work in its own thread).
---@param name string    shown in ListTagged and in a failure print
---@param order number   lower goes first (registries default to 50)
---@param release fun(owner: string, tag: string): number
---@param list fun(owner: string, tag: string): table|nil
function Registry.onRelease(name, order, release, list)
    for _, r in ipairs(_releasers) do
        if r.name == name then r.order, r.release, r.list = order, release, list return end
    end
    _releasers[#_releasers + 1] = { name = name, order = tonumber(order) or 50, release = release, list = list, seq = #_releasers + 1 }
end

--- Every participant in a release, lowest order first (ties: registries in creation order, then joiners).
local function participants()
    local parts = {}
    for i, name in ipairs(_order) do
        local reg = _all[name]
        parts[#parts + 1] = { order = reg.releaseOrder, seq = i, name = name, reg = reg }
    end
    for _, r in ipairs(_releasers) do
        parts[#parts + 1] = { order = r.order, seq = 100000 + r.seq, name = r.name, joiner = r }
    end
    table.sort(parts, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.seq < b.seq
    end)
    return parts
end

--- Remove everything `owner` holds under `tag`, everywhere, and close the tag. A participant that
--- throws is printed and skipped; the rest still go.
---@param owner string
---@param tag string
---@return number count
function Registry.releaseTag(owner, tag)
    -- Closed tags are kept until whip_core restarts, so keep them small: no per-owner entry for a tag
    -- closed for everyone, and an owner whose share is gone is dropped from the tag's users.
    if not _closedAll[tag] then Registry.closeTag(owner, tag) end
    local users = _tagUsers[tag]
    if users then
        users[owner] = nil
        if next(users) == nil then _tagUsers[tag] = nil end
    end
    local total = 0
    for _, p in ipairs(participants()) do
        local ok, n
        if p.reg then
            ok, n = pcall(p.reg.releaseTag, p.reg, owner, tag)
        else
            ok, n = pcall(p.joiner.release, owner, tag)
        end
        if ok then
            total = total + (tonumber(n) or 0)
        else
            print(('[whip_core:registry] releasing %s for %s / %s failed: %s'):format(p.name, owner, tag, tostring(n)))
        end
    end
    return total
end

--- Remove everything EVERY owner made under `tag`, and close it for everyone: later creates under it
--- are refused whoever asks. For a Director run's tag: a police script
--- that put up a blip with the run's tag sees it go with the run, with nothing to do itself.
---@param tag string
---@return number count
function Registry.releaseTagEverywhere(tag)
    _closedAll[tag] = true
    local users = _tagUsers[tag] or {}
    _tagUsers[tag] = nil
    users[CORE] = true
    local owners = {}
    for owner in pairs(users) do owners[#owners + 1] = owner end
    table.sort(owners)
    local total = 0
    for _, owner in ipairs(owners) do total = total + Registry.releaseTag(owner, tag) end
    return total
end

--- What `owner` holds under `tag`: { { registry, key }, ... }.
---@param owner string
---@param tag string
---@return table
function Registry.listTagged(owner, tag)
    local out = {}
    for _, p in ipairs(participants()) do
        if p.reg then
            for _, key in ipairs(p.reg:keysTagged(owner, tag)) do out[#out + 1] = { registry = p.name, key = key } end
        elseif p.joiner.list then
            local ok, list = pcall(p.joiner.list, owner, tag)
            if ok and type(list) == 'table' then
                for _, e in ipairs(list) do out[#out + 1] = { registry = p.name, key = e.key } end
            end
        end
    end
    return out
end

--- Remove everything YOU hold under one run tag, in every whip module, and close the tag: later
--- creates under it are refused ("... has ended"). Use a new tag for each run.
exports('ReleaseTag', function(tag)
    local owner = Registry.caller()
    local why = badTag(tag)
    if why then return false, why end
    return true, Registry.releaseTag(owner, tag)
end)

--- What you hold under one run tag: { { registry, key }, ... }.
exports('ListTagged', function(tag)
    local owner = Registry.caller()
    if badTag(tag) then return {} end
    return Registry.listTagged(owner, tag)
end)

--- Everything registered with whip on this side (server or client), or one resource's share of
--- it: { { registry, key, owner }, ... }. For admin tools, tests, and a satellite checking itself.
exports('GetRegistrations', function(resource)
    if resource ~= nil and type(resource) ~= 'string' then return {} end
    return Registry.list(resource)
end)

-- One sweep for every registry. whip_core stopping is not swept: its whole state goes with it.
-- A stopped resource's closed tags are forgotten too, so it may reuse its labels when it is back.
AddEventHandler('onResourceStop', function(res)
    if res == CORE then return end
    for _, name in ipairs(_order) do
        local ok, err = pcall(_all[name].sweepOwner, _all[name], res)
        if not ok then
            print(('[whip_core:registry] sweeping %s for %s failed: %s'):format(name, res, tostring(err)))
        end
    end
    local prefix = res .. '\0'
    for k in pairs(_closed) do
        if k:sub(1, #prefix) == prefix then _closed[k] = nil end
    end
end)
