-- ============================================
-- SYSTEMS — a System document, checked and compiled
-- ============================================
--
-- THE DOCUMENT (what the editor saves; the store keeps its revisions):
--   { format = 1, kind = 'system', name, description, settings = {},
--     vars  = { { id, type, scope = 'everyone' | 'player' | 'car', default, remember } },
--     nodes = { { id, type, v, x, y, props = {}, values = { [valueInputKey] = a typed-in constant } } },
--     links = { { id, from = { node, pin }, to = { node, pin } } } }
-- A link joins an exec output to an exec input ("then"), or a value output to a value input (a
-- speed into a Formula). A value input takes ONE wire; an unwired one takes its typed-in constant.
--
-- compile() refuses what the walker cannot run safely: an unknown card, a pin that is not there, a
-- wire between types that do not match, a value wired in a loop, an exec loop made only of cards that
-- never wait, a card on the wrong side for its lane. The editor's Check adds advice on top (cards
-- that never run, the sweep-rate warning, powers, claim marks): it calls this first.

SystemGraph = {
    MAX_NODES = 400, MAX_LINKS = 1200, MAX_VARS = 64,
    MAX_VALUE_DEPTH = 31,   -- value cards in a row (the walker works out at most 32, the reader included)
}
local G = SystemGraph
local C = SystemCards

local ID = '^[%w_%-]+$'
local VAR = '^[%a_][%w_]*$'

local function problem(list, severity, node, msg, pin)
    list[#list + 1] = { severity = severity, node = node, pin = pin, message = msg }
end

--- A field's saved value is right for its kind. Answers why not, or nil.
local function fieldProblem(f, v, vars)
    if v == nil then
        if f.required and f.default == nil then return 'needs a value' end
        return nil
    end
    local k = f.kind
    if k == 'number' or k == 'duration' then
        if type(v) ~= 'number' or v ~= v or v == math.huge or v == -math.huge then return 'is not a number' end
        if f.min and v < f.min then return ('is at least %s'):format(f.min) end
        if f.max and v > f.max then return ('is at most %s'):format(f.max) end
    elseif k == 'text' then
        if type(v) ~= 'string' then return 'is not text' end
        if f.maxLength and #v > f.maxLength then return ('is %d characters at most'):format(f.maxLength) end
    elseif k == 'bool' then
        if type(v) ~= 'boolean' then return 'is not yes or no' end
    elseif k == 'select' then
        for _, o in ipairs(f.options or {}) do if o == v then return nil end end
        return 'is not one of its choices'
    elseif k == 'scope' then
        for _, o in ipairs(C.SCOPES) do if o == v then return nil end end
        return 'is not for everyone, per player or per car'
    elseif k == 'var' then
        if type(v) ~= 'string' or not vars[v] then return ('names no variable (%s)'):format(tostring(v)) end
        if f.varType and vars[v].type ~= f.varType then return ('must be a %s variable'):format(f.varType) end
    elseif k == 'formula' then
        local ast, why = SystemFormula.parse(v)
        if not ast then return why end
    elseif k == 'item' then
        if type(v) ~= 'string' or v == '' or #v > 50 then return 'is not an item' end
    elseif k == 'place' then
        if C.coerce('vector', v) == nil then return 'is not a place (x, y, z)' end
    end
    if f.check then
        local ok, why = pcall(f.check, v)
        if not ok then return 'could not be checked' end
        if type(why) == 'string' then return why end
    end
    return nil
end

-- ============================================
-- Claims
-- ============================================
--
-- What a player's game SAYS (a form's typed answer, the health their game reports) is a claim: a
-- card's output pin marked `claim`. A claim may not reach an amount, a price, or the player or car a
-- card with a power acts on, unless it first passes a Clamp whose High is not a claim itself. Followed
-- through value cards (a Formula of a claim is a claim) and through variables (a variable set from a
-- claim is one wherever it is read). Compile's own pass, so a switch-on and a Test refuse it, not
-- only the editor's Check.
local GUARDED = { number = true, player = true, character = true, vehicle = true }

