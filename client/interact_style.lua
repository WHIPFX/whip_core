-- ============================================
-- PROMPT STYLES — how a world prompt looks and moves, from one place
-- ============================================
--
-- A style is one table, and the world renderer reads every number (size, colour, speed, opacity)
-- from it.
--
-- Where a prompt's style comes from, first match wins:
--   1. its own `style` (AddAction's, AddPoint's, Interactions.register's): a name, or a table
--   2. its group's, from Config.Interact3D.groupStyles (doors, vehicles, ground_items, ...)
--   3. 'default'
--
-- A style is a table of any of these (shared/interact_spec.lua checks them, InteractSpec.STYLE):
--   base = 'subtle'                           start from another named style
--   badgeScale = 1.2, labelScale = 0.9        the circle's and the label's size
--   opacity = { seen, inReach, focused }      0-1 in each state (in sight / in reach / E acts on it)
--   tint = '#ffc850', labelTint = ...         colours; both are drawn white, so white is no change
--   fadeMs, crossfadeMs, slideMs              how long each kind of movement takes
--   flash = 'blink' | 'fade', flashMs         an answer flash: twice, or once
--   gap, stackGap, stackAlpha, previewScale   the spacing and the option stack
--   cullBehind = false                        a sign is drawn from behind as well
--   easing = 'out' (and fadeEasing, crossfadeEasing, slideEasing)
--                                             'smooth' | 'linear' | 'out' | 'inOut' | 'back'
--   appear = 'pop', appearMs = 220            how it arrives: 'fade' | 'pop' | 'slide' | 'none'
--   focus = 'pop'                             becoming the one E acts on: 'none' | 'pop' | 'pulse'
--   idle = 'bob'                              while it is not: 'none' | 'pulse' | 'bob'
--   press = 'pop'                             when it is used: 'none' | 'pop'
--   labelWeight = 800, labelOutline = 3, labelOutlineColour = '#000', labelCase = 'upper',
--   labelShadow = false                       how the label's words are set
--   theme = 'glass'                           the prompt's look: 'keycap' (square), 'classic'
--                                             (round), 'glass', 'rim', 'dot' (badge.html THEMES)
--   dark = true                               black and white swapped (the square and the circle):
--                                             unset, the player's own choice (Dark prompts)
--
-- 'default' is Config.Interact3D (its fadeMs, flashMs, gap and the rest) with whatever
-- Config.Interact3D.styles.default sets on top. The named ones are Config.Interact3D.styles.
-- Its theme is the player's own shape (Server Settings → Prompt shape), which follows
-- Config.Interact3D.theme until they pick: square by default.
--
-- Resolved once, read every frame. A style resolves into a flat table of numbers, kept until the
-- settings change (/whip → Settings): a name in `named`, a table in a weak-keyed cache that lets it
-- go with the prompt that held it. The renderer asks InteractStyle.of on score frames, which is a
-- table lookup.

InteractStyle = {}

local DEFAULT_OPACITY = { seen = 0.35, inReach = 0.85, focused = 1.0 }

--- [name] = resolved, and [style table] = resolved. Emptied when the settings change.
local named = {}
local fromTable = setmetatable({}, { __mode = 'k' })

--- A style's settings said once each (Config.Interact3D.styles is read here, not by AddAction).
local warnedConfig = {}

--- The shapes prompts come in by default, for the server (Config.Interact3D.theme) and each player
--- (pause menu, Server Settings → Map & HUD → Prompt shape). The other themes are a style's to name.
local SHAPES = { keycap = true, classic = true }

--- The theme 'default' wears: the player's own choice, which follows the server's until they make
--- one (the row's default), else the rounded square.
local function baseTheme()
    local mine = PlayerPrefs ~= nil and PlayerPrefs.get ~= nil and PlayerPrefs.get('prompts.shape') or nil
    if SHAPES[mine] then return mine end
    local server = (Config.Interact3D or {}).theme
    if SHAPES[server] then return server end
    return 'keycap'
end

--- Whether 'default' is dark: the player's own switch (pause menu, Server Settings → Map & HUD → Dark
--- prompts), which follows the server's (Config.Interact3D.dark) until they flip it.
local function baseDark()
    local mine = PlayerPrefs ~= nil and PlayerPrefs.get ~= nil and PlayerPrefs.get('prompts.dark') or nil
    if type(mine) == 'boolean' then return mine end
    return (Config.Interact3D or {}).dark == true
end

-- DARK: black and white swapped, on the shapes only (badge.html's `.dark` rules are for these two; the
-- other themes have their own colours). The words go black with a white outline: the label page draws
-- them so (a tint only multiplies, and cannot make black white).
local DARK_INK = '#0a0c12'

--- The finishing touches every resolved style gets: which atlas it is drawn from (`look`: the theme,
--- and '+dark' when it is a dark shape), and its label's type with dark's colours on it.
local function finish(r)
    -- `darkShape`: drawn dark (the renderer's hold ring goes black with it).
    r.darkShape = (r.dark and SHAPES[r.theme]) and true or false
    r.look = r.darkShape and (r.theme .. '+dark') or r.theme
    local own = r.labelFmtOwn
    if own or r.darkShape then
        local f = {}
        if own then for k, v in pairs(own) do f[k] = v end end
        if r.darkShape then
            f.colour = DARK_INK
            f.outlineColour = '#ffffff'
        end
        r.labelFmt = f
        r.labelFmtKey = ('%s|%s|%s|%s|%s|%s'):format(tostring(f.weight), tostring(f.outline),
            tostring(f.outlineColour), tostring(f.case), tostring(f.shadow), tostring(f.colour))
    else
        r.labelFmt, r.labelFmtKey = nil, nil
    end
    return r
end

--- The ms a field gives, as the seconds the renderer counts in.
local function seconds(ms, fallback)
    local n = tonumber(ms)
    if not n then return fallback end
    return math.max(0, n) / 1000.0
end

--- 'default': Config.Interact3D's numbers, and nothing else yet.
local function fromConfig()
    local cfg = Config.Interact3D or {}
    local fade = seconds(cfg.fadeMs, 0.1)
    return finish({
        name = 'default',
        badgeScale = 1.0, labelScale = 1.0,
        seen = DEFAULT_OPACITY.seen, inReach = DEFAULT_OPACITY.inReach, focused = DEFAULT_OPACITY.focused,
        tintR = 255, tintG = 255, tintB = 255,
        labelR = 255, labelG = 255, labelB = 255,
        fade = fade, crossfade = fade, slide = fade,
        flash = 'blink', flashMs = tonumber(cfg.flashMs) or 900,
        gap = tonumber(cfg.gap) or 0.35,
        stackGap = tonumber(cfg.stackGap) or 0.25,
        stackAlpha = tonumber(cfg.stackAlpha) or 0.45,
        previewScale = tonumber(cfg.previewScale) or 3.4,
        cullBehind = cfg.cullBehind ~= false,
        -- How it moves: the gliding 'smooth', a plain fade in, and no animation.
        fadeEase = 'smooth', crossfadeEase = 'smooth', slideEase = 'smooth',
        appear = 'fade', appearS = 0.22,
        focusAnim = 'none', idle = 'none', press = 'none',
        animated = false,
        -- The player's shape, else the server's: baseTheme above. A style naming a theme keeps it.
        theme = baseTheme(),
        -- The player's dark switch, else the server's: baseDark above. A style saying `dark` keeps it.
        dark = baseDark(),
    })
end

--- `base` (resolved) with a checked style table laid over it: a new resolved table.
local function overlay(base, s)
    local r = {}
    for k, v in pairs(base) do r[k] = v end
    if s.badgeScale ~= nil then r.badgeScale = s.badgeScale end
    if s.labelScale ~= nil then r.labelScale = s.labelScale end
    if s.opacity then
        if s.opacity.seen ~= nil then r.seen = s.opacity.seen end
        if s.opacity.inReach ~= nil then r.inReach = s.opacity.inReach end
        if s.opacity.focused ~= nil then r.focused = s.opacity.focused end
    end
    if s.tint then r.tintR, r.tintG, r.tintB = s.tint.r, s.tint.g, s.tint.b end
    if s.labelTint then r.labelR, r.labelG, r.labelB = s.labelTint.r, s.labelTint.g, s.labelTint.b end
    if s.fadeMs ~= nil then r.fade = seconds(s.fadeMs, r.fade) end
    if s.crossfadeMs ~= nil then r.crossfade = seconds(s.crossfadeMs, r.crossfade) end
    if s.slideMs ~= nil then r.slide = seconds(s.slideMs, r.slide) end
    if s.flash ~= nil then r.flash = s.flash end
    if s.flashMs ~= nil then r.flashMs = s.flashMs end
    if s.gap ~= nil then r.gap = s.gap end
    if s.stackGap ~= nil then r.stackGap = s.stackGap end
    if s.stackAlpha ~= nil then r.stackAlpha = s.stackAlpha end
    if s.previewScale ~= nil then r.previewScale = s.previewScale end
    if s.cullBehind ~= nil then r.cullBehind = s.cullBehind end
    -- `easing` is all three; a channel's own wins over it.
    if s.easing ~= nil then r.fadeEase, r.crossfadeEase, r.slideEase = s.easing, s.easing, s.easing end
    if s.fadeEasing ~= nil then r.fadeEase = s.fadeEasing end
    if s.crossfadeEasing ~= nil then r.crossfadeEase = s.crossfadeEasing end
    if s.slideEasing ~= nil then r.slideEase = s.slideEasing end
    if s.appear ~= nil then r.appear = s.appear end
    if s.appearMs ~= nil then r.appearS = seconds(s.appearMs, r.appearS) end
    if s.focus ~= nil then r.focusAnim = s.focus end
    if s.idle ~= nil then r.idle = s.idle end
    if s.press ~= nil then r.press = s.press end
    if s.theme ~= nil then r.theme = s.theme end
    if s.dark ~= nil then r.dark = s.dark end
    -- How the label's words are set, as the style says it (`labelFmtOwn`). finish() makes it the message
    -- the label page takes with a row (dark's colours on top), and a key that says when two styles set them
    -- alike — nil for the page's own look, so 'default' sends nothing new.
    if s.labelWeight ~= nil or s.labelOutline ~= nil or s.labelOutlineColour ~= nil or s.labelCase ~= nil
        or s.labelShadow ~= nil then
        local f = {}
        local own = r.labelFmtOwn
        if own then for k, v in pairs(own) do f[k] = v end end
        if s.labelWeight ~= nil then f.weight = math.floor(s.labelWeight / 100 + 0.5) * 100 end
        if s.labelOutline ~= nil then f.outline = s.labelOutline end
        if s.labelOutlineColour ~= nil then
            local c = s.labelOutlineColour
            f.outlineColour = ('#%02x%02x%02x'):format(c.r, c.g, c.b)
        end
        if s.labelCase ~= nil then f.case = s.labelCase end
        if s.labelShadow ~= nil then f.shadow = s.labelShadow end
        r.labelFmtOwn = f
    end
    -- Whether the renderer has any animation to work out for this style; 'default' has none, so
    -- the common prompt pays nothing for them.
    r.animated = r.appear == 'pop' or r.appear == 'slide' or r.focusAnim ~= 'none' or r.idle ~= 'none'
        or r.press ~= 'none'
    return finish(r)
end

--- A style named in config, checked the way AddAction checks one (InteractSpec.style), with what was
--- wrong said in F8 once.
local function configStyle(name)
    local styles = (Config.Interact3D or {}).styles
    local raw = type(styles) == 'table' and styles[name] or nil
    if raw == nil then return nil end
    local warn = {}
    local s = InteractSpec.style(raw, 'Config.Interact3D.styles.' .. name, warn)
    for _, w in ipairs(warn) do
        if not warnedConfig[w] then
            warnedConfig[w] = true
            print('[whip_core:interact] ' .. w)
        end
    end
    return type(s) == 'table' and s or nil
end

local resolve

--- A name resolved: 'default' and the config's styles. `depth` stops a style that is its own base
--- (directly or through others) from going round for ever.
local function resolveName(name, depth)
    local r = named[name]
    if r then return r end
    local own = configStyle(name)
    if name == 'default' then
        r = own and overlay(fromConfig(), own) or fromConfig()
    elseif own == nil or depth > 4 then
        -- (A prompt's own style name was checked when it was added; this is a groupStyles entry, or
        -- a style whose bases go round in a circle.)
        local w = ("Config.Interact3D: the style '%s' is not in Config.Interact3D.styles (or its bases go round in a circle) — 'default' is used"):format(tostring(name))
        if not warnedConfig[w] then
            warnedConfig[w] = true
            print('[whip_core:interact] ' .. w)
        end
        r = resolveName('default', depth + 1)
    else
        r = overlay(resolve(own.base, depth + 1), own)
        r.name = name
    end
    named[name] = r
    return r
end

--- A style — nil, a name or a checked table — as the flat table the renderer reads.
---@param s nil|string|table
---@param depth number
---@return table
resolve = function(s, depth)
    if s == nil then return resolveName('default', depth) end
    if type(s) == 'string' then return resolveName(s, depth) end
    local r = fromTable[s]
    if r then return r end
    -- CHECKED AGAIN, ONCE. AddAction and Interactions.register hand over a table they have checked,
    -- and checking it twice changes nothing; but a table that skipped them (`tint = 'red'`) would
    -- put a nil colour into a draw call every frame. It is only the first sight of a table.
    local warn = {}
    local clean = InteractSpec.style(s, 'style', warn)
    for _, w in ipairs(warn) do
        if not warnedConfig[w] then
            warnedConfig[w] = true
            print('[whip_core:interact] ' .. w)
        end
    end
    if type(clean) ~= 'table' then clean = {} end
    r = overlay(resolve(clean.base, depth + 1), clean)
    fromTable[s] = r
    return r
end

--- The style a prompt is drawn with: its own, else its group's, else 'default'. `style` must have
--- been checked already (InteractSpec.style — AddAction and Interactions.register do it), so a table
--- here is one whip made.
---@param style nil|string|table
---@param group string|nil
---@return table resolved
function InteractStyle.of(style, group)
    if style ~= nil then return resolve(style, 0) end
    local byGroup = (Config.Interact3D or {}).groupStyles
    local g = type(byGroup) == 'table' and group and byGroup[group] or nil
    if type(g) == 'string' then return resolveName(g, 0) end
    return resolveName('default', 0)
end

--- Forget every resolved style, so the next prompt drawn reads the settings as they are now.
function InteractStyle.flush()
    named = {}
    fromTable = setmetatable({}, { __mode = 'k' })
    warnedConfig = {}
end

-- Changed in /whip → Settings: everything resolved from Config.Interact3D is out of date.
Settings.onChange('Interact3D', function() InteractStyle.flush() end)

-- ============================================
-- The player's own choice: the prompts' shape
-- ============================================
--
-- The square is the default, and a player who prefers the round prompts can have them. One row on
-- the pause menu's Server Settings page; it changes every prompt that does not name
-- a theme of its own, at once (the renderer's own atlas is redrawn in the new shape).
PlayerPrefs.define({
    key = 'prompts.shape', group = 'Map & HUD', type = 'choice', label = 'Prompt shape',
    help = 'The shape of the prompts you press E on in the world: doors, cars, cash machines.',
    options = { { value = 'keycap', label = 'Square' }, { value = 'classic', label = 'Circle' } },
    default = function()
        local server = (Config.Interact3D or {}).theme
        return server == 'classic' and 'classic' or 'keycap'
    end,
})
PlayerPrefs.onChange('prompts.shape', function() InteractStyle.flush() end)

-- And dark or not, beside it: black and white swapped (finish(), above, and badge.html's `.dark`).
PlayerPrefs.define({
    key = 'prompts.dark', group = 'Map & HUD', type = 'toggle', label = 'Dark prompts',
    help = 'Black and white swapped: a black square with a white outline and symbol, and black words with a white outline.',
    default = function() return (Config.Interact3D or {}).dark == true end,
})
PlayerPrefs.onChange('prompts.dark', function() InteractStyle.flush() end)

--- The shape 'default' wears (the vehicle controls draw their keys in it: client/pad.lua).
---@return string
function InteractStyle.baseTheme()
    return resolveName('default', 0).theme
end

--- The look the renderer's own badge atlas is drawn in ('default''s theme, and '+dark' when it is dark),
--- so the prompts most of the game wears need no second atlas.
---@return string
function InteractStyle.baseLook()
    return resolveName('default', 0).look
end
