-- ============================================
-- SYSTEMS — the Formula card's maths
-- ============================================
--
-- A builder types one line, `speed * 3.6 > limit + 10`, and every name in it becomes an input pin on
-- the card. This file reads that line and works it out. It is OUR OWN small reader, never load(): a
-- formula is data, and nothing in it can reach a Lua function, a global or a native.
--
-- THE ONE EVALUATOR. The editor's JS only reads the names and the shape (so the pins appear as you
-- type); the answer is always worked out here, by the server's Check and by the walker, so the two
-- languages cannot disagree about `%`, `^` or a division by zero.
--
-- WHAT IT TAKES
--   numbers        12   3.5   .5   1e3          (all worked out as floats: 7 // 2 does not exist)
--   text           "police"  'police'           (only to compare: job == "police")
--   yes/no         true  false
--   names          speed   limit   car_speed    (each one an input pin; up to 16)
--   a place's x/y/z   pos.x   pos.z             (a vector input)
--   maths          + - * / % ^   ( )           (% and ^ as Lua: -7 % 3 is 2, 2 ^ 10 is 1024)
--   compare        == ~= != < <= > >=           (= alone is a mistake, and said so)
--   logic          and  or  not                 (on yes/no only: `speed and 1` is refused)
--   functions      min max abs floor ceil round(x[, places]) clamp(x, lo, hi) sqrt
--                  distance(a, b)               (two places, in metres)
--
-- LIMITS: 200 characters, 16 levels of brackets and calls, 16 names. A division or % by 0, a result
-- that is not a real number (inf, NaN), or a type mix-up answers nil and why: the card's "refused".

SystemFormula = {
    MAX_LENGTH = 200,
    MAX_DEPTH = 16,
    MAX_NAMES = 16,
}
local F = SystemFormula

local FUNCS = {
    min = { min = 1, max = 16 }, max = { min = 1, max = 16 },
    abs = { min = 1, max = 1 }, floor = { min = 1, max = 1 }, ceil = { min = 1, max = 1 },
    round = { min = 1, max = 2 }, clamp = { min = 3, max = 3 }, sqrt = { min = 1, max = 1 },
    distance = { min = 2, max = 2 },
}
local WORDS = { ['and'] = true, ['or'] = true, ['not'] = true, ['true'] = true, ['false'] = true }

-- ============================================
-- Reading the line into tokens
-- ============================================

local function tokenize(src)
    local toks, i, n = {}, 1, #src
    while i <= n do
        local c = src:sub(i, i)
        if c:match('%s') then
            i = i + 1
        elseif c:match('%d') or (c == '.' and src:sub(i + 1, i + 1):match('%d')) then
            local _, e = src:find('^%d*%.?%d*', i)
            local j = e + 1
            local ex = src:match('^[eE][%+%-]?%d+', j)
            if ex then j = j + #ex end
            local text = src:sub(i, j - 1)
            local v = tonumber(text)
            if v == nil then return nil, ('"%s" is not a number'):format(text) end
            -- 1e999 reads as inf: refused here, as the header promises
            if v ~= v or v == math.huge or v == -math.huge then return nil, ('"%s" is too big a number'):format(text) end
            toks[#toks + 1] = { t = 'num', v = v + 0.0, at = i }
            i = j
        elseif c:match('[%a_]') then
            local word = src:match('^[%a_][%w_]*', i)
            toks[#toks + 1] = { t = WORDS[word] and word or 'name', v = word, at = i }
            i = i + #word
        elseif c == '"' or c == "'" then
            local close = src:find(c, i + 1, true)
            if not close then return nil, 'a piece of text is missing its closing quote' end
            toks[#toks + 1] = { t = 'str', v = src:sub(i + 1, close - 1), at = i }
            i = close + 1
        else
            local two = src:sub(i, i + 1)
            if two == '==' or two == '~=' or two == '!=' or two == '<=' or two == '>=' then
                toks[#toks + 1] = { t = two == '!=' and '~=' or two, at = i }
                i = i + 2
            elseif c == '=' then
                return nil, 'use == to compare (= alone sets nothing here)'
            elseif ('+-*/%^()<>,.'):find(c, 1, true) then
                toks[#toks + 1] = { t = c, at = i }
                i = i + 1
            else
                -- The whole letter, not its first byte (é is two): the editor's reader says the same.
                return nil, ('"%s" means nothing in a formula'):format(src:match('^[\194-\244][\128-\191]*', i) or c)
            end
        end
    end
    toks[#toks + 1] = { t = 'end', at = n + 1 }
    return toks
end

-- ============================================
-- Parsing (Lua's order: or < and < compare < + - < * / % < not, unary - < ^ < x.y, f())
-- ============================================

local Parser = {}
Parser.__index = Parser

function Parser:peek() return self.toks[self.i] end
function Parser:take() local t = self.toks[self.i]; self.i = self.i + 1; return t end
function Parser:fail(msg) error({ formula = msg }, 0) end
function Parser:expect(kind, msg)
    local t = self:take()
    if t.t ~= kind then self:fail(msg) end
    return t
end
function Parser:enter()
    self.depth = self.depth + 1
    if self.depth > F.MAX_DEPTH then self:fail(('more than %d levels of brackets'):format(F.MAX_DEPTH)) end
end
function Parser:leave() self.depth = self.depth - 1 end

local BINARY = {
    ['or'] = 1, ['and'] = 2,
    ['=='] = 3, ['~='] = 3, ['<'] = 3, ['<='] = 3, ['>'] = 3, ['>='] = 3,
    ['+'] = 4, ['-'] = 4,
    ['*'] = 5, ['/'] = 5, ['%'] = 5,
}
local UNARY_LEVEL = 6   -- not and unary - bind tighter than any binary operator; ^ tighter still

function Parser:primary()
    local t = self:take()
    if t.t == 'num' then return { k = 'num', v = t.v } end
    if t.t == 'str' then return { k = 'str', v = t.v } end
    if t.t == 'true' then return { k = 'bool', v = true } end
    if t.t == 'false' then return { k = 'bool', v = false } end
    if t.t == '(' then
        self:enter()
        local e = self:expr(0)
        self:expect(')', 'a bracket ( is never closed')
        self:leave()
        return e
    end
    if t.t == 'name' then
        if self:peek().t == '(' then
            local spec = FUNCS[t.v]
            if not spec then self:fail(('there is no function called %s'):format(t.v)) end
            self:take()
            self:enter()
            local args = {}
            if self:peek().t ~= ')' then
                while true do
                    args[#args + 1] = self:expr(0)
                    if self:peek().t ~= ',' then break end
                    self:take()
                end
            end
            self:expect(')', ('%s( is never closed'):format(t.v))
            self:leave()
            if #args < spec.min or #args > spec.max then
                self:fail(spec.min == spec.max and ('%s takes %d'):format(t.v, spec.min)
                    or ('%s takes %d to %d'):format(t.v, spec.min, spec.max))
            end
            return { k = 'call', f = t.v, args = args }
        end
        if FUNCS[t.v] then self:fail(('%s is a function: write %s(...)'):format(t.v, t.v)) end
        local node = { k = 'name', v = t.v }
        if self:peek().t == '.' then
            self:take()
            local f = self:take()
            if f.t ~= 'name' or not (f.v == 'x' or f.v == 'y' or f.v == 'z') then
                self:fail(('after %s. only x, y or z'):format(t.v))
            end
            node = { k = 'field', v = t.v, f = f.v }
        end
        return node
    end
    if t.t == 'end' then self:fail('the formula ends too soon') end
    self:fail(('%s cannot go there'):format(t.v or t.t))
end

function Parser:unary()
    local t = self:peek()
    if t.t == 'not' or t.t == '-' then
        self:take()
        self:enter()
        local e = self:expr(UNARY_LEVEL)
        self:leave()
        return { k = 'un', op = t.t, e = e }
    end
    local base = self:primary()
    if self:peek().t == '^' then
        self:take()
        self:enter()
        local rhs = self:expr(UNARY_LEVEL)   -- right associative; 2 ^ -1 works
        self:leave()
        return { k = 'bin', op = '^', a = base, b = rhs }
    end
    return base
end

function Parser:expr(minLevel)
    local left = self:unary()
    while true do
        local t = self:peek()
        local level = BINARY[t.t]
        if not level or level <= minLevel then break end
        self:take()
        self:enter()
        local right = self:expr(level)
        self:leave()
        left = { k = 'bin', op = t.t, a = left, b = right }
    end
    return left
end

--- Read a formula. Answers the tree, or nil and why (in words a builder reads).
---@param src string
---@return table|nil ast
---@return string|nil why
function F.parse(src)
    if type(src) ~= 'string' then return nil, 'a formula is text' end
    if #src > F.MAX_LENGTH then return nil, ('a formula is %d characters at most'):format(F.MAX_LENGTH) end
    if not src:find('%S') then return nil, 'the formula is empty' end
    local toks, why = tokenize(src)
    if not toks then return nil, why end
    local p = setmetatable({ toks = toks, i = 1, depth = 0 }, Parser)
    local ok, res = pcall(function()
        local e = p:expr(0)
        if p:peek().t ~= 'end' then p:fail(('%s cannot go there'):format(p:peek().v or p:peek().t)) end
        return e
    end)
    if not ok then
        if type(res) == 'table' and res.formula then return nil, res.formula end
        return nil, 'the formula could not be read'
    end
    local names = F.names(res)
    if #names > F.MAX_NAMES then return nil, ('a formula takes %d names at most'):format(F.MAX_NAMES) end
    return res
end

--- The names a formula reads, in the order they first appear: its input pins.
---@param ast table
---@return string[]
function F.names(ast)
    local out, seen = {}, {}
    local function walk(n)
        if n.k == 'name' or n.k == 'field' then
            if not seen[n.v] then seen[n.v] = true; out[#out + 1] = n.v end
        elseif n.k == 'un' then walk(n.e)
        elseif n.k == 'bin' then walk(n.a); walk(n.b)
        elseif n.k == 'call' then for _, a in ipairs(n.args) do walk(a) end
        end
    end
    walk(ast)
    return out
end

--- What a name is used as: 'vector' when only ever read as name.x/y/z or passed to distance(),
--- otherwise 'number' (text and yes/no inputs are 'any': a pin of the formula takes what it is given).
---@return table types   [name] = 'vector' | 'any'
function F.inputTypes(ast)
    local types = {}
    local function walk(n, asPlace)
        if n.k == 'field' then
            types[n.v] = types[n.v] or 'vector'
        elseif n.k == 'name' then
            if asPlace then types[n.v] = types[n.v] or 'vector' else types[n.v] = 'any' end
        elseif n.k == 'un' then walk(n.e)
        elseif n.k == 'bin' then walk(n.a); walk(n.b)
        elseif n.k == 'call' then
            for _, a in ipairs(n.args) do walk(a, n.f == 'distance') end
        end
    end
    walk(ast)
    return types
end

--- What a formula answers: 'bool' (a comparison, and/or/not), 'number' (maths), or 'any'.
function F.resultType(ast)
    if ast.k == 'bool' then return 'bool' end
    if ast.k == 'num' then return 'number' end
    if ast.k == 'str' then return 'text' end
    if ast.k == 'un' then return ast.op == 'not' and 'bool' or 'number' end
    if ast.k == 'bin' then
        if BINARY[ast.op] and BINARY[ast.op] <= 3 then return 'bool' end
        return 'number'
    end
    if ast.k == 'call' then return 'number' end
    if ast.k == 'field' then return 'number' end
    return 'any'
end

-- ============================================
-- Working it out
-- ============================================

local function bad(msg) error({ formula = msg }, 0) end

local function num(v, what)
    if type(v) ~= 'number' then bad(('%s is not a number'):format(what)) end
    return v
end

local function place(v, what)
    if type(v) ~= 'table' and type(v) ~= 'vector3' and type(v) ~= 'vector4' then
        bad(('%s is not a place'):format(what))
    end
    local x, y, z = tonumber(v.x), tonumber(v.y), tonumber(v.z)
    if not (x and y and z) then bad(('%s is not a place'):format(what)) end
    return x, y, z
end

local function finite(v)
    if type(v) == 'number' and (v ~= v or v == math.huge or v == -math.huge) then
        bad('the answer is not a real number (a division by nothing, or too big)')
    end
    return v
end

local function label(n)
    if n.k == 'name' then return n.v end
    if n.k == 'field' then return n.v .. '.' .. n.f end
    return 'a part of the formula'
end

local eval

local CALLS = {
    min = function(a) local m = a[1]; for i = 2, #a do if a[i] < m then m = a[i] end end; return m end,
    max = function(a) local m = a[1]; for i = 2, #a do if a[i] > m then m = a[i] end end; return m end,
    abs = function(a) return math.abs(a[1]) end,
    floor = function(a) return math.floor(a[1]) + 0.0 end,
    ceil = function(a) return math.ceil(a[1]) + 0.0 end,
    round = function(a)
        local places = math.floor(a[2] or 0)
        if places < 0 or places > 6 then bad('round takes 0 to 6 places') end
        local m = 10 ^ places
        local v = a[1] * m
        v = v >= 0 and math.floor(v + 0.5) or -math.floor(-v + 0.5)
        return v / m
    end,
    clamp = function(a)
        if a[2] > a[3] then bad('clamp: the low end is above the high end') end
        return math.max(a[2], math.min(a[3], a[1]))
    end,
    sqrt = function(a)
        if a[1] < 0 then bad('sqrt of a number below 0') end
        return math.sqrt(a[1])
    end,
}

eval = function(n, env)
    local k = n.k
    if k == 'num' or k == 'str' or k == 'bool' then return n.v end
    if k == 'name' then
        local v = env[n.v]
        if v == nil then bad(('%s has no value'):format(n.v)) end
        -- Inputs too: a pin fed inf or NaN by another card is refused (NaN makes every comparison false,
        -- `x > limit` and `x <= limit` alike).
        if type(v) == 'number' then
            if v ~= v or v == math.huge or v == -math.huge then bad(('%s is not a real number'):format(n.v)) end
            return v + 0.0
        end
        return v
    end
    if k == 'field' then
        local x, y, z = place(env[n.v], n.v)
        return finite((n.f == 'x' and x or n.f == 'y' and y or z) + 0.0)
    end
    if k == 'un' then
        local v = eval(n.e, env)
        if n.op == 'not' then
            if type(v) ~= 'boolean' then bad(('not %s: that is not a yes/no'):format(label(n.e))) end
            return not v
        end
        return -num(v, label(n.e))
    end
    if k == 'bin' then
        local op = n.op
        if op == 'and' or op == 'or' then
            local a = eval(n.a, env)
            if type(a) ~= 'boolean' then bad(('%s %s ...: that is not a yes/no'):format(label(n.a), op)) end
            if op == 'and' and not a then return false end
            if op == 'or' and a then return true end
            local b = eval(n.b, env)
            if type(b) ~= 'boolean' then bad(('... %s %s: that is not a yes/no'):format(op, label(n.b))) end
            return b
        end
        local a, b = eval(n.a, env), eval(n.b, env)
        if op == '==' or op == '~=' then
            local same
            if type(a) == 'number' and type(b) == 'number' then same = a == b
            elseif type(a) ~= type(b) then bad(('%s and %s are different kinds of thing'):format(label(n.a), label(n.b)))
            elseif type(a) == 'table' then
                -- Every input is a copy, so two tables are never the same table: a player is the same
                -- player by their server id, a place the same place by its x, y and z.
                if a.source ~= nil or b.source ~= nil then same = a.source == b.source
                elseif a.x ~= nil and b.x ~= nil then same = a.x == b.x and a.y == b.y and a.z == b.z
                else bad(('%s and %s cannot be compared'):format(label(n.a), label(n.b))) end
            else same = a == b end
            if op == '==' then return same end
            return not same
        end
        if op == '<' or op == '<=' or op == '>' or op == '>=' then
            num(a, label(n.a)); num(b, label(n.b))
            if op == '<' then return a < b elseif op == '<=' then return a <= b
            elseif op == '>' then return a > b else return a >= b end
        end
        num(a, label(n.a)); num(b, label(n.b))
        if op == '+' then return finite(a + b) end
        if op == '-' then return finite(a - b) end
        if op == '*' then return finite(a * b) end
        if op == '/' then
            if b == 0 then bad('a division by 0') end
            return finite(a / b)
        end
        if op == '%' then
            if b == 0 then bad('% by 0') end
            return finite(a - math.floor(a / b) * b)
        end
        if op == '^' then return finite(a ^ b) end
    end
    if k == 'call' then
        if n.f == 'distance' then
            local ax, ay, az = place(eval(n.args[1], env), label(n.args[1]))
            local bx, by, bz = place(eval(n.args[2], env), label(n.args[2]))
            local dx, dy, dz = ax - bx, ay - by, az - bz
            return finite(math.sqrt(dx * dx + dy * dy + dz * dz))
        end
        local args = {}
        for i, a in ipairs(n.args) do args[i] = num(eval(a, env), label(a)) + 0.0 end
        return finite(CALLS[n.f](args))
    end
    bad('a part of the formula could not be worked out')
end

--- Work a read formula out with these inputs. Answers the value, or nil and why.
---@param ast table          F.parse's tree
---@param env table          [name] = value (numbers, text, yes/no, places)
---@return any|nil value
---@return string|nil why
function F.eval(ast, env)
    local ok, res = pcall(eval, ast, env or {})
    if not ok then
        if type(res) == 'table' and res.formula then return nil, res.formula end
        return nil, 'the formula could not be worked out'
    end
    -- And the answer itself, whatever made it.
    if type(res) == 'number' and (res ~= res or res == math.huge or res == -math.huge) then
        return nil, 'the answer is not a real number (a division by nothing, or too big)'
    end
    return res
end
