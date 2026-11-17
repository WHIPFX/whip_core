-- Interact spec: every field AddAction (client) and AddPoint (server) take, and the one check both run.
-- An unknown field is warned about with the likely intended one; a wrong kind is left out; a number out of range is
-- clamped. Warned, not refused, and warnings come back as a third answer:
--
--     local id, why, warnings = exports.whip_core:AddAction({ ... })   -- id or false; warnings: nil, or a list
--
-- `require` is the exception: an unknown word there is refused, because an ignored requirement would leave the thing
-- open to everyone.

InteractSpec = {}

-- The fields. kind:
--   'any'       anything: checked by the code that reads it (an action's `at` and `require`)
--   'text'      text, or a function answering text (a number is read as its text)
--   'name'      text (a number is read as its text)
--   'function'  a function
--   'boolean'   true or false
--   'list'      a table
--   'number'    a number from min to max (text that reads as a number is taken as one)
--   'oneOf'     one of `values`
--   'colour'    '#ffc850', or { 255, 200, 80 }, or { r = 255, g = 200, b = 80 }: kept as { r, g, b }
--   'style'     a style's name, or a style table (STYLE below)
-- on: the places that read it ('prompt', 'part', 'radial'); left out, all of them.

--- AddAction's fields (client/actions.lua).
InteractSpec.ACTION = {
    id          = { kind = 'any' },
    at          = { kind = 'any' },
    label       = { kind = 'text' },
    icon        = { kind = 'text' },
    image       = { kind = 'text', on = { prompt = true, part = true } },
    description = { kind = 'text', on = { radial = true } },
    require     = { kind = 'any' },
    canInteract = { kind = 'function' },
    onSelect    = { kind = 'function' },
    options     = { kind = 'list' },
    enabled     = { kind = 'boolean' },
    group       = { kind = 'name' },
    reach       = { kind = 'number', min = 0.5, max = 25, on = { prompt = true } },
    seeFrom     = { kind = 'number', min = 1, max = 1000, on = { prompt = true } },
    sizeRange   = { kind = 'number', min = 0.5, max = 25, on = { prompt = true } },
    scale       = { kind = 'number', min = 0.25, max = 4, on = { prompt = true } },
    focusMode   = { kind = 'oneOf', values = { 'aim', 'near' }, on = { prompt = true } },
    onBlur      = { kind = 'function', on = { prompt = true } },
    style       = { kind = 'style', on = { prompt = true } },
    -- Hold E this long to use it; left out or 0, a press.
    holdMs      = { kind = 'number', min = 0, max = 10000, on = { prompt = true } },
    -- Hand press: true, a point, or { coords?, offset?, normal? } (client/interact_press.lua)
    press       = { kind = 'any', on = { prompt = true, part = true } },
    -- With at.entity: called when the entity is gone and the action with it.
    onGone      = { kind = 'function', on = { prompt = true } },
    -- With at.model: called as each prop comes into range and as it goes.
    onFound     = { kind = 'function', on = { prompt = true } },
    onLost      = { kind = 'function', on = { prompt = true } },
    -- With at.vehiclePart: shown above the part's own options while canInteract says yes.
    first       = { kind = 'boolean', on = { part = true } },
}

--- The ways a movement can ease: 'smooth' glides to a stop, 'linear' keeps one speed, 'out' starts fast and settles,
--- 'inOut' starts and ends slow, 'back' overshoots a little.
local EASINGS = { 'smooth', 'linear', 'out', 'inOut', 'back' }
InteractSpec.EASINGS = EASINGS

--- A style: how a world prompt looks and moves (client/interact_style.lua). Every field is optional; gaps come from
--- its `base`, then from 'default' (Config.Interact3D).
InteractSpec.STYLE = {
    base         = { kind = 'name' },                         -- start from this named style
    badgeScale   = { kind = 'number', min = 0.25, max = 4 },  -- the circle's size
    labelScale   = { kind = 'number', min = 0.25, max = 4 },  -- the label's size
    opacity      = { kind = 'list' },                         -- { seen, inReach, focused }: OPACITY
    tint         = { kind = 'colour' },                       -- the circle's colour (it is white)
    labelTint    = { kind = 'colour' },                       -- the label's colour (it is white)
    fadeMs       = { kind = 'number', min = 0, max = 2000 },  -- fading in and out, and between states
    crossfadeMs  = { kind = 'number', min = 0, max = 2000 },  -- the ring turning into the key
    slideMs      = { kind = 'number', min = 0, max = 2000 },  -- the option stack sliding
    flash        = { kind = 'oneOf', values = { 'blink', 'fade' } },   -- an answer flash's shape
    flashMs      = { kind = 'number', min = 100, max = 3000 },
    gap          = { kind = 'number', min = 0, max = 1 },     -- circle to label, a share of the circle
    stackGap     = { kind = 'number', min = 0, max = 1 },     -- between stacked option circles
    stackAlpha   = { kind = 'number', min = 0, max = 1 },     -- how visible an unselected option is
    previewScale = { kind = 'number', min = 0.5, max = 6 },   -- the picture above the label
    cullBehind   = { kind = 'boolean' },                      -- a sign is not drawn from behind
    -- Easing: `easing` sets all three, the others one each.
    easing          = { kind = 'oneOf', values = EASINGS },
    fadeEasing      = { kind = 'oneOf', values = EASINGS },
    crossfadeEasing = { kind = 'oneOf', values = EASINGS },
    slideEasing     = { kind = 'oneOf', values = EASINGS },
    -- Animations. appear: arriving; focus: becoming the one E acts on; idle: while not; press: when used.
    appear   = { kind = 'oneOf', values = { 'fade', 'pop', 'slide', 'none' } },
    appearMs = { kind = 'number', min = 0, max = 2000 },
    focus    = { kind = 'oneOf', values = { 'none', 'pop', 'pulse' } },
    idle     = { kind = 'oneOf', values = { 'none', 'pulse', 'bob' } },
    press    = { kind = 'oneOf', values = { 'none', 'pop' } },
    labelWeight        = { kind = 'number', min = 400, max = 800 },   -- 700 is bold
    labelOutline       = { kind = 'number', min = 0, max = 8 },       -- the dark edge, in texture px (3)
    labelOutlineColour = { kind = 'colour' },                         -- its colour (black)
    labelCase          = { kind = 'oneOf', values = { 'none', 'upper' } },
    labelShadow        = { kind = 'boolean' },                        -- the soft shadow under it
    -- The circle's look (html/interact3d/badge.html THEMES); 'classic' is the white disc.
    theme = { kind = 'oneOf', values = { 'classic', 'glass', 'rim', 'keycap', 'dot' } },
    -- Black and white swapped (square and circle only). Unset, the player's Dark prompts choice.
    dark = { kind = 'boolean' },
}

--- A style's `opacity`: how visible the prompt is in each of its three states, 0 to 1.
InteractSpec.STYLE_OPACITY = {
    seen    = { kind = 'number', min = 0, max = 1 },   -- in sight, too far to use
    inReach = { kind = 'number', min = 0, max = 1 },   -- close enough, but not the one E acts on
    focused = { kind = 'number', min = 0, max = 1 },   -- the one E acts on
}

--- One of an action's `options`.
InteractSpec.ACTION_OPTION = {
    id          = { kind = 'any' },
    label       = { kind = 'text' },
    icon        = { kind = 'text' },
    image       = { kind = 'text' },
    description = { kind = 'text' },
    require     = { kind = 'any' },
    canInteract = { kind = 'function' },
    onSelect    = { kind = 'function' },
    enabled     = { kind = 'boolean' },
    holdMs      = { kind = 'number', min = 0, max = 10000 },
    -- Per-option versions of the action's `press`, `first`; `options` makes a menu (world prompts): a list, or a
    -- function(ctx) returning one each time the menu opens (client/actions.lua checks which).
    press       = { kind = 'any' },
    options     = { kind = 'any' },
    first       = { kind = 'boolean' },
    -- Down a menu: after its onSelect the prompt stays on this menu (filled again, if it is filled) instead of
    -- going back to the top.
    stay        = { kind = 'boolean' },
}

--- An action's `at`. A `place` names where it is (one, checked by AddAction); other keys are read only `with` one.
InteractSpec.ACTION_AT = {
    coords      = { place = true },
    entity      = { place = true },
    netId       = { place = true },
    vehiclePart = { place = true },
    aimBox      = { place = true },   -- where the player looks, on what they aim at (client/aim_box.lua)
    aimModels   = { with = { 'aimBox' } },
    radial      = { place = true },
    model       = { place = true },
    heading     = { with = { 'coords', 'entity', 'netId', 'model' } },
    follow      = { with = { 'coords' } },
    offset      = { with = { 'entity', 'netId', 'model' } },
    bone        = { with = { 'entity', 'netId' } },
    faces       = { with = { 'model' } },
    -- Per-model placement: { [model] = { offset, heading } }
    perModel    = { with = { 'model' } },
}

--- AddPoint's fields (server/runtime_points.lua checks their values; this list is the names).
InteractSpec.POINT = {
    at = true, label = true, icon = true, options = true, require = true, audience = true,
    talk = true, quietFor = true, tag = true, reach = true, seeFrom = true, focusMode = true,
    enabled = true, onUse = true, style = true, holdMs = true,
}

--- A point's `at`.
InteractSpec.POINT_AT = {
    coords = true, heading = true, netId = true, vehicle = true, ground = true, container = true,
    offset = true, bone = true,
}

--- One of a point's options (and of a menu's, any level down).
InteractSpec.POINT_OPTION = { id = true, label = true, icon = true, require = true, options = true }

