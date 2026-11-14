-- ============================================
-- SANITIZE — Reusable Input Validation Helpers
-- Strips malicious/invalid data from client events
-- ============================================

Sanitize = {}

--- Drop a character the byte cut left incomplete at the END of `s`, and nothing else.
---
--- Constant time: only the last character can have been split by the cut, so only the last four
--- bytes are looked at (utf8.len checks the WHOLE string, and backing off a byte at a time with it is
--- O(n²) on a long param).
---@param s string
---@return string
local function dropSplitTail(s)
    local n = #s
    local j = n
    -- Back over continuation bytes (10xxxxxx) to the start of the last character: at most 3.
    while j > 1 and j > n - 3 do
        local b = s:byte(j)
        if b < 0x80 or b >= 0xC0 then break end
        j = j - 1
    end
    local lead = s:byte(j)
    local need = lead >= 0xF0 and 4 or lead >= 0xE0 and 3 or lead >= 0xC0 and 2 or 1
    if j + need - 1 > n then return s:sub(1, j - 1) end
    return s
end

--- Sanitize a string value: strip control chars, limit length.
--- @param val any       Raw input
--- @param maxLen? number Max allowed length (none: no limit)
--- @param default? string Fallback if invalid (default '')
--- @return string
function Sanitize.string(val, maxLen, default)
    default = default or ''
    if type(val) ~= 'string' then return default end
    -- Far longer than allowed: cut first, so a client cannot make the server scan megabytes it will throw away
    if maxLen and #val > maxLen * 4 + 64 then val = val:sub(1, maxLen * 4 + 64) end
    -- Strip control characters (0x00-0x1F) except newline/tab
    val = val:gsub('[%z\1-\8\11\12\14-\31]', '')
    if maxLen and #val > maxLen then
        val = val:sub(1, maxLen)
        -- Never half a character: the cut is by bytes, and one landing inside a multi-byte
        -- character would leave an invalid tail. Backed off to the last whole one (dropSplitTail, above).
        val = dropSplitTail(val)
    end
    if val == '' then return default end
    return val
end

--- Sanitize a key identifier: alphanumeric, underscore, hyphen only.
--- @param val any       Raw input
--- @param maxLen? number Max length (default 60)
--- @return string|nil   nil if invalid
function Sanitize.key(val, maxLen)
    maxLen = maxLen or 60
    if type(val) ~= 'string' then return nil end
    val = val:gsub('[^%w_%-]', '')
    if #val == 0 then return nil end
    if #val > maxLen then val = val:sub(1, maxLen) end
    return val
end

--- Sanitize a number: reject NaN/inf, clamp to range.
--- @param val any       Raw input
--- @param min? number    Minimum allowed (default -1e12)
--- @param max? number    Maximum allowed (default 1e12)
--- @param default? number Fallback if invalid (default 0)
--- @return number
function Sanitize.number(val, min, max, default)
    default = default or 0
    min = min or -1e12
    max = max or 1e12
    val = tonumber(val)
    if not val or val ~= val or val == math.huge or val == -math.huge then
        -- THE FALLBACK IS HELD TO THE RANGE TOO. It was returned as-is, and with no default given
        -- it is 0 — so `{'amount', 'int', 1, 999}` handed the handler a 0 for NaN or garbage, the
        -- one value its declared minimum exists to keep out.
        val = default
    end
    if val < min then return min end
    if val > max then return max end
    return val
end

--- Sanitize an integer: same as number but floored.
--- @param val any       Raw input
--- @param min? number    Minimum allowed (default -1e12)
--- @param max? number    Maximum allowed (default 1e12)
--- @param default? number Fallback if invalid (default 0)
--- @return number
function Sanitize.int(val, min, max, default)
    return math.floor(Sanitize.number(val, min, max, default))
end

--- Resolve an ID — by REJECTING, never by clamping.
---
--- `int` clamps, which is right for a QUANTITY (ask for 1000 rounds, get the 200 that fit) and
--- exactly wrong for an ADDRESS: an id of 0 clamped to 1 unbanned ban #1, deleted vehicle #1 and
--- linked shops to job #1. An id is either the thing you named or nothing.
---
--- Numeric strings are accepted (NUI datasets arrive as text); fractions, NaN, infinities and
--- anything outside [min, max] are not.
--- @param val any
--- @param min number|nil  default 1
--- @param max number|nil  default unbounded
--- @return number|nil     nil when it is not a valid id
function Sanitize.id(val, min, max)
    local n = tonumber(val)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    if n ~= math.floor(n) then return nil end
    if n < (min or 1) then return nil end
    if max and n > max then return nil end
    return math.tointeger(n) or n
end

--- The refusal every item and bank export gives for a bad amount, word for word, so a caller (and a test)
--- can recognise it. A sentence, as a player may be shown it. (Money.charge / pay take 0 too: money.lua's own.)
Sanitize.AMOUNT_ERR = 'Amount must be a whole number of 1 or more'

--- An item AMOUNT: a whole number of 1 or more — or nil, which the caller turns into a refusal.
---
--- Refused, not corrected, and not the same rule as `int`: half a banknote, a negative amount or a
--- string must not reach an item export. The check every item, cash and bank call uses.
---
--- An omitted amount (nil) means `default`, which the callers set to 1 — "give them one". Numeric
--- strings are accepted, as they are for ids.
---@param val any
---@param default number|nil  used when val is nil
---@return integer|nil
function Sanitize.amount(val, default)
    if val == nil then val = default end
    return Sanitize.id(val)
end

--- Validate a value is in an allowed set.
--- @param val any          Raw input
--- @param allowed table    Array of valid values, e.g. {'garaged','out','impounded'}
--- @param default any      Fallback if not in set
--- @return any
function Sanitize.enum(val, allowed, default)
    for _, v in ipairs(allowed) do
        if val == v then return val end
    end
    return default
end
