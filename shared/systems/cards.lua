-- Systems: what a card is. Unlike the Director's exec-only cards, a card also passes values on typed wires.
--
--   exec pins    inputs = { 'in' }, outputs = { 'yes', 'no' }
--   value pins   values = { inputs = { { key = 'speed', type = 'number' } },
--                          outputs = { { key = 'result', type = 'bool' } } }
-- An exec pin and a value pin on one card never share a name.
--
-- Kinds:
--   trigger   starts a pulse ("Every 5 seconds"). No exec input.
--   action    runs and answers at once (Branch, Set Variable, Notify).
--   wait      opens an activation and answers later (Delay, Charge, Progress Bar).
--   value     no exec pins: worked out when a card that reads it runs (Formula, Distance).
--   engine    hand-written per-frame Lua that the graph listens to (Drift Meter).
--
-- Side: 'server', 'client' or 'both', set by the card. Required, with no default, so a server card is never
-- shipped to players by accident. A card with a power ('money', 'items', 'others') is a server card.
--
-- settles: the output pins that mean "delivered" (Give Item's Given). Answering one settles the pulse's open
-- receipts (a Charge's payment): kept for good, never refunded, even if the pulse is cancelled later.

SystemCards = {}
local C = SystemCards

-- Types

--- Every value type, and the colour group a builder sees it as (six colours; `any` is grey).
C.TYPES = {
    number = 'number', text = 'text', bool = 'bool',
    vector = 'place', area = 'place', point = 'place',
    player = 'person', character = 'person',
    vehicle = 'thing', npc = 'thing', item = 'thing', door = 'thing', container = 'thing',
    job = 'thing', shop = 'thing', account = 'thing', receipt = 'thing',
    list = 'thing', record = 'thing',
    any = 'any',
}

C.KINDS = { trigger = true, action = true, wait = true, value = true, engine = true }
C.SIDES = { server = true, client = true, both = true }
-- make: the system makes the server's own things for good (Registers: an item of its own).
C.POWERS = { money = true, items = true, others = true, make = true }
C.MAKES = { vehicle = true, npc = true, point = true, blip = true, ground = true, area = true }
C.MAX_LIST = 64      -- a list holds this many things at most
C.MAX_TURNS = 100    -- a loop (For Each, Repeat) runs this many turns at most
C.MAX_NODES = 512    -- the most table entries one value may carry (lists of records, records of lists)
C.MAX_TEXT = 4000    -- bytes

local MAX_ID = 9007199254740991   -- 2^53: runtime doors, containers and points count up from 2^32

--- A whole positive number that names a thing (Sanitize.id's rule: reject, never clamp).
local function id(v)
    v = tonumber(v)
    if not v or v ~= v or v <= 0 or v ~= math.floor(v) or v > MAX_ID then return nil end
    return math.tointeger(v)
end
C.id = id

--- A bounded copy of a value: at most C.MAX_NODES table entries, 6 levels deep, no loops; vectors become
--- { x, y, z }; functions, threads and userdata are left out. Answers the copy, or nil when too big.
local function copy(v)
    local budget = C.MAX_NODES
    local over = false
    local function walk(x, depth, seen)
        local t = type(x)
        if t == 'vector3' or t == 'vector4' or t == 'vector2' then
            return { x = x.x, y = x.y, z = x.z }
        end
        if t == 'function' or t == 'thread' or t == 'userdata' then return nil end
        if t ~= 'table' then return x end
        if depth > 6 or seen[x] then over = true return nil end
        seen[x] = true
        local out = {}
        for k, val in pairs(x) do
            budget = budget - 1
            if budget < 0 then over = true break end
            local kt = type(k)
            if kt == 'string' or kt == 'number' then out[k] = walk(val, depth + 1, seen) end
            if over then break end
        end
        seen[x] = nil
        return out
    end
    local out = walk(v, 0, {})
    if over then return nil end
    return out
end
C.copy = copy

local function isPlace(v)
    local t = type(v)
    return t == 'table' or t == 'vector3' or t == 'vector4'
end

local function finite(n) return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge end

--- Text cut to `max` bytes without splitting a UTF-8 character.
local function cutText(s, max)
    if #s <= max then return s end
    local i = max
    while i > 0 do
        local b = s:byte(i + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end   -- the next byte starts a character
        i = i - 1
    end
    return s:sub(1, i)
end
C.cutText = cutText

--- Can a wire carry `from` into `to`? A player converts to their character; `any` goes either way and is
--- checked on arrival. A receipt comes only from a receipt pin, never from `any` or typed in (it would forge a refund).
function C.compatible(from, to)
    if to == 'receipt' or from == 'receipt' then return from == to end
    if from == to or from == 'any' or to == 'any' then return true end
    if from == 'player' and to == 'character' then return true end
    return false
end

--- A value checked against its pin's type: the value (a copy for a table), or nil.
--- `charOf(player)` turns a player into their character (the walker's Port; nil if the session is not current). It must not throw.
---@param t string
---@param v any
---@param charOf? fun(p: table): number|nil
---@return any|nil
function C.coerce(t, v, charOf)
    if v == nil then return nil end
    if t == 'any' then
        if type(v) == 'string' then return cutText(v, C.MAX_TEXT) end
        if type(v) == 'number' and not finite(v) then return nil end
        return copy(v)
    end
    if t == 'number' then
        if not finite(v) then return nil end
        return v
    elseif t == 'text' then
        if type(v) == 'string' then return cutText(v, C.MAX_TEXT) end
        return nil
    elseif t == 'bool' then
        if type(v) == 'boolean' then return v end
        return nil
    elseif t == 'vector' then
        if not isPlace(v) then return nil end
        local x, y, z = tonumber(v.x), tonumber(v.y), tonumber(v.z)
        if not (finite(x) and finite(y) and finite(z)) then return nil end
        return { x = x, y = y, z = z }
    elseif t == 'player' then
        if type(v) ~= 'table' then return nil end
        local s = id(v.source)
        if not s then return nil end
        local session = v.session
        if type(session) ~= 'string' and type(session) ~= 'number' then session = nil end
        return { source = s, session = session }
    elseif t == 'character' then
        if type(v) == 'table' and v.source ~= nil then
            local p = C.coerce('player', v)
            if not p or not charOf then return nil end
            local ok, cid = pcall(charOf, p)
            return ok and id(cid) or nil
        end
        return id(v)
    elseif t == 'item' then
        if type(v) == 'string' and v ~= '' and #v <= 50 then return v end
        return nil
    elseif t == 'area' or t == 'point' then
        if type(v) == 'string' and v ~= '' and #v <= 80 then return v end
        return id(v)
    elseif t == 'job' or t == 'shop' then
        -- whip names a job or a shop by its key as well as its id (Jobs.resolve).
        if type(v) == 'string' and v:match('^[%w_%-]+$') and #v <= 50 then return v end
        return id(v)
    elseif t == 'list' then
        if type(v) ~= 'table' then return nil end
        local items = {}
        for i = 1, math.min(#v, C.MAX_LIST) do items[i] = v[i] end
        return copy(items)
    elseif t == 'record' then
        if type(v) ~= 'table' then return nil end
        return copy(v)
    elseif t == 'receipt' then
        -- Only the walker makes these (ctx:receipt): { receipt = n }. A card taking one checks ctx:ownReceipt first.
        if type(v) ~= 'table' or not id(v.receipt) then return nil end
        return { receipt = id(v.receipt) }
    end
    -- vehicle, npc, door, container, account: whip's own numeric ids
    return id(v)
end

--- A type's empty value, for a variable nobody has set yet.
function C.zero(t)
    if t == 'number' then return 0 end
    if t == 'text' then return '' end
    if t == 'bool' then return false end
    if t == 'list' then return {} end
    return nil
end

-- Props (a card's fields, as the Director's: nodes.lua)

local FIELD_KINDS = {
    text = true, number = true, bool = true, select = true, duration = true,
    var = true,       -- a variable's name (the document's vars)
    formula = true,   -- a Formula line (shared/systems/formula.lua checks it)
    scope = true,     -- 'everyone' | 'player' | 'car'
    item = true,      -- an item key
    place = true,     -- a spot in the world: { x, y, z } (S2: the Places tab picks it)
}
C.SCOPES = { 'everyone', 'player', 'car' }

-- Defining a card

local defs = {}       -- [type] = def
local order = {}      -- types in the order defined (the palette's order)

local function pinList(list, what)
    if list == nil then return {} end
    if type(list) ~= 'table' then return nil, what .. ' is a list of pin names' end
    local out, seen = {}, {}
    for _, p in ipairs(list) do
        if type(p) ~= 'string' or not p:match('^[%a][%w_]*$') or #p > 32 then
            return nil, ('%s: "%s" is not a pin name'):format(what, tostring(p))
        end
        if seen[p] then return nil, ('%s: "%s" twice'):format(what, p) end
        seen[p] = true
        out[#out + 1] = p
    end
    return out
end

local function valueList(list, what)
    if list == nil then return {} end
    if type(list) ~= 'table' then return nil, what .. ' is a list of { key, type }' end
    local out = {}
    for _, p in ipairs(list) do
        if type(p) ~= 'table' or type(p.key) ~= 'string' or not p.key:match('^[%a][%w_]*$') or #p.key > 32 then
            return nil, ('%s: a value pin needs a key (letters, digits, _)'):format(what)
        end
        if not C.TYPES[p.type] then return nil, ('%s.%s: "%s" is not a type'):format(what, p.key, tostring(p.type)) end
        -- claim: what a player's game says (compile.lua's claim pass follows it).
        out[#out + 1] = { key = p.key, type = p.type, label = p.label or p.key, optional = p.optional == true,
                          default = p.default, claim = p.claim == true or nil }
    end
    return out
end

--- Add a card type. Answers true, or false and why.
---@param def table
---@return boolean ok
---@return string|nil why
function C.define(def)
    if type(def) ~= 'table' then return false, 'a card is a table' end
    if type(def.type) ~= 'string' or not def.type:match('^[a-z][%w]*%.[%a][%w_]*$') or #def.type > 48 then
        return false, ('"%s" is not a card type (group.name)'):format(tostring(def.type))
    end
    if defs[def.type] then return false, def.type .. ' is already defined' end
    if not C.KINDS[def.kind] then return false, def.type .. ': kind is trigger, action, wait, value or engine' end
    if not C.SIDES[def.side] then return false, def.type .. ': side is server, client or both (every card says)' end
    -- Powers: one ('money') or several ('money,items' or { 'money', 'items' }). Kept as def.powers (sorted) and
    -- def.power (one string, 'items,money').
    if def.power ~= nil then
        local list = (type(def.power) == 'table' and def.power or {}) --[[@as table]]
        if type(def.power) == 'string' then for p in def.power:gmatch('[^,%s]+') do list[#list + 1] = p end end
        local seen, powers = {}, {}
        for _, p in ipairs(list) do
            if not C.POWERS[p] then return false, def.type .. ': power is money, items, others or make' end
            if not seen[p] then seen[p] = true; powers[#powers + 1] = p end
        end
        if #powers == 0 then return false, def.type .. ': power is money, items, others or make' end
        table.sort(powers)
        def.powers = powers
        def.power = table.concat(powers, ',')
    end
    if def.makes ~= nil and not C.MAKES[def.makes] then return false, def.type .. ': makes is vehicle, npc, point, blip, ground or area' end
    if def.power and def.side ~= 'server' then return false, def.type .. ': a card with a power is a server card' end
    if type(def.title) ~= 'string' or def.title == '' then return false, def.type .. ' needs a title' end
    def.v = math.tointeger(def.v) or 1
    def.category = type(def.category) == 'string' and def.category or 'other'

    local kind = def.kind
    local why
    local inputs = def.inputs
    if inputs == nil then inputs = (kind == 'action' or kind == 'wait') and { 'in' } or {} end
    def.inputs, why = pinList(inputs, def.type .. ' inputs')
    if not def.inputs then return false, why end
    local outputs = def.outputs
    if outputs == nil then outputs = (kind == 'action' or kind == 'trigger') and { 'out' } or {} end
    def.outputs, why = pinList(outputs, def.type .. ' outputs')
    if not def.outputs then return false, why end
    if kind == 'value' and (#def.inputs > 0 or #def.outputs > 0) then
        return false, def.type .. ': a value card has no exec pins'
    end
    if kind == 'trigger' and #def.inputs > 0 then return false, def.type .. ': a trigger has no exec input' end
    if (kind == 'action' or kind == 'wait') and #def.inputs == 0 then
        return false, def.type .. ': an action needs an exec input'
    end
    if kind == 'wait' and #def.outputs == 0 then return false, def.type .. ': a waiting card answers at least one pin' end

    local values = def.values or {}
    local vin, vout
    vin, why = valueList(values.inputs, def.type .. ' value inputs')
    if not vin then return false, why end
    vout, why = valueList(values.outputs, def.type .. ' value outputs')
    if not vout then return false, why end
    def.values = { inputs = vin, outputs = vout }
    if kind == 'value' and #vout == 0 and type(def.pinsFor) ~= 'function' then
        return false, def.type .. ': a value card answers at least one value'
    end
    -- One name space for every pin on the card.
    local names = {}
    for _, list in ipairs({ def.inputs, def.outputs }) do
        for _, p in ipairs(list) do
            if names[p] then return false, ('%s: two pins called %s'):format(def.type, p) end
            names[p] = true
        end
    end
    for _, list in ipairs({ vin, vout }) do
        for _, p in ipairs(list) do
            if names[p.key] then return false, ('%s: two pins called %s'):format(def.type, p.key) end
            names[p.key] = true
        end
    end
    if def.pinsFor ~= nil and type(def.pinsFor) ~= 'function' then return false, def.type .. ': pinsFor is a function' end
    def._settles = {}
    for _, p in ipairs(def.settles or {}) do
        if not names[p] then return false, ('%s: settles names %s, which is not one of its pins'):format(def.type, tostring(p)) end
        def._settles[p] = true
    end

    -- What it runs.
    if kind == 'value' then
        if type(def.value) ~= 'function' then return false, def.type .. ': a value card has value(ctx)' end
    elseif kind == 'trigger' then
        local t = def.trigger
        local w = def.watch
        local fine = (type(t) == 'table' and type(t.name) == 'string' and (t.match == nil or type(t.match) == 'function')
                        and (t.test == nil or type(t.test) == 'function'))
            or type(def.timer) == 'function' or def.onStart == true
            -- A watch (walk.lua): checked repeatedly, starting only on a change: { every(props) -> ms,
            -- perPlayer(props) -> bool, check(ctx, last) -> reading (kept), outputs to start a pulse with (or nil) }.
            or (type(w) == 'table' and type(w.every) == 'function' and type(w.check) == 'function'
                and (w.perPlayer == nil or type(w.perPlayer) == 'function'))
        if not fine then return false, def.type .. ': a trigger has trigger = { name, match }, timer(props), watch = { every, check } or onStart' end
    else
        if type(def.run) ~= 'function' then return false, def.type .. ': it needs run(ctx)' end
    end
    -- What a card with a power does in a Test instead (walk.lua: nothing of value stays there).
    if def.dryRun ~= nil and type(def.dryRun) ~= 'function' then return false, def.type .. ': dryRun is a function' end
    -- What a trigger keeps standing while its system is on (a Point Used card's prompt): made at switch-on
    -- (server/systems/main.lua) under its tag, so switching off removes it.
    if def.standing ~= nil and (type(def.standing) ~= 'function' or kind ~= 'trigger') then
        return false, def.type .. ': standing(api) is a trigger\'s function'
    end

    -- Its fields.
    def._fields = {}
    if def.props ~= nil and type(def.props) ~= 'table' then return false, def.type .. ': props is a list' end
    for _, f in ipairs(def.props or {}) do
        if type(f) ~= 'table' or type(f.key) ~= 'string' or not FIELD_KINDS[f.kind] then
            return false, ('%s: a field needs a key and a kind (%s)'):format(def.type, 'text, number, bool, select, duration, var, formula, scope, item, place')
        end
        if def._fields[f.key] then return false, ('%s: two fields called %s'):format(def.type, f.key) end
        def._fields[f.key] = f
    end

    -- Its cost in points: instant 1, a whip API call 3, a wait 5, a card that makes a thing 10.
    if def.cost ~= nil then
        local c = tonumber(def.cost)
        if not c or c < 0 or c > 1000 or c ~= c then return false, def.type .. ': cost is 0 to 1000 points' end
        def.cost = c
    else
        def.cost = def.makes and 10 or (kind == 'wait' and 5) or 1
    end
    def._outputs = {}
    for _, p in ipairs(def.outputs) do def._outputs[p] = true end
    def._inputs = {}
    for _, p in ipairs(def.inputs) do def._inputs[p] = true end
    defs[def.type] = def
    order[#order + 1] = def.type
    return true
end

---@return table|nil def
function C.get(t) return defs[t] end

---@return string[] types   in the order defined
function C.types()
    local out = {}
    for i, t in ipairs(order) do out[i] = t end
    return out
end

--- A card's fields with their defaults filled in (what pinsFor and ctx:prop both see).
function C.withDefaults(def, props)
    local out = {}
    for k, v in pairs(type(props) == 'table' and props or {}) do out[k] = v end
    for key, f in pairs(def._fields) do
        if out[key] == nil and f.default ~= nil then out[key] = f.default end
    end
    return out
end

--- A card's value pins for these props: its declared ones plus what pinsFor adds (a Formula's names).
--- `info` = { vars = { [name] = { type, scope } } } for cards whose pins depend on the document. Answers
--- inputs, outputs (lists of { key, type, label, optional, default }), or nil and why (pinsFor refused).
---@return table|nil inputs
---@return table|string outputs
function C.valuePins(def, props, info)
    local vin, vout = {}, {}
    for _, p in ipairs(def.values.inputs) do vin[#vin + 1] = p end
    for _, p in ipairs(def.values.outputs) do vout[#vout + 1] = p end
    if def.pinsFor then
        local ok, extra, why = pcall(def.pinsFor, C.withDefaults(def, props), info or {})
        if not ok then return nil, 'its pins could not be worked out: ' .. tostring(extra) end
        if extra == nil then return nil, why or 'its fields do not read' end
        local ein = valueList(extra.inputs, def.type .. ' pins')
        local eout = valueList(extra.outputs, def.type .. ' pins')
        if not ein or not eout then return nil, 'its fields make pins that are not right' end
        for _, p in ipairs(ein) do vin[#vin + 1] = p end
        for _, p in ipairs(eout) do vout[#vout + 1] = p end
    end
    return vin, vout
end

--- What the editor needs to draw each card (no functions).
function C.wire()
    local out = {}
    for _, t in ipairs(order) do
        local d = defs[t]
        local props = {}
        for _, f in ipairs(d.props or {}) do
            local copyF = {}
            for k, v in pairs(f) do if type(v) ~= 'function' then copyF[k] = v end end
            props[#props + 1] = copyF
        end
        out[#out + 1] = {
            type = d.type, v = d.v, title = d.title, desc = d.desc, category = d.category, kind = d.kind,
            side = d.side, power = d.power, cost = d.cost, inputs = d.inputs, outputs = d.outputs,
            labels = d.labels, values = copy(d.values), props = props, dynamicPins = d.pinsFor ~= nil,
            testable = d.power == nil or d.dryRun ~= nil or d.kind == 'trigger',
        }
    end
    return out
end

--- Forget every card (the harness).
function C._reset() defs, order = {}, {} end