--- The words a `require` may use, on an action and on a point.
InteractSpec.REQUIRE = {
    alive = true, vehicle = true, job = true, onDuty = true, jobPermission = true,
    item = true, held = true, zone = true, charId = true, ace = true,
}

-- What people write instead: words close in meaning but not in spelling, each with what to write.

local ACTION_HINT = {
    distance = "'reach'", radius = "'reach'", activeRange = "'reach'", useRange = "'reach'",
    range = "'reach' (how close to use it) or 'seeFrom' (how far away it shows)",
    visibleRange = "'seeFrom'", drawDistance = "'seeFrom'", viewDistance = "'seeFrom'",
    callback = "'onSelect'", action = "'onSelect'", onPress = "'onSelect'", onClick = "'onSelect'",
    event = "'onSelect' (send your event from it)", serverEvent = "'onSelect' (send your event from it)",
    onUse = "'onSelect' (onUse is AddPoint's, on the server)",
    condition = "'canInteract'", canUse = "'canInteract'", canSee = "'canInteract'",
    name = "'id' (or 'label' for what it says)", text = "'label'", title = "'label'",
    desc = "'description'", img = "'image'", picture = "'image'",
    size = "'scale'",
    requires = "'require'", disabled = "'enabled = false'",
    coords = "'at = { coords = ... }'", entity = "'at = { entity = ... }'", heading = "'at.heading'",
    offset = "'at.offset'", bone = "'at.bone'", model = "'at.model'", vehiclePart = "'at.vehiclePart'",
    radial = "'at = { radial = true }'",
    job = "'require = { job = ... }'", item = "'require = { item = ... }'", zone = "'require = { zone = ... }'",
    ace = "'require = { ace = ... }'",
    groups = "'require = { job = ... }' (a job's key, or a list of them; a grade is the job's role permissions: jobPermission)",
    items = "'require = { item = ... }' (a list carries all of them)", anyItem = "'require = { item = ... }' (whip asks for all of them; for any one, check in canInteract)",
    gang = "'require = { job = ... }' (whip has no gangs: a gang is a job)", citizenid = "'require = { charId = ... }'",
    tint = "'style = { tint = ... }'", color = "'style = { tint = ... }'", colour = "'style = { tint = ... }'",
    opacity = "'style = { opacity = ... }'", alpha = "'style = { opacity = ... }'",
    badgeScale = "'style = { badgeScale = ... }'", labelScale = "'style = { labelScale = ... }'",
    fadeMs = "'style = { fadeMs = ... }'", theme = "'style'", look = "'style'",
    hold = "'holdMs' (how long, in milliseconds)", holdTime = "'holdMs'", holdDuration = "'holdMs'",
    touch = "'press' (used with the hand)", pressAnim = "'press'", handPress = "'press'",
    duration = "'holdMs' (to hold E) or 'style = { fadeMs = ... }'",
}