local function claimProblems(doc, problems)
    local nodes = type(doc.nodes) == 'table' and doc.nodes or {}
    local links = type(doc.links) == 'table' and doc.links or {}
    local vars = {}
    for _, v in ipairs(type(doc.vars) == 'table' and doc.vars or {}) do
        if type(v) == 'table' and type(v.id) == 'string' and C.TYPES[v.type] then vars[v.id] = { type = v.type, scope = v.scope or 'everyone' } end
    end
    local info = { vars = vars }
    local P = {}
    for _, n in ipairs(nodes) do
        local def = type(n) == 'table' and type(n.id) == 'string' and C.get(n.type) or nil
        if def then
            local vin, vout = C.valuePins(def, type(n.props) == 'table' and n.props or {}, info)
            if vin then P[n.id] = { def = def, vin = vin, vout = vout, var = type(n.props) == 'table' and n.props.var or nil } end
        end
    end
    -- [node][input pin] = { node, pin } it is wired from (one wire per value input)
    local into = {}
    for _, l in ipairs(links) do
        local to = type(l) == 'table' and l.to
        local from = type(l) == 'table' and l.from
        local t = type(to) == 'table' and P[to.node]
        if t and type(to) == 'table' and type(from) == 'table' and P[from.node] then
            for _, p in ipairs(t.vin) do
                if p.key == to.pin then into[to.node] = into[to.node] or {}; into[to.node][to.pin] = from end
            end
        end
    end
    local claimed, varClaimed = {}, {}
    local function isClaim(ref) return ref ~= nil and claimed[tostring(ref.node) .. '\0' .. tostring(ref.pin)] == true end
    local changed, rounds = true, 0
    while changed and rounds < 64 do
        changed, rounds = false, rounds + 1
        for id, p in pairs(P) do
            local function mark(pin)
                local k = id .. '\0' .. pin
                if not claimed[k] then claimed[k] = true; changed = true end
            end
            for _, o in ipairs(p.vout) do if o.claim then mark(o.key) end end
            local fromClaim = false
            for _, from in pairs(into[id] or {}) do if isClaim(from) then fromClaim = true end end
            if p.def.kind == 'value' and fromClaim then
                -- A Clamp ends it, if its Low and High are the builder's (typed, or from no claim).
                local w = into[id] or {}
                local clamped = p.def.type == 'math.clamp' and not isClaim(w.max) and not isClaim(w.min)
                if not clamped then for _, o in ipairs(p.vout) do mark(o.key) end end
            end
            if type(p.var) == 'string' then
                if fromClaim and p.def.kind ~= 'value' and not varClaimed[p.var] then varClaimed[p.var] = true; changed = true end
                if varClaimed[p.var] then for _, o in ipairs(p.vout) do mark(o.key) end end
            end
        end
    end
    for id, p in pairs(P) do
        if p.def.power then
            for _, i in ipairs(p.vin) do
                if GUARDED[i.type] and isClaim((into[id] or {})[i.key]) then
                    problem(problems, 'error', id, ('%s: %s comes from what a player\'s game says (a claim): pass it through a Clamp first')
                        :format(p.def.title, i.label or i.key), i.key)
                end
            end
        end
    end
end

