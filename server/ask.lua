-- ============================================
-- Server-driven questions (the Systems Creator's Ask cards)
-- ============================================
--
-- `Confirm` and `Input` are client exports: the player's own game asks, and its answer is a client
-- claim. That is the right shape for a satellite's own screens. A SYSTEM runs on the server, and when
-- one of its cards asks a player "Wash your car for $25?" the server is the one waiting, so the
-- question goes out and the answer comes back over the token bridge the skill check and the server
-- bar already use (server/skillcheck.lua, server/timed_action.lua):
--
--   1. A one-shot TOKEN. A client cannot answer a question nobody asked it, or answer one twice.
--   2. ONE AT A TIME per player, held here: a second question while one is up answers 'busy'.
--   3. A TIMEOUT, which also takes the dialog off their screen.
--   4. THE SAME CHARACTER: an answer from the character picked after a logout is refused.
--   5. THE ANSWER IS CHECKED against what was asked: a form's number inside its min and max, a pick
--      one of its options, a required field filled in. An answer that is not one is refused as a
--      whole ('bad answer'), never corrected.
--
-- WHAT IT DOES NOT DEFEND: the answer is still what the player says. A Yes is a Yes; a typed "50" is
-- 50. Nothing of value should hang on a typed number without the server checking it means something
-- (the Sell card charges what the system says, never what the player typed).
--
-- A `tag` ties the question to a run, as the bar's and the check's do: ReleaseTag(tag) (a system
-- switched off) answers 'cancelled' and takes the dialog down.

local Ask = {}

--- token -> { source, session, promise, done, owner, tag, kind, fields, payload, viaOwner (a channel delivered it) }
local _pending = {}
local _nextToken = 0

-- ============================================
-- Channels: somewhere else to ask than whip_core's own dialog
-- ============================================
--
-- A Director job invite rings the player's PHONE like an incoming call (Accept / Decline) when
-- whip_phone is running, and is asked on screen when it is not. whip_core calls no satellite, so the phone
-- REGISTERS a channel here (RegisterAskChannel), and a question asked with `opts.via = '<channel>'` is offered to it
-- first: deliver(source, token, kind, payload) answers true when it took the question (the player carries a phone
-- that can be used). Anything else (not taken, an error, the channel's resource stopped) asks on screen as always.
--
-- THE SAME QUESTION EITHER WAY: the token, the one-at-a-time rule, the timeout and the run tag are this file's. A
-- cancel still sends whip_core:client:serverAskCancel (the channel's own client listens to it too), and the answer
-- comes back through AnswerAsk, which only the resource that delivered the question may give, checked as the
-- dialog's answer is (the same player, the same character).
--
-- A channel that goes takes its questions' screen with it, not the questions: its questions still waiting are
-- asked on screen then, the same token, as if never sent.
local _channels = Registry.new('askChannel', {
    label = 'ask channel',
    onRemove = function(_, value)
        for token, entry in pairs(_pending) do
            if not entry.done and value and entry.viaOwner == value.owner then
                entry.viaOwner = nil
                TriggerClientEvent('whip_core:client:serverAsk', entry.source, token, entry.kind, entry.payload)
            end
        end
    end,
})

--- RegisterAskChannel(name, deliver): somewhere else a question can be asked (whip_phone's 'phone'). deliver is
--- called with (source, token, kind, payload) and answers true when it showed the question; the answer then comes
--- back through AnswerAsk. Yours until your resource stops; another running resource's name is refused.
exports('RegisterAskChannel', function(name, deliver)
    local owner = Registry.caller()
    if type(name) ~= 'string' or #name > 32 or not name:match('^[%w_%-]+$') then
        return false, 'name is a short word: letters, digits, _ or -'
    end
    if deliver == nil then return false, 'deliver is the function that shows a question' end
    local ok, why = _channels:add(owner, name, { owner = owner, deliver = deliver })
    if not ok then return false, why end
    return true
end)

local TIMEOUT_DEFAULT_MS = 30000
local TIMEOUT_MIN_MS, TIMEOUT_MAX_MS = 5000, 120000
local MAX_FIELDS = 6
local MAX_OPTIONS = 20
local FIELD_TYPES = { text = true, number = true, checkbox = true, select = true }

local function finite(n) return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge end

--- Text for the dialog: a string, cut to `max` bytes (never splitting a character), or the fallback.
local function words(v, max, fallback)
    if type(v) ~= 'string' or v == '' then return fallback end
    if #v <= max then return v end
    local i = max
    while i > 0 do
        local b = v:byte(i + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end
        i = i - 1
    end
    return v:sub(1, i)
end

--- One form field, cleaned: what the dialog shows and what the answer is held to. Nil and why when it
--- cannot be asked.
local function cleanField(f, i)
    if type(f) ~= 'table' then return nil, ('field %d is not a table'):format(i) end
    local t = f.type or 'text'
    if not FIELD_TYPES[t] then return nil, ('field %d: type is text, number, checkbox or select'):format(i) end
    local out = { type = t, label = words(f.label, 60, 'Field ' .. i), placeholder = words(f.placeholder, 80, nil),
                  required = f.required == true }
    if t == 'text' then
        out.maxLen = math.max(1, math.min(500, math.floor(tonumber(f.maxLen) or 100)))
        if f.default ~= nil then out.default = words(tostring(f.default), out.maxLen, nil) end
    elseif t == 'number' then
        if f.min ~= nil then if not finite(f.min) then return nil, ('field %d: min is a number'):format(i) end out.min = f.min end
        if f.max ~= nil then if not finite(f.max) then return nil, ('field %d: max is a number'):format(i) end out.max = f.max end
        if out.min and out.max and out.min > out.max then return nil, ('field %d: min is more than max'):format(i) end
        if finite(f.default) then out.default = f.default end
        -- The page sends an empty number as 0, and checks the range only when something is typed: a
        -- field where 0 is out of range is made required, so an honest empty one is never refused.
        if (out.min and out.min > 0) or (out.max and out.max < 0) then out.required = true end
    elseif t == 'checkbox' then
        out.default = f.default == true
        out.required = false
    else
        if type(f.options) ~= 'table' or #f.options == 0 then return nil, ('field %d: a select needs options'):format(i) end
        if #f.options > MAX_OPTIONS then return nil, ('field %d: %d options at most'):format(i, MAX_OPTIONS) end
        out.options = {}
        for j, o in ipairs(f.options) do
            local value, label
            if type(o) == 'table' then value, label = o.value, o.label else value, label = o, o end
            value = words(value ~= nil and tostring(value) or nil, 60, nil)
            if not value then return nil, ('field %d: option %d has no value'):format(i, j) end
            out.options[j] = { value = value, label = words(label ~= nil and tostring(label) or nil, 60, value) }
        end
        out.default = out.options[1].value
        if f.default ~= nil then
            for _, o in ipairs(out.options) do if o.value == tostring(f.default) then out.default = o.value end end
        end
        out.required = false
    end
    return out
end

--- What the client is sent, from the caller's spec. Nil and why when it cannot be asked.
local function cleanSpec(spec)
    if type(spec) ~= 'table' then return nil, 'the question is a table' end
    if spec.kind == 'confirm' then
        return { kind = 'confirm', title = words(spec.title, 80, 'Question'), message = words(spec.message, 400, ''),
                 yes = words(spec.yes, 24, 'Yes'), no = words(spec.no, 24, 'No') }
    elseif spec.kind == 'form' then
        if type(spec.fields) ~= 'table' or #spec.fields == 0 then return nil, 'a form needs at least one field' end
        if #spec.fields > MAX_FIELDS then return nil, ('a form has %d fields at most'):format(MAX_FIELDS) end
        local fields = {}
        for i, f in ipairs(spec.fields) do
            local cf, why = cleanField(f, i)
            if not cf then return nil, why end
            fields[i] = cf
        end
        return { kind = 'form', title = words(spec.title, 80, 'Question'), fields = fields }
    end
    return nil, 'kind is confirm or form'
end

--- The client's form answer, held to the fields asked: the values, or nil and why.
local function checkAnswer(fields, value)
    if type(value) ~= 'table' then return nil, 'not a list' end
    for k in pairs(value) do
        if math.type(k) ~= 'integer' or k < 1 or k > #fields then return nil, 'more answers than fields' end
    end
    local out = {}
    for i, f in ipairs(fields) do
        local v = value[i]
        if f.type == 'checkbox' then
            if type(v) ~= 'boolean' then return nil, ('field %d is not yes or no'):format(i) end
            out[i] = v
        elseif f.type == 'number' then
            if not finite(v) then return nil, ('field %d is not a number'):format(i) end
            if (f.min and v < f.min) or (f.max and v > f.max) then return nil, ('field %d is out of range'):format(i) end
            out[i] = v
        elseif f.type == 'select' then
            local hit = nil
            for _, o in ipairs(f.options) do if o.value == v then hit = o.value end end
            if not hit then return nil, ('field %d is not one of its options'):format(i) end
            out[i] = hit
        else
            if type(v) ~= 'string' then return nil, ('field %d is not text'):format(i) end
            -- Cut, not refused: the dialog has no length limit of its own to hold the player to.
            v = words(v, f.maxLen, '')
            if f.required and v:match('^%s*$') then return nil, ('field %d is required'):format(i) end
            out[i] = v
        end
    end
    -- A list shorter than the fields fails above, at its first missing answer.
    return out
end

--- Ask a player a question on their screen and wait for the answer.
---
--- Blocks the calling coroutine until they answer, the answer is refused, it times out, or it is
--- called off. Safe from a SecureEvent handler or a thread; never from a SecureCallback with a long
--- timeout (the client's callback stops listening after 10 s: run it from an event, as the skill
--- check says).
---
--- spec: { kind = 'confirm', title, message, yes, no }
---    or { kind = 'form', title, fields = { { label, type = 'text'|'number'|'checkbox'|'select',
---           placeholder, default, required, min, max, maxLen, options = { 'a', { value, label } } } } }
--- opts: { timeoutMs (5-120 s, default 30 s), tag, onOpen = function(token), via = 'phone' } — onOpen is told the
---       token once the question is on its way, so a caller can call it off (Ask.cancel). via: offer a confirm to
---       that channel first (Channels above); on screen when it does not take it.
---
--- ANSWERS `true, value`: for a confirm, value is true (Yes) or false (No, or Escape); for a form,
--- the list of answers in field order. OR `false, why`: 'busy', 'cancelled', 'timeout', 'dead',
--- 'player left', 'run ended', 'bad answer', 'Player not loaded', or a sentence naming a bad spec.
---@param source number
---@param spec table
---@param opts table|nil
---@param owner string|nil  the resource asking; default whip_core
---@return boolean answered
---@return any value_or_why
function Ask.run(source, spec, opts, owner)
    local id = tonumber(source)
    local who = id and Players[id]
    if not id or not who or who.closing then return false, 'Player not loaded' end
    source = id
    if who.isDead then return false, 'dead' end
    if opts ~= nil and type(opts) ~= 'table' then return false, 'opts must be a table' end
    opts = opts or {}
    owner = owner or GetCurrentResourceName()
    local clean, bad = cleanSpec(spec)
    if not clean then return false, bad end
    local tag = opts.tag
    if tag ~= nil and (type(tag) ~= 'string' or tag == '') then return false, 'opts.tag is the run tag, a string' end
    if opts.via ~= nil and type(opts.via) ~= 'string' then return false, 'opts.via is a channel name' end
    if tag ~= nil and not Registry.claimTag(owner, tag) then return false, 'run ended' end

    for _, entry in pairs(_pending) do
        if entry.source == source and not entry.done then return false, 'busy' end
    end

    local timeoutMs = tonumber(opts.timeoutMs)
    if finite(timeoutMs) and timeoutMs > 0 then
        timeoutMs = math.floor(math.max(TIMEOUT_MIN_MS, math.min(TIMEOUT_MAX_MS, timeoutMs)))
    else
        timeoutMs = TIMEOUT_DEFAULT_MS
    end

    _nextToken = _nextToken + 1
    local token = _nextToken
    local p = promise.new()
    local entry = { source = source, session = who.session, promise = p, done = false, owner = owner, tag = tag,
                    kind = clean.kind, fields = clean.fields }
    _pending[token] = entry

    local payload = clean.kind == 'confirm'
        and { title = clean.title, message = clean.message, yes = clean.yes, no = clean.no }
        or { title = clean.title, fields = clean.fields }
    entry.payload = payload   -- kept: asked on screen after all if its channel goes (_channels onRemove)

    -- Offered to a channel first when asked to (a confirm only), else on screen.
    local channel = clean.kind == 'confirm' and opts.via and _channels:get(opts.via)
    if channel and Registry.alive(channel.owner) then
        local ok, took = pcall(channel.deliver, source, token, clean.kind, payload)
        if not ok then
            print(('^3[whip_core:ask] the %s channel failed (asked on screen instead): %s^0'):format(opts.via, tostring(took)))
        elseif took == true then
            entry.viaOwner = channel.owner
        end
    end
    if not entry.viaOwner then
        TriggerClientEvent('whip_core:client:serverAsk', source, token, clean.kind, payload)
    end

    if type(opts.onOpen) == 'function' then
        local ok, err = pcall(opts.onOpen, token)
        if not ok then print(('[whip_core:ask] onOpen failed: %s'):format(tostring(err))) end
    end

    SetTimeout(timeoutMs, function()
        if not entry.done then
            entry.done = true
            _pending[token] = nil
            p:resolve({ false, 'timeout' })
            TriggerClientEvent('whip_core:client:serverAskCancel', entry.source, token)
        end
    end)

    local r = Citizen.Await(p)
    _pending[token] = nil
    if type(r) == 'table' and r[1] == true then return true, r[2] end
    return false, (type(r) == 'table' and r[2]) or 'cancelled'
end

--- Call off a question still waiting (the caller gave up: its own clock, its run's end). It answers
--- `why` (default 'cancelled') and comes off the player's screen. Never waits.
---@param token number
---@param why string|nil
---@return boolean ended  false when it was already answered
function Ask.cancel(token, why)
    local entry = _pending[token]
    if not entry or entry.done then return false end
    entry.done = true
    _pending[token] = nil
    entry.promise:resolve({ false, type(why) == 'string' and why or 'cancelled' })
    TriggerClientEvent('whip_core:client:serverAskCancel', entry.source, token)
    return true
end

--- AnswerAsk(source, token, yes): the answer to a question a channel showed (RegisterAskChannel), from that
--- channel's resource only, for the player it was asked of and the character still playing. A confirm only:
--- yes = true (Accept) or false (Decline). Answers true, or false and why.
exports('AnswerAsk', function(source, token, yes)
    local caller = Registry.caller()
    source, token = tonumber(source), tonumber(token)
    local entry = token and _pending[token]
    if not token or not entry or entry.done or entry.source ~= source then return false, 'That question is gone' end
    if entry.viaOwner ~= caller then return false, 'That question was not asked through you' end
    local player = Players[source]
    if entry.session ~= nil and (not player or player.session ~= entry.session) then
        return false, 'That question was for another character'
    end
    entry.done = true
    _pending[token] = nil
    if player and player.isDead then
        entry.promise:resolve({ false, 'dead' })
        return true
    end
    entry.promise:resolve({ true, yes == true })
    return true
end)

--- The client's answer. `answered` false carries the dialog's own words (`why`); true carries the
--- value: a bool for a confirm, the list of answers for a form.
SecureEvent('whip_core:server:askAnswer', {
    rateLimit = 250,
    -- A player who dies with the dialog up still answers, so the caller is not left to its timeout.
    -- An answer from the floor counts for nothing ('dead', below).
    whileDead = true,
    params = {
        { 'token', 'id' },
        { 'answered', 'bool' },
        { 'why', 'enum', { 'busy', 'cancelled', 'timeout', '' }, '' },
        { 'value', 'any' },   -- held to what was asked below
    },
}, function(source, player, token, answered, why, value)
    local entry = _pending[token]
    if not entry or entry.done or entry.source ~= source then
        RecordEventRejection('whip_core:server:askAnswer', source, 'answer did not match an open question')
        return
    end
    if entry.session ~= nil and (not player or player.session ~= entry.session) then
        RecordEventRejection('whip_core:server:askAnswer', source, 'answer came from a different character session')
        return
    end
    entry.done = true
    _pending[token] = nil

    if not answered then
        entry.promise:resolve({ false, why ~= '' and why or 'cancelled' })
        return
    end
    if player and player.isDead then
        entry.promise:resolve({ false, 'dead' })
        return
    end
    if entry.kind == 'confirm' then
        if type(value) ~= 'boolean' then
            RecordEventRejection('whip_core:server:askAnswer', source, 'a yes/no answer that is not one')
            entry.promise:resolve({ false, 'bad answer' })
            return
        end
        entry.promise:resolve({ true, value })
        return
    end
    local out, bad = checkAnswer(entry.fields, value)
    if not out then
        RecordEventRejection('whip_core:server:askAnswer', source, 'form answer refused: ' .. tostring(bad))
        entry.promise:resolve({ false, 'bad answer' })
        return
    end
    entry.promise:resolve({ true, out })
end)

--- A player who left or logged out answers now, rather than at the timeout.
local function endAsksOf(src)
    for token, entry in pairs(_pending) do
        if entry.source == src and not entry.done then
            entry.done = true
            _pending[token] = nil
            entry.promise:resolve({ false, 'player left' })
            TriggerClientEvent('whip_core:client:serverAskCancel', src, token)
        end
    end
end

AddEventHandler('playerDropped', function()
    endAsksOf(source)
end)

--- WhipPlayer:logout calls this before it waits for the player's running handlers, beside
--- EndSkillChecksFor: a question asked of character A is never answered by character B.
---@param src number
function EndAsksFor(src)
    endAsksOf(src)
end

--- A run's end takes its question down: asked with a tag, it ends when that tag is released (a
--- system switched off), answering 'cancelled'. Never waits.
Registry.onRelease('ask', 5, function(owner, tag)
    local n = 0
    for token, entry in pairs(_pending) do
        if not entry.done and entry.owner == owner and entry.tag == tag then
            entry.done = true
            _pending[token] = nil
            entry.promise:resolve({ false, 'cancelled' })
            TriggerClientEvent('whip_core:client:serverAskCancel', entry.source, token)
            n = n + 1
        end
    end
    return n
end, function(owner, tag)
    local out = {}
    for token, entry in pairs(_pending) do
        if not entry.done and entry.owner == owner and entry.tag == tag then out[#out + 1] = { key = token } end
    end
    return out
end)

-- Ask.run itself is not exported yet: the Systems Creator's cards and the Director are its only callers. The
-- channel side is (RegisterAskChannel, AnswerAsk, above). `_ENV.`, as skillcheck.lua: the local above would assign
-- itself.
_ENV.Ask = Ask