local AT_HINT = {
    pos = "'coords'", position = "'coords'", location = "'coords'", coord = "'coords'",
    ped = "'entity'", object = "'entity'",
    vehicle = "'vehiclePart' (a car part), or 'netId' / 'entity' (riding the car)",
    net = "'netId'", networkId = "'netId'", netid = "'netId'", part = "'vehiclePart'",
    prop = "'model' (every prop of that model)", props = "'model'", models = "'model' (a list is fine)",
    aimbox = "'aimBox'", aimAt = "'aimBox' (where the player looks, on what they aim at)", box = "'aimBox'",
}

local POINT_HINT = {
    onSelect = "'onUse' (a point's press runs on the server: onUse(source, use))",
    callback = "'onUse'", action = "'onUse'", distance = "'reach'", radius = "'reach'",
    activeRange = "'reach'", visibleRange = "'seeFrom'", requires = "'require'", name = "'label'",
    coords = "'at = { coords = ... }'", netId = "'at = { netId = ... }'",
    job = "'require = { job = ... }'", item = "'require = { item = ... }'",
    scale = "'style = { badgeScale = ..., labelScale = ... }'",
}

local STYLE_HINT = {
    scale = "'badgeScale' and 'labelScale'", size = "'badgeScale' and 'labelScale'",
    alpha = "'opacity = { seen, inReach, focused }'", color = "'tint'", colour = "'tint'",
    labelColor = "'labelTint'", labelColour = "'labelTint'", textColour = "'labelTint'",
    fade = "'fadeMs'", fadeTime = "'fadeMs'", duration = "'fadeMs'", speed = "'fadeMs' (milliseconds: lower is faster)",
    preset = "'base'", inherit = "'base'", extends = "'base'",
    ease = "'easing'", tween = "'easing'", animation = "'appear', 'focus', 'idle' or 'press'",
    onAppear = "'appear'", onFocus = "'focus'", onPress = "'press'", hover = "'focus'",
    labelOutlineColor = "'labelOutlineColour'", outlineColour = "'labelOutlineColour'",
    outlineColor = "'labelOutlineColour'", outline = "'labelOutline'", labelStroke = "'labelOutline'",
    labelBold = "'labelWeight'", fontWeight = "'labelWeight'", weight = "'labelWeight'",
    uppercase = "labelCase = 'upper'", labelUpper = "labelCase = 'upper'",
    skin = "'theme'", look = "'theme'", shape = "'theme' ('keycap' is square, 'dot' starts small)",
    font = "nothing — prompts are set in whip's one face, Plus Jakarta Sans",
    labelFont = "nothing — prompts are set in whip's one face, Plus Jakarta Sans",
}

