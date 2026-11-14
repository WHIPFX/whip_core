-- ============================================
-- DirectorFields — every kind of field a card or a task step has, in one place
-- ============================================
--
-- A card's props and a step's fields are each { key, kind, label, ... }. Its KIND is one of the names below, and
-- the kind is the whole of what the Director knows about it: where it may be used, how Check reads a card's value,
-- how a step's value is read as the brain plays it, and what it names (a placed thing, a variable, another card), so
-- that whatever walks a scenario's references asks here. A new kind is added here once; the editor draws it by the
-- same name (html/js/director/panels.js).
--
-- ONE VOCABULARY: a choice is `select` (its look, `look = 'seg'`, a row of buttons; the editor picks one for a short
-- list by itself), a number is `number` (`slider = true` draws it as one; `duration` is a number of seconds).
--
-- Each kind (the K calls below), every part optional:
--   card, step       it may be a card's field / a step's
--   satCard, satStep another resource's card / step may use it (cards_api.lua, satellite_api.lua)
--   check(f, v, cx)  a card's value: a message when it is wrong (cx = { vars, world, doc })
--   read(f, v, cx)   a step's value as it is played, or nil and why (cx = { world, owner })
--   fromVar(f, v, cx) a card's value read through a run variable, as the card takes it, or nil (cx = { world }); a
--                    kind without one takes the value when its check passes (F.fromVar)
--   names            what its value names: 'world' (a placed thing's id), 'worlds' (a list of them), 'var', 'card'
--   refs             what is named inside its value, a table: { var = { 'onlyVar' } } (an answer's rules)
--   sibling          what its value makes another key of the step name: { when, key, names } (a target set to
--                    'thing' names the step's `thing`)
-- (names, refs and sibling are the editor's too: dev/director/export_data.lua writes them into refs-data.js.)
--
-- WHAT THE SERVER HAS (an item, a job, a lore character, a weapon, a plate): asked of whip itself, here, by the kinds
-- and by Check's own rules for placed things and the start.

DirectorFields = {}
local F = DirectorFields

local finite, coords = DirectorKit.finite, DirectorKit.place

-- ============================================
-- What the server has
-- ============================================

--- Is this an item the server has (Config.Items: a satellite's RegisterItem too)?
function F.isItem(key)
    return type(key) == 'string' and type(Config) == 'table' and type(Config.Items) == 'table' and Config.Items[key] ~= nil
end

--- Can the item be used at all (`usable = true` in its definition)?
function F.isUsable(key)
    local def = F.isItem(key) and Config.Items[key]
    return def ~= nil and def ~= false and def.usable == true
end

--- Is this one of whip's jobs, by its key?
function F.isJob(key)
    return type(key) == 'string' and Jobs ~= nil and Jobs.getByKey ~= nil and Jobs.getByKey(key) ~= nil
end

--- Is this a lore character in use (server/director/lore.lua)?
function F.isLore(key) return DirectorLore.isLive(key) end

--- The lore character a document's empty lore field means, or nil (server/director/lore.lua).
function F.loreDefault(doc) return DirectorLore.defaultOf(doc) end

--- A weapon this server has: GTA's own, or one a running resource adds (shared/weapon_catalog.lua).
function F.isWeapon(name) return WeaponCatalog.get(name) ~= nil end

--- What is wrong with a car's plate (whip's one plate rule: Vehicles.normalisePlate), or nil.
function F.plateProblem(plate)
    local _, why = Vehicles.normalisePlate(plate)
    return why
end

--- A car model whip's vehicle catalog has, or nil when the catalog is empty (nothing to tell by).
function F.isCarModel(model)
    local cat = VehicleCatalog.rows
    if type(model) ~= 'string' or type(cat) ~= 'table' or next(cat) == nil then return nil end
    return cat[model:lower()] ~= nil
end

--- Why an NPC's look from the character editor (def.look) cannot be used, or nil (Npcs.spawn's own rule).
function F.lookProblem(look) return Npcs.lookProblem(look) end

-- ============================================
-- The kinds
-- ============================================

local KINDS = {}
local ORDER = {}
local function K(name, def)
    def.name = name
    KINDS[name] = def
    ORDER[#ORDER + 1] = name
end

local function has(list, x)
    for _, v in ipairs(list or {}) do if v == x then return true end end
    return false
end

local function oneOf(v, options, default)
    for _, o in ipairs(options) do if o == v then return v end end
    return default
end

local function name(f) return f.label or f.key end

--- A step's text-like value: trimmed, cut to its max, required when it says so.
local function readText(f, v)
    if type(v) ~= 'string' then v = '' end
    v = v:match('^%s*(.-)%s*$')
    if f.max and #v > f.max then v = v:sub(1, f.max) end
    if v == '' and f.required then return nil, 'is empty' end
    return v
end

K('text', { card = true, step = true, satCard = true, satStep = true,
    check = function(f, v)
        if type(v) ~= 'string' then return f.key .. ' must be text' end
        if f.maxLength and #v > f.maxLength then return ('%s is longer than %d characters'):format(f.key, f.maxLength) end
    end,
    read = readText,
    fromVar = function(f, v)
        v = tostring(v)
        return f.maxLength and DirectorKit.cut(v, f.maxLength) or v
    end })

local function checkNumber(f, v)
    if not finite(v) then return f.key .. ' must be a number' end
    if f.min and v < f.min then return ('%s must be at least %s'):format(f.key, f.min) end
    if f.max and v > f.max then return ('%s must be at most %s'):format(f.key, f.max) end
end
local function readNumber(f, v)
    local n = tonumber(v)
    if not finite(n) then n = f.default end
    if n == nil then return nil end
    if f.min then n = math.max(f.min, n) end
    if f.max then n = math.min(f.max, n) end
    return n
end
--- A number from a variable: held to the field's range (nil when it is no number).
local function numberFromVar(f, v)
    local n = tonumber(v)
    if not finite(n) then return nil end
    return readNumber(f, n)
end
K('number', { card = true, step = true, satCard = true, satStep = true, check = checkNumber, read = readNumber, fromVar = numberFromVar })
K('duration', { card = true, satCard = true, check = checkNumber, read = readNumber, fromVar = numberFromVar })

K('bool', { card = true, step = true, satCard = true, satStep = true,
    check = function(f, v) if type(v) ~= 'boolean' then return f.key .. ' must be yes or no' end end,
    read = function(f, v)
        if type(v) == 'boolean' then return v end
        return f.default == true
    end })

K('select', { card = true, step = true, satCard = true, satStep = true,
    check = function(f, v)
        -- A LOOSE choice may name one that is not here yet (another resource's skill check game, before that resource
        -- has started): its card's own check warns about it, and the run copes without it.
        local later = f.loose and type(v) == 'string' and v ~= '' and #v <= 64
        if not later and not has(f.options, v) then return ('%s: "%s" is not one of the choices'):format(f.key, tostring(v)) end
    end,
    read = function(f, v) return oneOf(v, f.options, f.default) end })

-- Who a card is for, of the run's players (DirectorNodes.PLAYERS): 'this player' (the one its trigger carries),
-- 'everyone in the run', 'the starter'. Read as server ids by F.playersOf.
K('players', { card = true, satCard = true,
    check = function(f, v)
        if not has(DirectorNodes.PLAYERS, v) then return ('%s: "%s" is not one of the choices'):format(name(f), tostring(v)) end
    end })

--- The players a `players` field's value names, as server ids of the run's (the kind above). `this`: the trigger's
--- player when the caller has it already (else Director.playerOf).
function F.playersOf(ctx, v, this)
    local run = ctx.run
    if v == 'everyone in the run' then return ctx:players() end
    if v == 'the starter' then return (run.starter and run.players[run.starter]) and { run.starter } or {} end
    local s = this or Director.playerOf(ctx)
    return s and { s } or {}
end

K('world', { card = true, step = true, satCard = true, satStep = true, names = 'world',
    check = function(f, v, cx)
        if type(v) ~= 'string' or not cx.world[v] then return ('%s points at a placed thing that does not exist'):format(f.key) end
        if f.worldKind and cx.world[v].kind ~= f.worldKind then
            return ('%s must be a %s, not a %s'):format(f.key, f.worldKind, tostring(cx.world[v].kind))
        end
    end,
    read = function(f, v, cx)
        if type(v) ~= 'string' or v == '' then
            if f.required then return nil, 'has nothing picked' end
            return nil
        end
        local w = cx.world and cx.world[v]
        if not w then return nil, ('names "%s", which is not placed'):format(v) end
        if f.worldKind and w.kind ~= f.worldKind then return nil, ('must be a %s'):format(f.worldKind) end
        return v
    end })

-- With `groups`, it may hold a named group too ('group:<name>': DirectorNodes.groupName), every placed thing of its kind
-- whose Group that is.
K('worlds', { card = true, names = 'worlds',
    check = function(f, v, cx)
        -- (One thing, as a card that held one saved it before its upgrade.)
        if f.groups and type(v) == 'string' then v = { v } end
        if type(v) ~= 'table' then return name(f) .. ' are not readable' end
        if f.required and #v == 0 then return name(f) .. ' has nothing picked' end
        if f.max and #v > f.max then return ('%s: %d at most'):format(name(f), f.max) end
        local seen = {}
        for _, id in ipairs(v) do
            local g = f.groups and DirectorNodes.groupName(id) or nil
            if g then
                if seen[id] then return ('%s: the group "%s" is in it twice'):format(name(f), g) end
                if #DirectorNodes.expandThings(cx.world, { id }, f.worldKind) == 0 then
                    return ('%s: nothing%s is in the group "%s" now'):format(name(f), f.worldKind and ' of its kind' or '', g)
                end
            else
                local w = type(id) == 'string' and cx.world[id] or nil
                if not w then return ('%s names a placed thing that does not exist'):format(name(f)) end
                if f.worldKind and w.kind ~= f.worldKind then
                    return ('%s: "%s" is a %s, not a %s'):format(name(f), tostring(w.label or id), tostring(w.kind), f.worldKind)
                end
                if seen[id] then return ('%s: "%s" is in it twice'):format(name(f), tostring(w.label or id)) end
            end
            seen[id] = true
        end
    end })

K('var', { card = true, satCard = true, names = 'var',
    check = function(f, v, cx)
        if type(v) ~= 'string' or not cx.vars[v] then return ('%s names a variable that does not exist'):format(f.key) end
    end })

K('item', { card = true, satCard = true,
    check = function(f, v)
        if type(v) ~= 'string' or v == '' then return name(f) .. ' must name an item' end
        if not F.isItem(v) then return ('%s: "%s" is not an item on this server'):format(name(f), v) end
    end })

K('runItem', { card = true,
    check = function(f, v, cx)
        if type(v) ~= 'string' or v == '' then return name(f) .. ' must name an item' end
        if not DirectorGraph.scenarioItems(cx.doc)[v] then
            return ('%s: "%s" is not one the scenario places or gives (an item spot, Give Item, Drop Item, Put in Car or Create Container)')
                :format(name(f), v)
        end
    end,
    -- (A run has no document to ask: an item's key, and the card counts only the run's own stacks of it.)
    fromVar = function(_, v) return type(v) == 'string' and v ~= '' and v or nil end })

-- A Dialog Line answer's rules (nodes_world.lua ruleProp): its Only if may read a variable.
K('rule', { card = true, refs = { var = { 'onlyVar' } },
    check = function(f, v) if type(v) ~= 'table' then return name(f) .. ' are not readable' end end })

K('job', { card = true, satCard = true,
    check = function(f, v)
        if type(v) ~= 'string' or v == '' then return name(f) .. ' must name a job' end
        if not F.isJob(v) then return ('%s: "%s" is not a job on this server'):format(name(f), v) end
    end })

-- Another card of the scenario, by its id: a card's of the types its `options` name (what a Haggle's price is for), a
-- Wait step's any card (it goes on at the outcomes picked: cardOuts).
K('card', { card = true, step = true, names = 'card',
    check = function(f, v, cx)
        local target = nil
        for _, n in ipairs(type(cx.doc) == 'table' and type(cx.doc.nodes) == 'table' and cx.doc.nodes or {}) do
            if type(n) == 'table' and n.id == v then target = n break end
        end
        if not target then return ('%s: that card is not on the blueprint any more'):format(name(f)) end
        if f.options and not has(f.options, target.type) then
            return ('%s: a %s card cannot take a price'):format(name(f), tostring(target.type))
        end
    end,
    read = function(_, v)
        if type(v) ~= 'string' or not v:match('^[%w_%-]+$') or #v > 64 then return nil, 'has no card picked' end
        return v
    end,
    fromVar = function(f, v) return (KINDS.card.read(f, v)) end })

K('cardOuts', { step = true,
    read = function(_, v)
        local out = {}
        for _, pin in ipairs(type(v) == 'table' and v or {}) do
            if type(pin) == 'string' and pin:match('^[%w_%-]+$') and #pin <= 32 and #out < 16 then out[#out + 1] = pin end
        end
        if #out == 0 then return nil, 'has no outcome picked' end
        return out
    end })

-- One of a car's recorded drives, by its id (server/director/takes.lua): a card's names the car in its `of` field.
K('take', { card = true, step = true,
    check = function(f, v, cx)
        local id = math.tointeger(tonumber(v))
        local listed = false
        for _, w in pairs(cx.world) do
            for _, t in ipairs(w.kind == 'vehicle' and type(w.def) == 'table' and type(w.def.takes) == 'table' and w.def.takes or {}) do
                if type(t) == 'table' and math.tointeger(tonumber(t.id)) == id then listed = true end
            end
        end
        if not id or not listed then return ('%s: pick one of the car\'s driving events (record one on its page)'):format(name(f)) end
    end,
    read = function(f, v, cx)
        local n = math.tointeger(tonumber(v))
        if not n or n < 1 then
            if f.required then return nil, 'has no driving event picked (record one on the car\'s page)' end
            return nil
        end
        -- (One its car no longer has, removed from its page, is never played.)
        if cx.owner and not DirectorTakes.onCar(cx.owner, n) then return nil, 'was removed from the car: pick another' end
        return n
    end })

-- One of whip's icons by its key (html/js/glyphs.js; the page shows a missing one as its default).
K('glyph', { card = true,
    check = function(f, v)
        if type(v) ~= 'string' or #v > 32 or not v:match('^[%w_]*$') then return name(f) .. ' must be an icon\'s name' end
    end })

-- An /e name: typed, or picked from the emote menu.
K('emote', { card = true, step = true,
    check = function(f, v)
        if type(v) ~= 'string' then return f.key .. ' must be an emote\'s name' end
        if f.maxLength and #v > f.maxLength then return ('%s is longer than %d characters'):format(f.key, f.maxLength) end
    end,
    read = readText })

-- What a container's slots may hold: { slot, item, min, max, chance }, a slot's chances 100% at most (what is left:
-- the slot empty). nodes_heist.lua rollLoot.
K('loot', { card = true,
    check = function(f, v)
        local nm = name(f)
        if type(v) ~= 'table' then return nm .. ' are not readable' end
        if #v > 200 then return nm .. ': 200 at most' end
        local sum = {}
        for i, e in ipairs(v) do
            if type(e) ~= 'table' then return ('%s %d is not readable'):format(nm, i) end
            local slot = math.tointeger(tonumber(e.slot))
            if not slot or slot < 1 or slot > 100 then return ('%s %d: its slot is 1-100'):format(nm, i) end
            if type(e.item) ~= 'string' or e.item == '' then return ('Slot %d: an item is not picked'):format(slot) end
            if not F.isItem(e.item) then return ('Slot %d: "%s" is not an item on this server'):format(slot, e.item) end
            local mn = math.tointeger(tonumber(e.min or 1))
            local mx = math.tointeger(tonumber(e.max or e.min or 1))
            if not mn or not mx or mn < 1 or mx < mn or mx > 1000000 then
                return ('Slot %d (%s): how many is 1 or more, the most at least the fewest'):format(slot, e.item)
            end
            local ch = tonumber(e.chance or 100)
            if not ch or ch < 1 or ch > 100 then return ('Slot %d (%s): its chance is 1-100%%'):format(slot, e.item) end
            sum[slot] = (sum[slot] or 0) + ch
            if sum[slot] > 100 then return ('Slot %d: its chances add up to more than 100%%'):format(slot) end
        end
    end })

-- A lore character by key; empty is the scenario's own (server/director/lore.lua).
K('lore', { card = true, satCard = true,
    check = function(f, v)
        if type(v) ~= 'string' then return name(f) .. ' must name a lore character' end
        if not F.isLore(v) then return ('%s: "%s" is not a lore character on this server'):format(name(f), v) end
    end })

-- Another resource's list, filled by its own Director button (cards_api.lua): plain entries, as many as it takes.
K('entries', { card = true, satCard = true,
    check = function(f, v)
        local nm = name(f)
        if type(v) ~= 'table' then return nm .. ' are not readable' end
        if f.max and #v > f.max then return ('%s: %d at most'):format(nm, f.max) end
        for i, e in ipairs(v) do
            if type(e) ~= 'table' then return ('%s %d is not readable'):format(nm, i) end
        end
    end })

-- ---- a step's own ----

-- A place in the world (key `at`), put down in the world builder and joined to its thing.
K('point', { step = true, satStep = true,
    read = function(f, v)
        local c = coords(v)
        if not c and f.required then return nil, 'is not placed in the world yet' end
        return c
    end })

-- Who or what a step points at (its `options`): the nearest of the run's players, who set the card off, a placed thing
-- (the step's `thing`) or a point (its `at`).
K('target', { step = true, satStep = true, sibling = { when = 'thing', key = 'thing', names = 'world' },
    read = function(f, v) return oneOf(v, f.options, f.default) end })

K('weapon', { step = true, read = readText })
K('voice', { step = true, read = readText })
K('speechLine', { step = true, read = readText })

-- ============================================
-- When: a field or an outcome only some of the time
-- ============================================
--
-- A field's `when` (it shows, and counts, only while it holds) and a card's `pinWhen` ({ [pin] = when }: an outcome
-- that is one only while it holds; a wired one still shows) are one small language, read the same way by the editor
-- (html/js/director/when.js):
--   { key = k, is = v }      k's value (its field's default when it has none) is v     isnt = v: it is not
--   { key = k, set = true }  k has a value saved, not empty                            set = false: it has none
--   { key = k, above = n }   k's value (or its default) is a number above n
--   { all = { ... } }        every one of them holds          { any = { ... } }  one of them does
--   false                    never: an outcome a card no longer takes, kept so wires already drawn from it still
--                            show and Check says they can never happen (Skill Check's No answer)
-- k may be a path into a field that is a table ('opt1Rule.chance').

local function valueAt(values, key)
    local v = values
    for part in key:gmatch('[^.]+') do
        if type(v) ~= 'table' then return nil end
        v = v[part]
    end
    return v
end

local function defaultOf(fields, key)
    for _, f in ipairs(type(fields) == 'table' and fields or {}) do if f.key == key then return f.default end end
    return nil
end

--- Does `c` hold for these values (a card's props, a step)? `fields`: theirs, for defaults. No `c`: it does.
function F.holds(c, values, fields)
    if c == false then return false end
    if type(c) ~= 'table' then return true end
    if c.all then
        for _, x in ipairs(c.all) do if not F.holds(x, values, fields) then return false end end
        return true
    end
    if c.any then
        for _, x in ipairs(c.any) do if F.holds(x, values, fields) then return true end end
        return false
    end
    local raw = valueAt(type(values) == 'table' and values or {}, c.key)
    if c.set ~= nil then return (raw ~= nil and raw ~= '') == c.set end
    local v = raw
    if v == nil then v = defaultOf(fields, c.key) end
    if c.is ~= nil then return v == c.is end
    if c.isnt ~= nil then return v ~= c.isnt end
    if c.above ~= nil then return type(v) == 'number' and v > c.above end
    return true
end

--- The pinWhen of a card whose `timeout` outcome comes only with a time limit set (its `seconds` field).
F.TIMES_OUT = { timeout = { key = 'seconds', set = true } }

--- What is wrong with a `when` as written (a card's or a step's, at definition), or nil.
function F.whenProblem(c, depth)
    depth = depth or 1
    if c == false and depth == 1 then return nil end
    if type(c) ~= 'table' or depth > 4 then return 'a when is { key, is | isnt | set | above }, { all } / { any } of them, or false' end
    local list = c.all or c.any
    if list ~= nil then
        if type(list) ~= 'table' or #list == 0 then return 'all and any are lists of whens' end
        for _, x in ipairs(list) do
            local why = F.whenProblem(x, depth + 1)
            if why then return why end
        end
        return nil
    end
    if type(c.key) ~= 'string' or not c.key:match('^[%a][%w_.]*$') then return 'a when names the key of a field' end
    local n = (c.is ~= nil and 1 or 0) + (c.isnt ~= nil and 1 or 0) + (c.set ~= nil and 1 or 0) + (c.above ~= nil and 1 or 0)
    if n ~= 1 then return ('a when on %s says one of is, isnt, set or above'):format(c.key) end
    if c.set ~= nil and type(c.set) ~= 'boolean' then return 'set is true or false' end
    if c.above ~= nil and not finite(c.above) then return 'above is a number' end
    return nil
end

-- ============================================
-- Asking it
-- ============================================

--- A kind by its name, or nil.
function F.get(kind) return KINDS[kind] end

--- The kinds usable as `where` ('card', 'step', 'satCard', 'satStep'), in order, as text for a refusal.
function F.namesFor(where)
    local out = {}
    for _, k in ipairs(ORDER) do if KINDS[k][where] then out[#out + 1] = k end end
    return table.concat(out, ', ')
end

--- May a field of this kind be used `where` ('card', 'step', 'satCard', 'satStep')?
function F.usable(kind, where)
    local d = KINDS[kind]
    return d ~= nil and d[where] == true
end

--- A card's field against its value: a message, or nil when it is fine. cx = { vars, world, doc }.
function F.check(f, v, cx)
    -- An empty lore field is the scenario's own lore character: there has to be one.
    if f.kind == 'lore' and (v == nil or v == '') then
        if not F.loreDefault(cx.doc) then
            return ('%s: pick a lore character, or make the NPC that starts the scenario one'):format(name(f))
        end
        return nil
    end
    if v == nil then
        if f.required then return f.label and (f.label .. ' is empty') or (f.key .. ' is empty') end
        return nil
    end
    -- A reference to a run variable: allowed for values, never for a field that NAMES a variable, and for a placed
    -- thing only where the field says so (the runtime checks what it then reads).
    if type(v) == 'table' and v.var ~= nil then
        if f.kind == 'var' then return f.key .. ' must name a variable, not read one' end
        if f.kind == 'rule' then return f.key .. ' cannot read a variable' end
        if f.kind == 'world' and not f.allowVar then return f.key .. ' must point at a placed thing' end
        if not cx.vars[v.var] then return ('%s uses a variable that does not exist (%s)'):format(f.key, tostring(v.var)) end
        return nil
    end
    local d = KINDS[f.kind]
    local msg = d and d.check and d.check(f, v, cx) or nil
    if msg then return msg end
    if f.check then
        local ok, m = pcall(f.check, v, cx.doc)
        if not ok then return ('%s could not be checked: %s'):format(f.key, tostring(m)) end
        if m then return tostring(m) end
    end
    return nil
end

--- A card's field read through a run variable (CTX:prop), checked as a saved value would be: the kind's own fromVar,
--- else the value when the kind's check passes; nil when it cannot be used. cx = { world } (the run's placed things by
--- id). A field of no kind known here takes the value as it is.
function F.fromVar(f, v, cx)
    if f == nil then return v end
    if v == nil then return nil end
    local d = KINDS[f.kind]
    if not d then return v end
    if d.fromVar then return d.fromVar(f, v, cx) end
    if d.check then
        local ok, msg = pcall(d.check, f, v, cx)
        if not ok or msg ~= nil then return nil end
    end
    return v
end

--- A step's field value as it is played, or nil and why (a required one missing). cx = { world, owner }.
function F.read(f, v, cx)
    local d = KINDS[f.kind]
    if not (d and d.read) then return nil end
    return d.read(f, v, cx)
end

--- The placed things a field's value names, as a list of ids (a world or worlds field; a step's target set to a
--- thing names its `thing`: pass the step as `s`). A worlds field's groups name their members of `world` (the
--- scenario's things; without it, none).
function F.worldIds(f, v, s, world)
    local d = KINDS[f.kind]
    if d and d.names == 'world' and type(v) == 'string' then return { v } end
    if d and d.names == 'worlds' and (type(v) == 'table' or (f.groups and type(v) == 'string')) then
        if not f.groups then return v end
        return DirectorNodes.expandThings(world or {}, v, f.worldKind)
    end
    local sib = d and d.sibling
    if sib and sib.names == 'world' and v == sib.when and s and type(s[sib.key]) == 'string' then return { s[sib.key] } end
    return {}
end

--- The kinds' references as plain data, for the editor (dev/director/export_data.lua): { [kind] = { names, refs,
--- sibling } } of the kinds that name anything.
function F.refsData()
    local out = {}
    for kind, d in pairs(KINDS) do
        if d.names or d.refs or d.sibling then out[kind] = { names = d.names, refs = d.refs, sibling = d.sibling } end
    end
    return out
end

--- Does a card's field `f` (its value `v`) name placed thing `id`? (`world`: for its groups, as F.worldIds.)
function F.namesWorld(f, v, id, world)
    for _, x in ipairs(F.worldIds(f, v, nil, world)) do if x == id then return true end end
    return false
end
