-- ============================================
-- Player flags — what a character has done, kept for good
-- ============================================
--
-- A flag is a named fact about one CHARACTER that outlives a run and a restart: "met the fence",
-- "jobs done: 3", "betrayed Lester". A scenario sets them (Set Player Flag) and asks them (If Player
-- Flag, and a Dialog Line answer's "Only if"); any resource can, through the exports:
--
--   exports.whip_core:SetPlayerFlag(source, 'met_fence', true)
--   exports.whip_core:GetPlayerFlag(source, 'met_fence')       --> true
--   exports.whip_core:SetPlayerFlag(source, 'jobs_done', 3)
--   exports.whip_core:SetPlayerFlag(source, 'met_fence', nil)  --> cleared (false clears too)
--
-- KEPT IN THE CHARACTER'S METADATA (key FLAGS_KEY), so a flag is saved the one way whip saves a
-- character (the player unit: with the action that set it), and reads cost no database wait. That is
-- also why only an ONLINE character's flags can be read or set: an offline one's metadata is not in
-- memory. The player's own game is sent its metadata (the client's GetPlayer), so a flag is no secret from
-- the player it is about; nobody else sees it.
--
--   name   letters, digits and _ . - : (at most 64), starting with a letter. Names starting with _
--          are whip's own (a Dialog Line's "once ever" answers) and cannot be set through the exports.
--   value  true, a number, or text (at most 100 characters). nil or false clears the flag.
--   at most MAX_FLAGS per character.

PlayerFlags = {}

local FLAGS_KEY = 'whipFlags'
local MAX_FLAGS = 256
local NAME_MAX  = 64
local TEXT_MAX  = 100

--- Is this a flag name? `internal` lets whip's own names (starting with _) through.
---@param name any
---@param internal boolean|nil
---@return boolean
function PlayerFlags.validName(name, internal)
    if type(name) ~= 'string' or #name == 0 or #name > NAME_MAX then return false end
    if name:match('^[%a][%w_.:%-]*$') then return true end
    return internal == true and name:match('^_[%w_.:%-]+$') ~= nil
end

--- A value as kept: true, a finite number, or text; nil for "cleared" (nil and false). Second answer:
--- why a value cannot be kept.
local function readValue(v)
    if v == nil or v == false then return nil end
    if v == true then return true end
    if type(v) == 'number' then
        if v ~= v or v == math.huge or v == -math.huge then return nil, 'a flag cannot hold that number' end
        return v
    end
    if type(v) == 'string' then
        if #v > TEXT_MAX then return nil, ('a flag holds at most %d characters of text'):format(TEXT_MAX) end
        return v
    end
    return nil, 'a flag holds true, a number or text'
end

local function playerOf(src)
    local p = src and Players[src]
    if not p or not p.charId then return nil end
    return p
end

local function flagsOf(p)
    local t = p.metadata and p.metadata[FLAGS_KEY]
    return type(t) == 'table' and t or nil
end

--- One flag's value, or nil (not set, or the player is not on a character).
---@param src number
---@param name string
---@return any
function PlayerFlags.get(src, name)
    local p = playerOf(src)
    local t = p and flagsOf(p)
    if not t or type(name) ~= 'string' then return nil end
    return t[name]
end

--- Every flag a character has, as a copy ({} when none).
---@param src number
---@param internal boolean|nil  include whip's own (_ names)
---@return table
function PlayerFlags.all(src, internal)
    local out = {}
    local p = playerOf(src)
    for k, v in pairs(p and flagsOf(p) or {}) do
        if internal or k:sub(1, 1) ~= '_' then out[k] = v end
    end
    return out
end

--- Set (or clear, with nil or false) one flag. Saved with the character, and told to whoever listens
--- (`whip_core:flag:changed`).
---@param src number
---@param name string
---@param value any
---@param internal boolean|nil  whip's own names (_...) allowed
---@return boolean ok
---@return string|nil why
function PlayerFlags.set(src, name, value, internal)
    local p = playerOf(src)
    if not p then return false, 'they are not on a character' end
    if not PlayerFlags.validName(name, internal) then
        return false, ('a flag name is letters, digits and _ . - : (at most %d), starting with a letter'):format(NAME_MAX)
    end
    local v, why = readValue(value)
    if why then return false, why end
    local old = flagsOf(p) or {}
    if old[name] == v then return true end
    -- A new table each time: setMetadata is the one way metadata is saved, and it is handed the whole.
    local nextFlags, n = {}, 0
    for k, x in pairs(old) do
        if k ~= name then nextFlags[k] = x; n = n + 1 end
    end
    if v ~= nil then
        if n >= MAX_FLAGS then return false, ('a character holds at most %d flags'):format(MAX_FLAGS) end
        nextFlags[name] = v
    end
    local ok, err = p:setMetadata(FLAGS_KEY, next(nextFlags) and nextFlags or nil)
    if not ok then return false, err end
    WhipEmit('whip_core:flag:changed', { source = src, charId = p.charId, name = name, value = v, was = old[name] })
    return true
end

-- ============================================
-- Exports
-- ============================================

---@return number|nil src
---@return string|nil why
local function sourceOf(who)
    local charId, src = WhoIs(who)
    if not charId then return nil, src --[[@as string|nil]] end
    -- (With a charId, WhoIs answers their source or nil, not a why.)
    ---@cast src number|nil
    if not src then return nil, 'they are not online: flags are read and set while the character is on' end
    return src
end

--- A flag of a character who is on: GetPlayerFlag(who, name) -> value | nil.
exports('GetPlayerFlag', function(who, name)
    local src = sourceOf(who)
    if not src or not PlayerFlags.validName(name) then return nil end
    return PlayerFlags.get(src, name)
end)

--- All of a character's flags (whip's own left out): GetPlayerFlags(who) -> { [name] = value } | nil.
exports('GetPlayerFlags', function(who)
    local src = sourceOf(who)
    if not src then return nil end
    return PlayerFlags.all(src)
end)

--- Set or clear a flag: SetPlayerFlag(who, name, value) -> true | false, why. nil or false clears it.
exports('SetPlayerFlag', function(who, name, value)
    local src, why = sourceOf(who)
    if not src then return false, why end
    return PlayerFlags.set(src, name, value)
end)