local OPACITY_HINT = {
    idle = "'seen'", far = "'seen'", active = "'inReach'", near = "'inReach'", inRange = "'inReach'",
    focus = "'focused'", selected = "'focused'",
}

local POINT_AT_HINT = {
    entity = "'netId' (the server knows an entity by its network id)", pos = "'coords'",
    position = "'coords'", coord = "'coords'",
}

local POINT_OPTION_HINT = {
    onUse = "nothing — an option has no onUse of its own: the point's onUse gets use.option",
    onSelect = "nothing — an option has no onSelect of its own: the point's onUse gets use.option",
    requires = "'require'",
}

--- Words people copy into a `require`.
local REQUIRE_HINT = {
    jobs = "'job'", items = "'item'", charIds = "'charId'", zones = "'zone'", aces = "'ace'",
    onduty = "'onDuty'", lockpick = 'nothing — lockpicking is a door rule, not an action requirement',
    groups = "'job' (ox_target's groups: a job's key, or a list)", gang = "'job' (whip has no gangs: a gang is a job)",
    grade = "'jobPermission' (a role's permission, not a number)", citizenid = "'charId'",
    holding = "'held'", inHand = "'held'", hand = "'held'", weapon = "'held' (the item in the hand, by its key)",
}

InteractSpec.HINT = {
    ACTION = ACTION_HINT, ACTION_OPTION = ACTION_HINT, ACTION_AT = AT_HINT,
    POINT = POINT_HINT, POINT_AT = POINT_AT_HINT, POINT_OPTION = POINT_OPTION_HINT,
    STYLE = STYLE_HINT, STYLE_OPACITY = OPACITY_HINT,
}