--- Check and compile a System document for one lane ('server' or 'client').
---@param doc table
---@param lane string|nil
---@return table|nil graph
---@return table problems   { { severity = 'error' | 'warning', node, pin, message } }
function G.compile(doc, lane)
    lane = lane or 'server'
    local problems = {}
    local function err(node, msg, pin) problem(problems, 'error', node, msg, pin) end
    local function warn(node, msg, pin) problem(problems, 'warning', node, msg, pin) end

    if type(doc) ~= 'table' then err(nil, 'a system is a table') return nil, problems end
    if doc.format ~= 1 then err(nil, 'this system was saved by a newer whip (format ' .. tostring(doc.format) .. ')') end
    if doc.kind ~= 'system' then err(nil, 'this is not a system document') end
    local nodes = type(doc.nodes) == 'table' and doc.nodes or {}
    local links = type(doc.links) == 'table' and doc.links or {}
    local rawVars = type(doc.vars) == 'table' and doc.vars or {}
    -- Over a cap, nothing more is read (a huge document is slow to check).
    if #nodes > G.MAX_NODES then err(nil, ('a system has %d cards at most'):format(G.MAX_NODES)) end
    if #links > G.MAX_LINKS then err(nil, ('a system has %d wires at most'):format(G.MAX_LINKS)) end
    if #rawVars > G.MAX_VARS then err(nil, ('a system has %d variables at most'):format(G.MAX_VARS)) end
    if #problems > 0 then return nil, problems end

    -- Variables.
    local vars = {}
    for _, v in ipairs(rawVars) do
        local name = type(v) == 'table' and v.id or nil
        if type(name) ~= 'string' or not name:match(VAR) or #name > 32 then
            err(nil, ('"%s" is not a variable name (letters, digits, _; 32 at most)'):format(tostring(name)))
        elseif vars[name] then
            err(nil, ('two variables called %s'):format(name))
        elseif not C.TYPES[v.type] or v.type == 'any' then
            err(nil, ('variable %s: "%s" is not a type'):format(name, tostring(v.type)))
        else
            local scope = v.scope or 'everyone'
            local fine = false
            for _, s in ipairs(C.SCOPES) do if s == scope then fine = true end end
            if not fine then err(nil, ('variable %s: kept for everyone, per player or per car'):format(name)) end
            local default = v.default
            if default ~= nil then
                default = C.coerce(v.type, default)
                if default == nil then err(nil, ('variable %s: its starting value is not a %s'):format(name, v.type)) end
            end
            if v.remember == true and v.type ~= 'number' and v.type ~= 'bool' and v.type ~= 'text' then
                err(nil, ('variable %s: only numbers, yes/no and text can be remembered'):format(name))
            end
            -- Not per car yet: a street car's id is handed out again after a restart, so a remembered
            -- per-car value would be another car's.
            if v.remember == true and scope == 'car' then
                err(nil, ('variable %s: a per-car variable cannot be remembered yet (for everyone or per player can)'):format(name))
            end
            vars[name] = { type = v.type, scope = scope, default = default, remember = v.remember == true }
        end
    end
    local info = { vars = vars }

    -- Cards.
    local g = { nodes = {}, execOut = {}, valueIn = {}, triggers = {}, timers = {}, watches = {}, onStart = {}, vars = vars,
                settings = type(doc.settings) == 'table' and C.copy(doc.settings) or {}, lane = lane }
    for _, n in ipairs(nodes) do
        local nid = type(n) == 'table' and n.id or nil
        if type(nid) ~= 'string' or not nid:match(ID) or #nid > 40 then
            err(nil, ('a card has a bad id (%s)'):format(tostring(nid)))
        elseif g.nodes[nid] then
            err(nid, 'two cards share this id')
        else
            local def = C.get(n.type)
            if not def then
                err(nid, ('unknown card type %s'):format(tostring(n.type)))
            else
                if def.side ~= 'both' and def.side ~= lane then
                    err(nid, ('%s runs on the %s, not here'):format(def.title, def.side == 'server' and 'server' or "player's game"))
                end
                local props = type(n.props) == 'table' and n.props or {}
                for key, f in pairs(def._fields) do
                    local why = fieldProblem(f, props[key], vars)
                    if why then err(nid, f.label and (f.label .. ' ' .. why) or (key .. ' ' .. why), key) end
                end
                local vin, vout = C.valuePins(def, props, info)
                if not vin then
                    err(nid, tostring(vout))
                    vin, vout = {}, {}
                end
                local node = { id = nid, type = n.type, def = def, props = C.copy(props) or {}, consts = {}, vin = {}, vout = {},
                               cache = {} }   -- ctx:cached: worked out once per card (a Formula's parsed line)
                local names = {}
                for _, p in ipairs(def.inputs) do names[p] = 'exec' end
                for _, p in ipairs(def.outputs) do names[p] = 'exec' end
                for _, p in ipairs(vin) do
                    if names[p.key] then err(nid, ('"%s" is already one of its pins: name it something else'):format(p.key), p.key) end
                    names[p.key] = 'value'
                    node.vin[p.key] = p
                end
                for _, p in ipairs(vout) do
                    if names[p.key] then err(nid, ('"%s" is already one of its pins: name it something else'):format(p.key), p.key) end
                    names[p.key] = 'value'
                    node.vout[p.key] = p
                end
                -- Typed-in constants: a constant for a pin that is not there is dropped; one of the
                -- wrong type is refused (a player can never be typed in).
                local values = type(n.values) == 'table' and n.values or {}
                for key, v in pairs(values) do
                    local pin = node.vin[key]
                    if pin then
                        local got = C.coerce(pin.type, v)
                        if got == nil or pin.type == 'player' or pin.type == 'character' or pin.type == 'receipt' then
                            err(nid, ('%s: that is not a %s'):format(pin.label, pin.type), key)
                        else
                            node.consts[key] = got
                        end
                    end
                end
                g.nodes[nid] = node
                if def.kind == 'trigger' then
                    if def.trigger then
                        local list = g.triggers[def.trigger.name]
                        if not list then list = {}; g.triggers[def.trigger.name] = list end
                        list[#list + 1] = nid
                    elseif def.timer then
                        g.timers[#g.timers + 1] = nid
                    elseif def.watch then
                        g.watches[#g.watches + 1] = nid
                    elseif def.onStart then
                        g.onStart[#g.onStart + 1] = nid
                    end
                end
            end
        end
    end

    -- Wires.
    local seenLinks = {}
    local execIn = {}   -- [nodeId] = { from node ids } (for the loop check)
    for _, l in ipairs(links) do
        local lid = type(l) == 'table' and l.id or nil
        local from = type(l) == 'table' and l.from or nil
        local to = type(l) == 'table' and l.to or nil
        if type(lid) ~= 'string' or seenLinks[lid] then
            err(nil, 'a wire has a missing or repeated id')
        elseif type(from) ~= 'table' or type(to) ~= 'table' then
            err(nil, ('wire %s has no ends'):format(lid))
        else
            seenLinks[lid] = true
            local a, b = g.nodes[from.node], g.nodes[to.node]
            if not a or not b then
                err(nil, ('wire %s goes to a card that is not there'):format(lid))
            elseif a.def._outputs[from.pin] then
                if not b.def._inputs[to.pin] then
                    err(b.id, ('a "then" wire must go into one of its inputs, not %s'):format(tostring(to.pin)), to.pin)
                else
                    local byPin = g.execOut[a.id]
                    if not byPin then byPin = {}; g.execOut[a.id] = byPin end
                    local list = byPin[from.pin]
                    if not list then list = {}; byPin[from.pin] = list end
                    list[#list + 1] = { node = b.id, pin = to.pin }
                    local ins = execIn[b.id]
                    if not ins then ins = {}; execIn[b.id] = ins end
                    ins[#ins + 1] = a.id
                end
            elseif a.vout[from.pin] then
                local pin = b.vin[to.pin]
                if not pin then
                    err(b.id, ('a value wire must go into one of its value inputs, not %s'):format(tostring(to.pin)), to.pin)
                elseif not C.compatible(a.vout[from.pin].type, pin.type) then
                    err(b.id, ('%s takes a %s, and this wire carries a %s'):format(pin.label, pin.type, a.vout[from.pin].type), to.pin)
                else
                    local byKey = g.valueIn[b.id]
                    if not byKey then byKey = {}; g.valueIn[b.id] = byKey end
                    if byKey[to.pin] then
                        err(b.id, ('%s already has a wire (a value input takes one)'):format(pin.label), to.pin)
                    else
                        byKey[to.pin] = { node = a.id, pin = from.pin }
                    end
                end
            else
                err(a.id, ('it has no output called %s'):format(tostring(from.pin)), from.pin)
            end
        end
    end

    -- A value input with nothing in it.
    for nid, node in pairs(g.nodes) do
        for key, pin in pairs(node.vin) do
            local wired = g.valueIn[nid] and g.valueIn[nid][key]
            if not wired and node.consts[key] == nil and pin.default == nil and not pin.optional then
                err(nid, ('%s needs a value: wire one in or type one'):format(pin.label), key)
            end
        end
    end

    -- Values wired in a loop (a value card reading itself, through others).
    local color = {}
    local function visit(nid)
        if color[nid] == 1 then return true end
        if color[nid] == 2 then return false end
        color[nid] = 1
        for _, src in pairs(g.valueIn[nid] or {}) do
            local sn = g.nodes[src.node]
            if sn and sn.def.kind == 'value' and visit(src.node) then return true end
        end
        color[nid] = 2
        return false
    end
    for nid, node in pairs(g.nodes) do
        if node.def.kind == 'value' and color[nid] == nil and visit(nid) then
            err(nid, 'its values are wired in a loop')
        end
    end
    -- ...or deeper than the walker works them out (SystemsRuntime.LIMITS.valueDepth, 32): it would
    -- refuse every pulse with a reason that points nowhere.
    local hasLoop = false
    for _, p in ipairs(problems) do if p.message == 'its values are wired in a loop' then hasLoop = true end end
    if not hasLoop then
        local depthOf = {}
        local function depth(nid)
            if depthOf[nid] then return depthOf[nid] end
            local d = 0
            for _, src in pairs(g.valueIn[nid] or {}) do
                local sn = g.nodes[src.node]
                if sn and sn.def.kind == 'value' then d = math.max(d, depth(src.node) + 1) end
            end
            depthOf[nid] = d
            return d
        end
        for nid in pairs(g.nodes) do
            if depth(nid) > G.MAX_VALUE_DEPTH then
                err(nid, ('its values come through more than %d cards: work some out with one Formula'):format(G.MAX_VALUE_DEPTH))
            end
        end
    end

    -- An exec loop must pass through a card that waits (the Director's rule: a loop of instant cards
    -- would spin until the chain limit ends it).
    local onStack, done, loopErr = {}, {}, {}
    local function walk(nid)
        if onStack[nid] then return nid end
        if done[nid] then return nil end
        onStack[nid] = true
        local node = g.nodes[nid]
        if node and node.def.kind ~= 'wait' then
            for _, list in pairs(g.execOut[nid] or {}) do
                for _, t in ipairs(list) do
                    local back = walk(t.node)
                    if back then onStack[nid] = nil; return back end
                end
            end
        end
        onStack[nid] = nil
        done[nid] = true
        return nil
    end
    for nid in pairs(g.nodes) do
        local back = not done[nid] and walk(nid)
        if back and not loopErr[back] then
            loopErr[back] = true
            err(back, 'its wires go round in a loop with no card that waits (add a Delay)')
        end
    end

    -- Advice: cards no trigger reaches.
    local reached = {}
    local stack = {}
    for nid, node in pairs(g.nodes) do if node.def.kind == 'trigger' then stack[#stack + 1] = nid end end
    while #stack > 0 do
        local nid = table.remove(stack)
        if not reached[nid] then
            reached[nid] = true
            for _, list in pairs(g.execOut[nid] or {}) do
                for _, t in ipairs(list) do stack[#stack + 1] = t.node end
            end
        end
    end
    local readBy = {}
    for nid in pairs(reached) do
        for _, src in pairs(g.valueIn[nid] or {}) do readBy[src.node] = true end
    end
    local changed = true
    while changed do
        changed = false
        for nid, node in pairs(g.nodes) do
            if node.def.kind == 'value' and readBy[nid] and not reached[nid] then
                reached[nid] = true
                changed = true
                for _, src in pairs(g.valueIn[nid] or {}) do readBy[src.node] = true end
            end
        end
    end
    for nid, node in pairs(g.nodes) do
        if not reached[nid] then
            warn(nid, node.def.kind == 'value' and 'nothing reads this' or 'nothing starts this card (wire it from a "When..." card)')
        end
    end
    local hasTrigger = false
    for _, node in pairs(g.nodes) do if node.def.kind == 'trigger' then hasTrigger = true end end
    if next(g.nodes) and not hasTrigger then err(nil, 'nothing starts this system: add a "When..." card') end
    claimProblems(doc, problems)

    for _, p in ipairs(problems) do
        if p.severity == 'error' then return nil, problems end
    end
    return g, problems
end

--- The editor's Check: compile's verdict, and what the editor draws from it.
---   ok        it compiles (it could be switched on or tested)
---   problems  compile's errors and warnings, and the advice on top (a card that cannot be tested)
---   pins      [nodeId] = { inputs, outputs }: the value pins of every card whose pins come from its
---             fields (a Formula's names, a variable's type), as the server works them out; the
---             editor's own guess at them is replaced by these
---   powers    what its cards may do ('items,money'), for the approval
---@return boolean ok
---@return table problems
---@return table extra  { pins, powers }
function G.check(doc, lane)
    local graph, problems = G.compile(doc, lane)
    problems = problems or {}
    local pins, powers = {}, {}
    local nodes = type(doc) == 'table' and type(doc.nodes) == 'table' and doc.nodes or {}
    if #nodes <= G.MAX_NODES then
        -- The variables as a card's pins see them (a bad one is compile's to say, and names nothing here).
        local vars = {}
        for _, v in ipairs(type(doc.vars) == 'table' and doc.vars or {}) do
            if type(v) == 'table' and type(v.id) == 'string' and C.TYPES[v.type] then
                vars[v.id] = { type = v.type, scope = v.scope or 'everyone' }
            end
        end
        local info = { vars = vars }
        for _, n in ipairs(nodes) do
            local def = type(n) == 'table' and type(n.id) == 'string' and C.get(n.type) or nil
            if def then
                if def.pinsFor then
                    local vin, vout = C.valuePins(def, type(n.props) == 'table' and n.props or {}, info)
                    if vin then pins[n.id] = { inputs = vin, outputs = vout } end
                end
                if def.power then
                    for _, p in ipairs(def.powers or { def.power }) do powers[p] = true end
                    -- A trigger is never a step (its pulse is followed from it), so it has no dry run.
                    if not def.dryRun and def.kind ~= 'trigger' then
                        problem(problems, 'warning', n.id, ('%s cannot be tried in a Test yet: a test stops at it'):format(def.title))
                    end
                end
            end
        end
    end
    local list = {}
    for p in pairs(powers) do list[#list + 1] = p end
    table.sort(list)
    return graph ~= nil, problems, { pins = pins, powers = table.concat(list, ',') }
end