-- Small parts

--- A function, or one handed over an export (a callable table that throws when indexed: read only with rawget).
function InteractSpec.callable(v)
    if type(v) == 'function' then return true end
    if type(v) ~= 'table' then return false end
    if rawget(v, '__cfx_functionReference') ~= nil then return true end
    local mt = getmetatable(v)
    return type(mt) == 'table' and rawget(mt, '__call') ~= nil
end

--- How many single-letter edits (add, drop, change, or swap of neighbours) turn `a` into `b` (both lowercased).
local function edits(a, b)
    local la, lb = #a, #b
    if math.abs(la - lb) > 2 then return 3 end
    local before, prev = nil, {}
    for j = 0, lb do prev[j] = j end
    for i = 1, la do
        local cur = { [0] = i }
        local ca = a:sub(i, i)
        for j = 1, lb do
            local cb = b:sub(j, j)
            local cost = (ca == cb) and 0 or 1
            cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            if before and i > 1 and j > 1 and ca == b:sub(j - 1, j - 1) and a:sub(i - 1, i - 1) == cb then
                cur[j] = math.min(cur[j], before[j - 2] + 1)
            end
        end
        before, prev = prev, cur
    end
    return prev[lb]
end

--- The field `word` most likely meant: a hint, else the nearest name in `fields` (one edit for a short name, two for a
--- longer one). nil when nothing is close.
---@param word any
---@param fields table  [name] = anything
---@param hints table|nil  [word] = what to write instead
---@return string|nil
function InteractSpec.didYouMean(word, fields, hints)
    if type(word) ~= 'string' then return nil end
    if hints and hints[word] then return hints[word] end
    local low = word:lower()
    local best, bestD
    for name in pairs(fields) do
        local d = edits(low, name:lower())
        local allowed = #name <= 4 and 1 or 2
        if d <= allowed and (bestD == nil or d < bestD or (d == bestD and name < best)) then
            best, bestD = name, d
        end
    end
    return best and ("'" .. best .. "'") or nil
end

--- Adds a warning for every key of `t` not in `fields`. Keys starting with `_` are skipped.
---@param t table
---@param fields table  [name] = anything
---@param where string  how the warning names a key: 'at' gives 'at.coord'; '' gives 'coord'
---@param warn table  the list to add to
---@param hints table|nil
---@return table unknown  [key] = true for each one warned about
function InteractSpec.unknown(t, fields, where, warn, hints)
    local found = {}
    for k in pairs(t) do
        if fields[k] == nil and not (type(k) == 'string' and k:sub(1, 1) == '_') then
            found[k] = true
            local name = (where ~= '' and (where .. '.') or '') .. tostring(k)
            local meant = InteractSpec.didYouMean(k, fields, hints)
            warn[#warn + 1] = meant and ('%s is not a field — use %s. It was ignored'):format(name, meant)
                or ('%s is not a field. It was ignored'):format(name)
        end
    end
    return found
end

--- A value as a warning shows it: text quoted (cut at 40 letters), anything else by its kind.
local function shown(v)
    if type(v) == 'string' then return "'" .. (#v > 40 and (v:sub(1, 40) .. '…') or v) .. "'" end
    if type(v) == 'number' or type(v) == 'boolean' then return tostring(v) end
    if InteractSpec.callable(v) then return 'a function' end
    return 'a ' .. type(v)
end

--- A number held to [min, max], or nil when it is not one. Warns when not a number or outside.
---@return number|nil
function InteractSpec.number(v, name, min, max, warn)
    local n = tonumber(v)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then
        warn[#warn + 1] = ('%s is a number from %g to %g — got %s. It was left out'):format(name, min, max, shown(v))
        return nil
    end
    if n < min or n > max then
        local held = n < min and min or max
        warn[#warn + 1] = ('%s is a number from %g to %g — got %g, so %g is used'):format(name, min, max, n, held)
        return held
    end
    return n
end

--- A colour as { r, g, b } (0-255) from '#ffc850', { 255, 200, 80 } or { r = 255, ... }; nil otherwise.
local function colour(v)
    if type(v) == 'string' then
        local hex = v:match('^#?(%x%x%x%x%x%x)$')
        if not hex then return nil end
        return { r = tonumber(hex:sub(1, 2), 16), g = tonumber(hex:sub(3, 4), 16), b = tonumber(hex:sub(5, 6), 16) }
    end
    if type(v) ~= 'table' or InteractSpec.callable(v) then return nil end
    local r = tonumber(rawget(v, 'r') or rawget(v, 1))
    local g = tonumber(rawget(v, 'g') or rawget(v, 2))
    local b = tonumber(rawget(v, 'b') or rawget(v, 3))
    if not (r and g and b) then return nil end
    local function byte(n) return math.floor(math.max(0, math.min(255, n)) + 0.5) end
    return { r = byte(r), g = byte(g), b = byte(b) }
end

--- The named styles: 'default' and each in Config.Interact3D.styles.
local function styleNames()
    local names = { default = true }
    local styles = Config and Config.Interact3D and Config.Interact3D.styles
    if type(styles) == 'table' then
        for k in pairs(styles) do
            if type(k) == 'string' then names[k] = true end
        end
    end
    return names
end

--- A style's name, or nil (with a warning) when there is no such style.
local function styleName(v, name, warn)
    local names = styleNames()
    if names[v] then return v end
    local meant = InteractSpec.didYouMean(v, names)
    local all = {}
    for k in pairs(names) do all[#all + 1] = "'" .. k .. "'" end
    table.sort(all)
    warn[#warn + 1] = meant and ("%s: there is no style '%s' — use %s. It was left out"):format(name, tostring(v), meant)
        or ("%s: there is no style '%s' (there are %s). It was left out"):format(name, tostring(v), table.concat(all, ', '))
    return nil
end

--- A style (a name or a STYLE table) checked like an action's fields: what to keep, or nil. Warnings name `where`.
---@param v any
---@param where string
---@param warn table
---@return string|table|nil
function InteractSpec.style(v, where, warn)
    if v == nil then return nil end
    if type(v) == 'string' then return styleName(v, where, warn) end
    if type(v) ~= 'table' or InteractSpec.callable(v) then
        warn[#warn + 1] = ("%s is a style's name or a table of how it looks — got %s. It was left out")
            :format(where, InteractSpec.callable(v) and 'a function' or ('a ' .. type(v)))
        return nil
    end
    local out = InteractSpec.read(v, InteractSpec.STYLE, where, warn, STYLE_HINT)
    if out.base ~= nil then out.base = styleName(out.base, where .. '.base', warn) end
    if out.opacity ~= nil then
        out.opacity = InteractSpec.read(out.opacity, InteractSpec.STYLE_OPACITY, where .. '.opacity', warn, OPACITY_HINT)
    end
    return out
end

--- One value checked against its field: what to keep (nil to leave out), warning when it is not what the field takes.
local function value(v, spec, name, warn)
    if v == nil or spec.kind == 'any' then return v end
    local kind = spec.kind
    if kind == 'text' then
        if type(v) == 'string' or InteractSpec.callable(v) then return v end
        if type(v) == 'number' then return tostring(v) end
        warn[#warn + 1] = ('%s is text or a function — got %s. It was left out'):format(name, shown(v))
    elseif kind == 'name' then
        if type(v) == 'string' then return v end
        if type(v) == 'number' then return tostring(v) end
        warn[#warn + 1] = ('%s is text — got %s. It was left out'):format(name, shown(v))
    elseif kind == 'function' then
        if InteractSpec.callable(v) then return v end
        warn[#warn + 1] = ('%s is a function — got %s. It was left out'):format(name, shown(v))
    elseif kind == 'boolean' then
        if type(v) == 'boolean' then return v end
        warn[#warn + 1] = ('%s is true or false — got %s. It was left out'):format(name, shown(v))
    elseif kind == 'list' then
        if type(v) == 'table' and not InteractSpec.callable(v) then return v end
        warn[#warn + 1] = ('%s is a list — got %s. It was left out'):format(name, shown(v))
    elseif kind == 'number' then
        return InteractSpec.number(v, name, spec.min, spec.max, warn)
    elseif kind == 'oneOf' then
        for _, ok in ipairs(spec.values) do
            if v == ok then return v end
        end
        warn[#warn + 1] = ("%s is '%s' — got %s. It was left out")
            :format(name, table.concat(spec.values, "' or '"), shown(v))
    elseif kind == 'colour' then
        local c = colour(v)
        if c then return c end
        warn[#warn + 1] = ("%s is a colour: '#ffc850' or { 255, 200, 80 } — got %s. It was left out"):format(name, shown(v))
    elseif kind == 'style' then
        return InteractSpec.style(v, name, warn)
    end
    return nil
end

--- `t` read against `fields`: a copy with only the known fields, each checked. Warnings name `where` .. field.
---@param t table
---@param fields table  [name] = { kind, min?, max?, values? }
---@param where string
---@param warn table
---@param hints table|nil
---@return table copy
function InteractSpec.read(t, fields, where, warn, hints)
    InteractSpec.unknown(t, fields, where, warn, hints)
    local out = {}
    local prefix = where ~= '' and (where .. '.') or ''
    for k, spec in pairs(fields) do
        local v = rawget(t, k)
        if v ~= nil then out[k] = value(v, spec, prefix .. k, warn) end
    end
    return out
end

--- The message for a `require` word that is not one, e.g. `require.jobs is not a requirement — use 'job'`.
---@return string
function InteractSpec.notARequirement(where, k)
    local meant = InteractSpec.didYouMean(k, InteractSpec.REQUIRE, REQUIRE_HINT)
    if meant then return ('%s.%s is not a requirement — use %s'):format(where, tostring(k), meant) end
    return ('%s.%s is not a requirement (alive, vehicle, job, onDuty, jobPermission, item, held, zone, charId, ace)')
        :format(where, tostring(k))
end

--- `item` may be a list of items or one { item, count }, told apart by the `item` field.
local function requireItems(v)
    if type(v) ~= 'table' or v.item ~= nil then return { v } end
    return v
end

--- Is this a `require` table whip can read? nil when it is, or why not. Shared by AddAction and item right-click
--- options (server/item_options.lua). An unknown word is refused: ignoring it would require nothing.
---@param req any
---@param where string  how the message names it: 'require', 'option "unload" require'
---@return string|nil why
function InteractSpec.checkRequire(req, where)
    if req == nil then return nil end
    if type(req) ~= 'table' then return where .. ' must be a table' end
    for k in pairs(req) do
        if not InteractSpec.REQUIRE[k] then return InteractSpec.notARequirement(where, k) end
    end
    if req.alive ~= nil and type(req.alive) ~= 'boolean' then return where .. '.alive is true or false' end
    if req.vehicle ~= nil and req.vehicle ~= 'in' and req.vehicle ~= 'out' then
        return where .. ".vehicle is 'in' or 'out'"
    end
    if req.onDuty ~= nil and type(req.onDuty) ~= 'boolean' then return where .. '.onDuty is true or false' end
    if req.jobPermission ~= nil and type(req.jobPermission) ~= 'string' then
        return where .. '.jobPermission is the name of a permission'
    end
    if req.item ~= nil then
        for _, it in ipairs(requireItems(req.item)) do
            if (type(it) == 'table' and type(it.item) ~= 'string') or (type(it) ~= 'table' and type(it) ~= 'string') then
                return where .. ".item entries are an item key or { item = 'key', count = n }"
            end
        end
    end
    if req.held ~= nil then
        for _, key in ipairs(type(req.held) == 'table' and req.held or { req.held }) do
            if type(key) ~= 'string' then return where .. ".held is an item key, or a list of them" end
        end
    end
    return nil
end

-- Saying it

--- Warnings already printed, so each is said once: [owner|text] = true. Keyed without the id, so many NPCs with the
--- same slip cost one line.
local said = {}

--- Print each warning once, as `[whip_core:<what>] <owner>, <thing>: <warning>`.
---@param what string   'actions' | 'points'
---@param owner string  the resource that made the call
---@param thing string  'action "bench"', 'point 4294967297'
---@param warn table
function InteractSpec.say(what, owner, thing, warn)
    for _, w in ipairs(warn) do
        local key = tostring(owner) .. '|' .. w
        if not said[key] then
            said[key] = true
            print(('[whip_core:%s] %s, %s: %s'):format(what, tostring(owner), thing, w))
        end
    end
end
