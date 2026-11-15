-- Interaction points: the registry, spatial grid, scoring, focus choice and the E key.
-- Drawing is done by a renderer ('nui' or 'world', picked by Config.InteractRenderer) that signs into
-- InteractRenderers at file scope, so this file loads before both.

Interactions = {}           -- Global API table
local registry = {}         -- [id] = { id, x, y, z, label, icon, group, callback, condition }

--- whip_core's own name: the owner of every prompt registered without an `_owner` stamp.
local CORE = GetCurrentResourceName()

--- Who owns a prompt. whip_core's own registrations carry no stamp.
---@return string
local function ownerOf(data)
    return data._owner or CORE
end
local interactOpen = false  -- Tracks if any indicators are currently being drawn
local currentFocusId = nil  -- The interaction with highest priority this frame

-- While set, only prompts in this group are considered (an editor's live preview).
-- State is declared up here because the scoring thread and the Interactions functions share it.
local soloGroup = nil

-- The prompt whose focus is held, or nil: { id, onLost, hidden }. See Interactions.hold.
local holdState = nil

-- An editor's preview, or nil: { group, from }. See Interactions.setPreview.
local previewState = nil

-- When the prompts last came back from standing down, or nil while they are down. See pressIsTheirs.
local promptsBackAt = nil

-- The typed number in progress, or nil: { id, buffer, max, onSubmit, onCancel, held }.
---@type table|nil
local inputState = nil

-- Forward-declared: unregister() and setOptions() have to be able to kill a live input.
local endInput

-- The renderer registry, [name] = renderer.
InteractRenderers = {}

-- Spatial grid: one cell bucket per 25 m, so scoring cost follows what is near the player.
-- Points live in exactly one cell, tracked on the entry as _cell.

local CELL_SIZE = 25.0

-- A moving prompt off screen is asked where it is at most this often, and only within its reach plus the slack.
local REFOLLOW_MS    = 250
local REFOLLOW_SLACK = 2.0

--- Is this prompt a sign (it has a heading) seen from behind by a camera at `cam`? Billboards never are.
---@return boolean
local function seenFromBehind(data, cam)
    if data.heading == nil then return false end
    local h = math.rad(data.heading)
    -- A tilted sign (a `follow`'s `tilt`: a garage door swung up) faces up or down as much as out.
    local t = data.tilt and math.rad(data.tilt) or 0.0
    local c = math.cos(t)
    return (-math.sin(h) * c * (cam.x - data.x) + math.cos(h) * c * (cam.y - data.y)
            + math.sin(t) * (cam.z - data.z)) <= 0.0
end

local grid = {}   -- [cellKey] = { [id] = true }

local function gridCellKey(x, y)
    return math.floor(x / CELL_SIZE) .. '_' .. math.floor(y / CELL_SIZE)
end

local function gridInsert(id, data)
    local key = gridCellKey(data.x, data.y)
    data._cell = key
    local bucket = grid[key]
    if not bucket then bucket = {}; grid[key] = bucket end
    bucket[id] = true
end

local function gridRemove(id, data)
    local bucket = data and data._cell and grid[data._cell]
    if bucket then
        bucket[id] = nil
        if not next(bucket) then grid[data._cell] = nil end
    end
end

-- A callback that throws is reported once per prompt per field, so a per-frame callback cannot flood F8.
-- Cleared when the prompt is removed.
local throwReported = {}

-- /whipcost's line for a prompt's conditions and options, by its owner.
local _conditionCostNames = {}
local function conditionCostName(owner)
    owner = owner or 'whip_core'
    local name = _conditionCostNames[owner]
    if not name then
        name = ('prompts, part: %s\'s conditions and options'):format(owner)
        _conditionCostNames[owner] = name
    end
    return name
end

---@param id string
---@param what string  'label' | 'icon' | 'condition' | 'follow' | 'option "x" condition'
---@param err any
local function reportThrow(id, what, err)
    local key = tostring(id) .. '|' .. what
    if throwReported[key] then return end
    throwReported[key] = true
    print(('[whip_core:interact] %s callback for "%s" threw (reported once): %s')
        :format(what, tostring(id), tostring(err)))
end

--- The one removal path: every public remove funnels through here so the grid and registry agree.
local function unregister(id)
    local data = registry[id]
    if not data then return false end

    -- A prompt being typed into cannot just disappear: the digit reader would keep swallowing number keys.
    if inputState and inputState.id == id then endInput(true) end

    gridRemove(id, data)
    registry[id] = nil

    -- Forget its throw reports so a re-registered fix is judged fresh.
    local prefix = tostring(id) .. '|'
    local n = #prefix
    for key in pairs(throwReported) do
        if key:sub(1, n) == prefix then throwReported[key] = nil end
    end

    return true
end

-- Multi-choice options: a prompt carries a list. The circle shows the selected option, scrolling moves
-- through the rest, E fires the selected one. A registration without `options` gets one implicit option
-- that inherits the prompt's icon and label.

--- Read `field` off an option, falling back to the prompt's own; call it if it is not a string.
--- Anything not a string is called: a function that crossed an export is a callable table, so type() would lie.
---@return any
local function resolveField(data, opt, field)
    local v = opt and opt[field]
    if v == nil then v = data[field] end

    if v == nil then return nil end
    if type(v) == 'string' then return v end

    local ok, res = pcall(v)
    if not ok then
        reportThrow(data.id, field, res)
        return nil
    end
    return res
end

--- Normalise a registration's options into a list.
---@return table options
local function buildOptions(data)
    local src = data.options
    if type(src) == 'table' and #src > 0 then
        local out = {}
        for i = 1, #src do
            local o = src[i]
            out[i] = {
                id        = o.id or ('opt' .. i),
                icon      = o.icon,       -- nil inherits the prompt's
                label     = o.label,
                -- A picture path under html/, shown above the label by the world renderer.
                image     = o.image,
                condition = o.condition,
                callback  = o.callback,
                -- Hold to use, in ms; nil inherits the prompt's.
                holdMs    = tonumber(o.holdMs),
            }
        end
        return out
    end

    -- The implicit option inherits icon, label and callback from the prompt.
    return { { id = 'default' } }
end

--- Rebuild which options are offerable and keep the selection valid. `_avail` holds indices into `options`,
--- reused between frames. If no option passes its condition the prompt does not draw.
---@return number count
local function refreshOptions(data)
    local opts = data.options
    if not opts then return 0 end

    local avail = data._avail
    if not avail then avail = {}; data._avail = avail end

    local n = 0
    for i = 1, #opts do
        local o = opts[i]
        local ok = true
        if o.condition then
            local good, res = pcall(o.condition)
            if not good then
                reportThrow(data.id, 'option "' .. tostring(o.id) .. '" condition', res)
            end
            ok = (good and res) and true or false
        end
        if ok then
            n = n + 1
            avail[n] = i
        end
    end
    for j = n + 1, #avail do avail[j] = nil end

    data._availN = n

    -- An option asked for by id (Interactions.setSelection) before the list existed.
    if data._wantSel ~= nil then
        for k = 1, n do
            if opts[avail[k]].id == data._wantSel then data._sel = k break end
        end
        data._wantSel = nil
    end

    -- The list can shrink under the player, so clamp the index.
    local sel = data._sel or 1
    if sel > n then sel = 1 end
    if sel < 1 then sel = 1 end
    data._sel = sel

    return n
end

--- The option E would act on right now, or nil when the prompt has nothing to offer.
local function selectedOption(data)
    local n = data._availN or 0
    if n <= 0 then return nil end
    local idx = data._avail and data._avail[data._sel or 1]
    return idx and data.options and data.options[idx] or nil
end

-- Public registration API

---@param id string
---@param vr number|nil
---@return number|nil
local function clampVisibleRange(id, vr)
    vr = tonumber(vr)
    if not vr then return nil end
    local cfg = Config.InteractVisibleRange or 5.0
    local gate = math.max(1, math.ceil(cfg / CELL_SIZE)) * CELL_SIZE
    if vr <= gate then return vr end
    print(('[whip_core:interact] "%s" asked for visibleRange %.1f but the grid only '
        .. 'searches %.1f — clamped. Raise Config.InteractVisibleRange to allow it.')
        :format(tostring(id), vr, gate))
    return gate
end

--- The id for a registration that names none: derived from owner, group, label and spot, so a
--- re-registration (onReady re-fires) replaces itself.
---@return string
local function autoId(data)
    local seed = ('%s|%s|%.1f|%.1f|%.1f'):format(tostring(data.group or ''),
        type(data.label) == 'string' and data.label or '',
        tonumber(data.x) or 0, tonumber(data.y) or 0, tonumber(data.z) or 0)
    return ('%s:auto:%08x'):format(tostring(data._owner or CORE), GetHashKey(seed) & 0xFFFFFFFF)
end

--- A style for a prompt, checked (shared/interact_spec.lua): the style to keep, or nil.
local function checkedStyle(id, style)
    if style == nil then return nil end
    local warn = {}
    local s = InteractSpec.style(style, 'style', warn)
    if #warn > 0 then InteractSpec.say('interact', 'whip_core', ('prompt "%s"'):format(tostring(id)), warn) end
    return s
end

--- Register a world interaction point.
---@param data table { id (optional string), x, y, z, label, icon?, heading?, follow?, focusMode?, visibleRange?, activeRange?, sizeRange?, scale?, onBlur?, group?, callback (function), condition? (function→bool) }
---@return string|false registeredId  false when refused
---@return string|nil reason
---
--- `heading`: world renderer only. Omitted, the prompt faces the player like a billboard; given, it stands
--- as a sign, readable from the front and hidden from behind.
--- `follow`: a function returning `x, y, z, heading`, called each frame while visible, for a point that
--- moves (a door handle). nil keeps the last position. Optional further answers, in order:
--- `pull` (metres toward the camera, so the prompt does not sit inside its prop; 0 = none),
--- `wrap` (the box a sign stands on, see interact_world.lua foldQuad), `centre` (centre the words on
--- the point), `tilt` (degrees a sign leans back), `fit` ({ width, above, below }, the box the prompt
--- stays inside).
--- `pull` and `centre` can also be given at registration.
--- `focusMode`: 'aim' (default, what you look at wins) or 'near' (closest wins, wider cone; doors).
--- `visibleRange` and `activeRange` override Config for this point: how far its circle fades in, and how
--- close you must be for the key to work. Visible range is capped to what the grid searches
--- (clampVisibleRange, above).
function Interactions.register(data)
    if type(data) ~= 'table' then return false, 'a prompt is a table: { id, x, y, z, label, callback, ... }' end
    local id = data.id
    if id == nil then id = autoId(data) end

    -- Another resource's id is refused while that owner runs.
    local prev = registry[id]
    if prev and ownerOf(prev) ~= ownerOf(data) and Registry.alive(ownerOf(prev)) then
        return false, ('prompt "%s" belongs to %s'):format(tostring(id), ownerOf(prev))
    end

    local visRange = clampVisibleRange(id, data.visibleRange)

    -- Unhook the old cell before the entry is replaced, or the stale bucket entry resurrects it.
    if prev then gridRemove(id, prev) end

    registry[id] = {
        id        = id,
        x         = data.x,
        y         = data.y,
        z         = data.z,
        label     = data.label or 'Interact',
        icon      = data.icon or 'E',
        -- Numbers go through tonumber so a satellite passing '2.0' cannot throw in the loop.
        heading   = tonumber(data.heading),   -- nil = billboard
        follow    = data.follow,
        pull      = tonumber(data.pull),   -- a follow may change it
        pullFixed = tonumber(data.pull),   -- what it goes back to when a follow says nothing
        centre      = data.centre == true, -- a follow may change it
        centreFixed = data.centre == true,
        focusMode = data.focusMode, -- nil/'aim' = point at it; 'near' = closest wins

        -- nil for both means "use Config".
        visibleRange = visRange,
        activeRange  = tonumber(data.activeRange),

        -- Draw size, separate from reach: pinned at registration, never changed by setRange.
        sizeRange = tonumber(data.sizeRange) or tonumber(data.activeRange),

        -- Size multiplier for one family of prompts, held to 0.25-4.
        scale = tonumber(data.scale) and math.max(0.25, math.min(4.0, tonumber(data.scale))) or nil,

        -- A style's name or table, else its group's (client/interact_style.lua).
        style = checkedStyle(id, data.style),

        -- Hold to use: ms E (A on a pad) is held before the callback runs. nil is a press.
        holdMs = tonumber(data.holdMs),

        -- Each option used plays the hand press towards the circle (client/interact_press.lua).
        press = data.press == true,

        options = buildOptions(data),

        -- Called when this prompt stops being the focused one.
        onBlur = data.onBlur,

        group     = data.group or 'default',
        callback  = data.callback,
        condition = data.condition,
        -- Offered while downed / seated too (set from AddAction's `alive = false` or `vehicle = 'in'`).
        allowDowned = data.allowDowned == true,
        allowSeated = data.allowSeated == true,
        -- Who registered this, stamped by the export wrapper; nil for whip_core's own.
        _owner    = data._owner,
    }

    gridInsert(id, registry[id])

    return id
end

--- Remove every interaction registered by a given resource.
---@param resource string
---@return number removed
function Interactions.removeByOwner(resource)
    local toRemove = {}
    for id, data in pairs(registry) do
        if data._owner == resource then
            toRemove[#toRemove + 1] = id
        end
    end
    for _, id in ipairs(toRemove) do
        unregister(id)
    end
    return #toRemove
end

--- Remove one of the caller's own interaction points.
---@param id string
---@param owner string|nil  who is asking; nil is whip_core (the export passes the caller)
---@return boolean ok
---@return string|nil reason
function Interactions.remove(id, owner)
    owner = owner or CORE
    local data = registry[id]
    if not data then return false, ('no prompt "%s"'):format(tostring(id)) end
    if ownerOf(data) ~= owner then
        return false, ('prompt "%s" belongs to %s'):format(tostring(id), ownerOf(data))
    end
    unregister(id)
    return true
end

--- Remove every one of the caller's own prompts in a group (a group name is required).
---@param group string
---@param owner string|nil  who is asking; nil is whip_core (the export passes the caller)
---@return boolean ok
---@return number|string countOrReason
function Interactions.removeGroup(group, owner)
    if type(group) ~= 'string' or group == '' then return false, 'a group name is required' end
    owner = owner or CORE
    local toRemove = {}
    for id, data in pairs(registry) do
        if data.group == group and ownerOf(data) == owner then
            toRemove[#toRemove + 1] = id
        end
    end
    for _, id in ipairs(toRemove) do
        unregister(id)
    end
    return true, #toRemove
end

--- Give one group the screen to itself, or hand it back. The setter must clear it on every exit.
--- Not exported: a satellite that could blank every prompt is a footgun.
---@param group string|nil  the group to show alone, or nil to show everything again
function Interactions.setSolo(group)
    soloGroup = group
    -- The E that ended a solo was the editor's, not a prompt's.
    if promptsBackAt then promptsBackAt = GetGameTimer() end
end

--- The group that has the screen to itself, or nil (IsGameInputFree reads it).
---@return string|nil
function Interactions.getSolo()
    return soloGroup
end

--- An editor's preview of the prompts a scenario will put up. While set:
---   * only that group's prompts are drawn, under the editor's screen, even while prompts are blocked;
---   * range and focus are measured from `from()` (x, y, z), not from the player;
---   * nothing can be used: no E, scroll or typing, and callbacks never run.
--- The setter clears it on every exit, as with setSolo. Not exported.
---@param group string|nil   the group to preview, or nil to end it
---@param from function|nil  → x, y, z: where the preview is seen from
function Interactions.setPreview(group, from)
    previewState = group and { group = group, from = from } or nil
end

--- The group being previewed, or nil.
---@return string|nil
function Interactions.getPreview()
    return previewState and previewState.group or nil
end

--- Hold one prompt's focus (a conversation): it is the only prompt considered and keeps the focus
--- while within its visible range, on screen or not. `onLost(why)` is called when it ends: 'lost'
--- (out of range or removed) or 'blocked' (a screen opened, the player went down or into a car).
--- A progress bar does not end it. The holder calls Interactions.release on its own exits.
--- `hidden`: renderers are not handed it because the holder draws it. Not exported.
---@param id string
---@param opts table|nil { onLost = function(why), hidden = boolean }
function Interactions.hold(id, opts)
    opts = opts or {}
    holdState = { id = id, onLost = opts.onLost, hidden = opts.hidden == true }
end

--- Let go of a hold (that prompt's, or any when nil). onLost is not called: this is the holder's own exit.
---@param id string|nil
function Interactions.release(id)
    if holdState and (id == nil or holdState.id == id) then holdState = nil end
end

--- The held prompt's id, or nil.
---@return string|nil
function Interactions.getHeld()
    return holdState and holdState.id or nil
end

--- The hold could not continue: say why, once.
local function endHold(why)
    local h = holdState
    holdState = nil
    if h and h.onLost then
        local ok, err = pcall(h.onLost, why)
        if not ok then print(('[whip_core:interact] ERROR in onLost for "%s": %s'):format(tostring(h.id), tostring(err))) end
    end
end

--- Update position of an existing interaction point.
---@param id string
---@param x number
---@param y number
---@param z number
function Interactions.updatePosition(id, x, y, z)
    local data = registry[id]
    if data then
        data.x = x
        data.y = y
        data.z = z
        if gridCellKey(x, y) ~= data._cell then
            gridRemove(id, data)
            gridInsert(id, data)
        end
    end
end

--- Turn an existing point without re-registering it; nil makes it a billboard again.
---@param id string
---@param heading number|nil  degrees, or nil for a billboard that faces the player
function Interactions.updateHeading(id, heading)
    local data = registry[id]
    if not data then return end
    data.heading = tonumber(heading)
end

--- Update label of an existing interaction point.
---@param id string
---@param label string
function Interactions.updateLabel(id, label)
    if registry[id] then
        registry[id].label = label
    end
end

--- Replace what a prompt can do, at runtime. The selection resets.
---@param id string
---@param options table|nil  nil restores the implicit single option from the flat fields
function Interactions.setOptions(id, options)
    local data = registry[id]
    if not data then return end

    -- Typed digits must not be submitted against a different selection.
    if inputState and inputState.id == id then endInput(true) end

    data.options = buildOptions({
        options = options,
        icon = data.icon, label = data.label, callback = data.callback,
    })

    data._sel = 1
    -- The next score frame rebuilds the available list.
    data._availN = nil
end

--- Change how close you have to be to an existing point. Absolute metres; nil means the Config
--- default. Does not touch `sizeRange`.
---@param id string
---@param visibleRange number|nil
---@param activeRange number|nil
function Interactions.setRange(id, visibleRange, activeRange)
    local data = registry[id]
    if not data then return end
    data.visibleRange = clampVisibleRange(id, visibleRange)
    data.activeRange = tonumber(activeRange)
end

--- Update the glyph in the middle of an existing point's badge (a door's padlock). A new name
--- repaints the badge atlas once.
---@param id string
---@param icon string
function Interactions.updateIcon(id, icon)
    if registry[id] then
        registry[id].icon = icon
    end
end

--- Change how a prompt looks and moves without re-registering. A style's name, a style table
--- (client/interact_style.lua), or nil for its group's.
---@param id string
---@param style string|table|nil
---@return boolean ok  false when there is no such prompt
function Interactions.setStyle(id, style)
    local data = registry[id]
    if not data then return false end
    data.style = checkedStyle(id, style)
    return true
end

--- Flash a prompt a colour, which then fades back to white (green unlock, red lock, amber refusal).
--- World renderer only. Stored on the registry, so it works on a prompt that is not visible.
---@param id string
---@param r number 0-255
---@param g number 0-255
---@param b number 0-255
function Interactions.flash(id, r, g, b)
    local data = registry[id]
    if not data then return end
    data._flashR, data._flashG, data._flashB = r, g, b
    data._flashAt = GetGameTimer()
end

--- Say something on a prompt for a moment, replacing its label, then go back to the label.
---@param id string
---@param text string   what to say. Empty or nil clears any status immediately.
---@param ms number|nil how long to say it for, in milliseconds. Default 2000.
function Interactions.setStatus(id, text, ms)
    local data = registry[id]
    if not data then return end

    if text == nil or text == '' then
        data._statusText, data._statusUntil = nil, nil
        return
    end

    data._statusText  = tostring(text)
    data._statusUntil = GetGameTimer() + (tonumber(ms) or 2000)
end

--- The label a prompt should show now: the selected option's, unless a status is talking over it.
---@return string|nil
local function labelFor(data, opt)
    local until_ = data._statusUntil
    if until_ then
        if GetGameTimer() < until_ then
            return data._statusText
        end
        -- Expired: cleared lazily, when the prompt is next resolved.
        data._statusText, data._statusUntil = nil, nil
    end
    return resolveField(data, opt, 'label')
end

-- Typing a value into a prompt (client/prompt_typing.lua): the prompt steps aside while it is typed into, and in its
-- place stands a capsule (a keyboard: "Start typing", Enter gives it) or whip's on-screen keyboard (a pad). The
-- prompt keeps the focus while it is in range, on screen or not (the player may look round), and its own keys
-- (E, scroll, A) stand down: Enter or Done submits, Esc, B or Cancel leaves.

-- The caret, for a caller that shows the text itself (a conversation's dialog): a pipe, as the label font has no
-- block characters. Half a second on, half a second off.
local CARET = '|'
local CARET_PERIOD_MS = 1000

--- End the input for any reason (submit, cancel, blur, prompt gone, blocked) and tell the caller.
---@param fire boolean should onCancel be called (false when the caller is submitting)
function endInput(fire)
    local st = inputState
    if not st then return end

    -- Cleared before the callback: onCancel may register prompts or start another input.
    inputState = nil
    PromptTyping.close()
    -- The key that ended it (Enter, A) is not a press on the prompt that comes back.
    if promptsBackAt then promptsBackAt = GetGameTimer() end

    if fire and st.onCancel then
        local ok, err = pcall(st.onCancel)
        if not ok then
            print(('[whip_core:interact] ERROR in onCancel for "%s": %s')
                :format(tostring(st.id), tostring(err)))
        end
    end
end

--- Start typing into a prompt: it steps aside for the capsule or the keyboard (client/prompt_typing.lua) and keeps the
--- focus until the value is given or left. Call setOptions before this: it cancels a running input.
---@param id string
---@param opts table { max?, numeric? (default true: digits), title?, icon?, prefix?, commas?, placeholder?, value?,
---                    capsule? (false: the caller shows the text on a keyboard), anchor?() -> x, y, z, hang?,
---                    onChange?(text), onSubmit (function(text)), onCancel? (function) }
function Interactions.beginInput(id, opts)
    local data = registry[id]
    if not data then return false end
    opts = opts or {}

    -- A running input is abandoned and told so.
    endInput(true)

    -- What is being typed, by default the selected option's words and glyph, read before the input is up (a label
    -- that shows the field reads as the option's own words here).
    local sel = selectedOption(data)
    local title = opts.title
    if title == nil and sel then title = labelFor(data, sel) end
    local icon = opts.icon
    if icon == nil then icon = resolveField(data, sel, 'icon') end

    local st = {
        id       = id,
        buffer   = '',
        onSubmit = opts.onSubmit,
        onCancel = opts.onCancel,
        onChange = opts.onChange,
    }
    inputState = st

    PromptTyping.open({
        -- Where it stands: the prompt's point, or the caller's own (a conversation's dialog).
        anchor = opts.anchor or function()
            local d = registry[id]
            if not d then return nil end
            return d.x, d.y, d.z
        end,
        numeric = opts.numeric ~= false, max = opts.max, value = opts.value,
        title = title, icon = icon, prefix = opts.prefix, commas = opts.commas, placeholder = opts.placeholder,
        capsule = opts.capsule, hang = opts.hang,
        onChange = function(text)
            if inputState ~= st then return end
            st.buffer = text
            if st.onChange then
                local ok, err = pcall(st.onChange, text)
                if not ok then print(('[whip_core:interact] ERROR in onChange for "%s": %s'):format(tostring(id), tostring(err))) end
            end
        end,
        onDone = function(text)
            if inputState ~= st then return end
            Interactions.submitInput(text)
        end,
        onCancel = function()
            if inputState ~= st then return end
            endInput(true)
        end,
    })
    st.buffer = PromptTyping.text() or ''
    return true
end

--- Give the typed value: onSubmit gets it (no onCancel). The typing's Enter or Done.
---@param text string|nil  what was typed (the typing's own when nil)
function Interactions.submitInput(text)
    local st = inputState
    if not st then return end
    text = text or st.buffer
    -- false: no onCancel, this is the successful exit.
    endInput(false)
    if st.onSubmit then
        local ok, err = pcall(st.onSubmit, text)
        if not ok then
            print(('[whip_core:interact] ERROR in onSubmit for "%s": %s'):format(tostring(st.id), tostring(err)))
        end
    end
    -- Giving the amount is a press too (the ATM).
    local typedInto = registry[st.id]
    if typedInto and typedInto.press then InteractPress.atPrompt(typedInto) end
    -- Not logged: whatever this submits to writes its own row server-side.
end

--- Stop typing, firing onCancel.
---@param id string|nil  nil cancels whatever is running; an id cancels only if it matches
function Interactions.cancelInput(id)
    if not inputState then return end
    if id ~= nil and inputState.id ~= id then return end
    endInput(true)
end

--- Is this prompt (or any prompt, with no argument) currently taking typed input?
---@param id string|nil
---@return boolean
function Interactions.inputActive(id)
    if not inputState then return false end
    if id == nil then return true end
    return inputState.id == id
end

--- What is typed so far; '' when nothing yet, nil when no input is running.
---@param id string|nil
---@return string|nil
function Interactions.inputText(id)
    if not inputState or not Interactions.inputActive(id) then return nil end
    return inputState.buffer
end

--- Put a value in the field as if typed (cleaned and cut as typing is: a number's digits only).
---@param id string|nil
---@param text string|number
---@return boolean set
function Interactions.setInputText(id, text)
    if not inputState or not Interactions.inputActive(id) then return false end
    PromptTyping.setText(text)
    inputState.buffer = PromptTyping.text() or ''
    return true
end

--- The blinking caret. A space on the off beat, so a centred label does not twitch.
---@return string
function Interactions.inputCaret()
    return (GetGameTimer() % CARET_PERIOD_MS) < (CARET_PERIOD_MS / 2) and CARET or ' '
end

--- Digits and caret together.
---@param id string|nil
---@return string|nil
function Interactions.inputDisplay(id)
    local text = Interactions.inputText(id)
    if text == nil then return nil end
    return text .. Interactions.inputCaret()
end

--- Get all registered interactions (for debug/tools).
function Interactions.getAll()
    return registry
end

--- Run one of a prompt's options as though E had been pressed on it (whip_test's interaction cases).
---@param id string
---@param optionId string|nil  the first option when nil
---@return boolean ok
---@return string|nil reason
function Interactions.fire(id, optionId)
    local data = registry[id]
    if not data then return false, 'no such prompt' end
    local opt
    for _, o in ipairs(data.options or {}) do
        if optionId == nil or tostring(o.id) == tostring(optionId) then opt = o break end
    end
    local cb = (opt and opt.callback) or data.callback
    if not cb then return false, 'it has nothing to run' end
    CreateThread(function()
        local ok, err = pcall(cb)
        if not ok then reportThrow(id, 'callback', err) end
    end)
    return true
end

--- The prompt the player is on right now, or nil. Read it before anything that yields.
---@return string|nil
function Interactions.getFocusedId()
    return currentFocusId
end

--- Which option is selected: its place among those offered now (1 = the first) and its id, or nil.
---@param id string
---@return number|nil index
---@return string|nil optionId
---@return number|nil count  how many are offered now
function Interactions.getSelection(id)
    local data = registry[id]
    if not data then return nil end
    local opt = selectedOption(data)
    if not opt then return nil end
    return data._sel or 1, opt.id, data._availN or 0
end

--- Put the selection on an option by its id, if it is offered. Call after setOptions; applied when the list is next built if not yet.
---@param id string
---@param optionId string
function Interactions.setSelection(id, optionId)
    local data = registry[id]
    if not data or optionId == nil then return end
    data._wantSel = optionId
    local n = data._availN
    if not n or not data._avail then return end
    for k = 1, n do
        local o = data.options and data.options[data._avail[k]]
        if o and o.id == optionId then data._sel = k break end
    end
    data._wantSel = nil
end

-- No Interact* exports: other resources use AddAction (client/actions.lua). Interactions.* is whip_core's own.

-- Camera forward vector

local sin = math.sin
local cos = math.cos
local abs = math.abs
local sqrt = math.sqrt
local max = math.max
local pi = math.pi

--- Camera forward direction as a unit vector. Global so other client files aim by the same maths.
function InteractGetCameraForward()
    local rot = GetFinalRenderedCamRot(2)
    local rX = rot.x * pi / 180.0
    local rZ = rot.z * pi / 180.0
    local cosX = abs(cos(rX))
    return
        -sin(rZ) * cosX,
         cos(rZ) * cosX,
         sin(rX)
end

--- What the camera is pointing at, up to `reach` metres: whether it hit, where, the surface's normal,
--- the entity hit (0 for the map), and where the camera is. The player's ped is never hit.
---@param reach number  metres
---@param flags number|nil  shape test flags: 1 the map, 16 objects, 81 map + objects + glass (the default)
---@return boolean hit
---@return vector3 coords
---@return vector3 normal
---@return number entity
---@return vector3 camera
function Interactions.aimRay(reach, flags)
    local cam = GetFinalRenderedCamCoord()
    local fx, fy, fz = InteractGetCameraForward()
    local ray = StartShapeTestRay(cam.x, cam.y, cam.z, cam.x + fx * reach, cam.y + fy * reach, cam.z + fz * reach,
        flags or 81, PlayerPedId(), 0)
    local _, hit, coords, normal, entity = GetShapeTestResult(ray)
    return hit == 1, coords, normal, entity, cam
end

-- Priority scoring

--- Priority score for an interaction point; higher wins. Global, like InteractGetCameraForward.
---@return number score (-1 if out of range or behind camera)
---@return number distance
---@return number dot (camera dot product, for behind-camera culling)
---@param distWeight number|nil    how much being close counts (default Config)
---@param cameraWeight number|nil  how much being centred counts (default Config)
---@param sharpness number|nil     exponent on the camera term; >1 tightens it toward the crosshair
---@param aimOrigin vector3|nil    where the aim ray starts (default the player's position); pass the camera for true screen-centre
function InteractComputeScore(px, py, pz, cfx, cfy, cfz, ix, iy, iz, maxRange,
                              distWeight, cameraWeight, sharpness, aimOrigin)
    local dx = ix - px
    local dy = iy - py
    local dz = iz - pz
    local dist = sqrt(dx * dx + dy * dy + dz * dz)

    if dist > maxRange or dist < 0.3 then
        return -1, dist, 0
    end

    -- Dot of camera forward and direction to target, from aimOrigin when given.
    local adx, ady, adz, alen
    if aimOrigin then
        adx, ady, adz = ix - aimOrigin.x, iy - aimOrigin.y, iz - aimOrigin.z
        alen = sqrt(adx * adx + ady * ady + adz * adz)
        -- Clamp rather than divide by zero.
        if alen < 0.001 then alen = 0.001 end
    else
        adx, ady, adz, alen = dx, dy, dz, dist
    end

    local invLen = 1.0 / alen
    local dirX = adx * invLen
    local dirY = ady * invLen
    local dirZ = adz * invLen
    local dot = cfx * dirX + cfy * dirY + cfz * dirZ

    -- Behind the camera: skip.
    if dot < -0.2 then
        return -1, dist, dot
    end

    -- 0 = far, 1 = very close
    local normalizedDist = 1.0 - (dist / maxRange)

    -- Remap dot from [-1, 1] to [0, 1]
    local cameraDot = max(0, (dot + 1.0) * 0.5)

    -- The remap is flat (90 degrees off still scores 0.5); a power separates dead centre from "in front".
    if sharpness and sharpness ~= 1 then
        cameraDot = cameraDot ^ sharpness
    end

    local dw = distWeight   or Config.InteractDistWeight   or 0.6
    local cw = cameraWeight or Config.InteractCameraWeight or 0.4

    return dw * normalizedDist + cw * cameraDot, dist, dot
end

-- Blocking conditions

--- Should interactions be blocked? Downed and seated are per-prompt (`softBlocked` below).
--- Blocking closes the prompts (clearAll below).
local function IsInteractionBlocked()
    if not PlayerLoaded then return true end
    -- `true`: the prompts' own question, which does not count their own typing mode.
    return IsGameInputFree ~= nil and not IsGameInputFree(true)
end

--- Blocked by nothing but a timed action's progress bar? A held prompt survives that.
local function blockedOnlyByBar()
    local bar = UI ~= nil and UI.IsProgressActive ~= nil and UI.IsProgressActive()
    return bar and IsGameInputFree ~= nil and IsGameInputFree(true, true)
end

--- Is the player downed / seated, and can the scan be skipped (no prompt opted in for that state)?
---@return boolean downed, boolean seated, boolean skip
local function softBlocked()
    local downed = PlayerIsDead == true
    local seated = IsPedInAnyVehicle(PlayerPedId(), false)
    if not downed and not seated then return false, false, false end
    for _, data in pairs(registry) do
        if (not downed or data.allowDowned) and (not seated or data.allowSeated) then
            return downed, seated, false
        end
    end
    return downed, seated, true
end

-- Renderer selection

local activeRenderer = nil
local activeRendererName = nil

-- A runtime choice, which beats Config until cleared.
local overrideName = nil

-- The last unknown name complained about, so it is reported once.
local complainedAbout = nil

-- Names of the renderers that have signed in.
local function registeredNames()
    local out = {}
    for k in pairs(InteractRenderers) do out[#out + 1] = k end
    table.sort(out)
    return out
end

--- Adopt a renderer: the one asked for, else the one chosen earlier, else Config's. Cheap when nothing
--- changed. The outgoing renderer is cleared before it is detached.
---@param name string|nil
local function useRenderer(name)
    if name then overrideName = name end

    name = name or overrideName or Config.InteractRenderer or 'nui'

    local r = InteractRenderers[name]
    if not r then
        if complainedAbout ~= name then
            complainedAbout = name
            print(('[whip_core:interact] no renderer named "%s" — registered: %s')
                :format(tostring(name), table.concat(registeredNames(), ', ')))
        end
        overrideName = nil                  -- a bad name must not stick and block Config
        if activeRenderer then return end
        name = 'nui'
        r = InteractRenderers.nui
        if not r then return end            -- nothing has loaded yet; try again next tick
    end
    complainedAbout = nil

    if r == activeRenderer then return end

    if activeRenderer then
        if activeRenderer.clear then activeRenderer.clear() end
        if activeRenderer.detach then activeRenderer.detach() end
    end

    activeRenderer = r
    activeRendererName = name
    if activeRenderer.attach then activeRenderer.attach() end
end

--- Swap renderers at runtime (/interactrenderer).
---@param name string
function Interactions.setRenderer(name)
    useRenderer(name)
    return activeRendererName
end

--- Which renderer is currently drawing: 'world' or 'nui'.
---@return string|nil
function Interactions.getRendererName()
    return activeRendererName
end

-- Bound inputs: select and navigate, rebindable key mappings (E to select, wheel to cycle). The `~!`
-- prefix registers an alternate binding for a pad. One route per device per action, never two.

-- When each bound action was last pressed; commands fire on their own thread, so a press is parked here.
local navPressedAt = {}

-- How long a press stays claimable, so a press made with nothing focused does not fire later.
local NAV_MAX_AGE_MS = 200

-- A press this soon after the prompts come back is not theirs: it ended a mode.
local PROMPTS_SETTLE_MS = 150

--- Was a press made at `at` meant for the prompts? Not if they were stood down when it was made.
---@param at number  GetGameTimer when it was pressed
---@return boolean
local function pressIsTheirs(at)
    return promptsBackAt ~= nil and at - promptsBackAt >= PROMPTS_SETTLE_MS
end

--- Claim a pending press if there is a fresh one. Consumes it either way.
---@param name string 'select' | 'up' | 'down'
---@return boolean
function InteractTakeNav(name)
    local at = navPressedAt[name]
    if not at then return false end
    navPressedAt[name] = nil
    return pressIsTheirs(at) and (GetGameTimer() - at) <= NAV_MAX_AGE_MS
end

--- A press from the pad's D-pad (client/pad.lua), parked like a binding's.
---@param name string 'up' | 'down'
function InteractPressNav(name)
    navPressedAt[name] = GetGameTimer()
end

--- Is a prompt up with more than one option to step through? client/pad.lua asks before using D-pad up elsewhere.
---@return boolean
function InteractHasChoices()
    if not currentFocusId or inputState then return false end
    local data = registry[currentFocusId]
    return (data and data._availN or 0) > 1
end

--- Is a prompt in focus? Its A is the pad's accept, so client/pad.lua's A in a vehicle steps aside.
---@return boolean
function InteractHasFocus()
    return currentFocusId ~= nil
end

local function BindNav(name, command, label, kbMapper, kbParam, padParam)
    RegisterCommand(command, function()
        navPressedAt[name] = GetGameTimer()
        if WhipPadDebugFire then WhipPadDebugFire('bind', 'prompt option ' .. name) end

        -- Scrolling opens GTA's weapon wheel, so up and down arm the suppressor.
        if (name == 'up' or name == 'down') and Inventory.suppressWeaponWheel then
            Inventory.suppressWeaponWheel()
        end
    end, false)

    RegisterKeyMapping(command, label, kbMapper, kbParam)

    -- The pad alternate: same command, second default.
    if padParam then
        RegisterKeyMapping('~!' .. command, label .. ' (Controller)', 'PAD_DIGITALBUTTON', padParam)
    end
end

-- A binding and a direct control read of the same key would fire one press twice, so the loop reads
-- no control a binding covers. `select` has no pad binding (A is the menu's confirm): the loop reads
-- control 201. Up and down reach the loop from the D-pad through client/pad.lua (InteractPressNav).

-- The key a prompt shows: the Interact binding's key, or A on a pad.

local keyLabelCache, keyLabelAt = 'E', nil
local KEY_LABEL_MS = 1000   -- how often the binding is asked again

--- The key to show on a prompt: 'A' on a pad, else the Interact binding's key.
---@return string
function Interactions.keyLabel()
    if WhipPadActive then return 'A' end
    return Interactions.keyName()
end

--- The keyboard key the Interact binding is on ('E' by default; 'E' too for a key with no short name).
---@return string
function Interactions.keyName()
    local now = GetGameTimer()
    if keyLabelAt == nil or now - keyLabelAt >= KEY_LABEL_MS then
        keyLabelAt = now
        -- GTA's help text names a key 't_E'.
        local s = GetControlInstructionalButton(0, GetHashKey('+whip_interact') | 0x80000000, true)
        local key = type(s) == 'string' and s:match('^t_(.+)$') or nil
        keyLabelCache = (key and #key <= 6) and key:upper() or 'E'
    end
    return keyLabelCache
end

-- Select is a `+` binding so its release is heard too (a prompt can ask to be held). WhipInteractKey
-- (client/controller.lua) keeps the press and hold for the modes.
local selectHeldKb = false
RegisterCommand('+whip_interact', function()
    navPressedAt.select = GetGameTimer()
    selectHeldKb = true
    WhipInteractKey(true)
    if WhipPadDebugFire then WhipPadDebugFire('bind', 'prompt option select') end
end, false)
RegisterCommand('-whip_interact', function()
    selectHeldKb = false
    WhipInteractKey(false)
end, false)
RegisterKeyMapping('+whip_interact', 'Interact', 'keyboard', 'e')

--- Is the interact key down right now? The binding's, or the pad's accept (control 201; not with LB, which is talk).
---@return boolean
local function selectHeld()
    if selectHeldKb then return true end
    return WhipPadActive and not WhipPadModHeld and IsDisabledControlPressed(0, 201) and true or false
end

--- A prompt being held to use it (holdMs): { id, sel, start, ms }, or nil.
local pressHold = nil
BindNav('up',     'whip_interact_up',   'Interact: Option Up',   'MOUSE_WHEEL', 'IOM_WHEEL_UP',   nil)
BindNav('down',   'whip_interact_down', 'Interact: Option Down', 'MOUSE_WHEEL', 'IOM_WHEEL_DOWN', nil)

--- The focused prompt's control blocks: 'promptScroll' (the wheel, while it picks an option).
--- Changed only when what the prompt wants changes; clearAll lets go.
local promptHeld = {}
local PROMPT_BLOCKS = {
    promptScroll = { controls = { 14, 15, 16, 17 } },
}
local function promptBlock(id, want)
    want = want and true or false
    if (promptHeld[id] or false) == want then return end
    promptHeld[id] = want
    if want then ControlBlocks.hold(id, PROMPT_BLOCKS[id]) else ControlBlocks.release(id) end
end

-- Main interaction thread. Scoring runs about 30 times a second over the grid cells near the player;
-- the renderer's frame() runs every frame.

CreateThread(function()
    -- What is on screen now: [id] = entry, the renderer's whole view of a prompt (it never sees the
    -- registry). Two buffers are swapped: a score frame fills the other while the old one is still
    -- readable for entry reuse and for `removed`. `visible` points at the current one.
    local visibleA, visibleB = {}, {}
    local visible = visibleA
    local frameCounter = 0

    -- Prompts are scored about SCORE_MS apart while one is up, and never more often than every 2nd frame.
    -- A scroll, a typed digit or a press scores on the next pass.
    local SCORE_MS = 30
    local lastScoreAt, lastScoreFrame = nil, 0
    local scoreSoon = false

    -- Cell keys around the player, rebuilt when the player crosses a cell or the range changes.
    local cachedCell = nil
    local cachedRange = nil
    local cachedNearby = {}
    local candidates = {}      -- reused scratch array for the score frame's candidate ids

    -- The two diff lists handed to the renderer, reused. What arrives in `frame` is valid for the call
    -- only: a renderer stashes an id, never the table.
    local stateChanges = {}
    local removedIds   = {}
    -- What the renderer is handed while a hidden prompt is held.
    local heldScratch, heldChanges = {}, {}

    local function rebuildNearby(px, py, range)
        local radius = math.ceil(range / CELL_SIZE)
        local cx = math.floor(px / CELL_SIZE)
        local cy = math.floor(py / CELL_SIZE)
        local keys = {}
        for dx = -radius, radius do
            for dy = -radius, radius do
                keys[#keys + 1] = (cx + dx) .. '_' .. (cy + dy)
            end
        end
        return keys
    end

    --- Ask a following prompt where it is now and keep the answer on its registry record (and grid cell).
    local function applyFollow(data)
        local ok, fx_, fy_, fz_, fh, fpull, fwrap, fcentre, ftilt, ffit = pcall(data.follow)
        if not ok then reportThrow(data.id, 'follow', fx_) end
        if ok and fx_ then
            if gridCellKey(fx_, fy_) ~= data._cell then
                gridRemove(data.id, data)
                data.x, data.y, data.z = fx_, fy_, fz_
                gridInsert(data.id, data)
            else
                data.x, data.y, data.z = fx_, fy_, fz_
            end
            data.heading = fh
            data.pull = tonumber(fpull) or data.pullFixed
            data.wrap = type(fwrap) == 'table' and fwrap or nil
            if fcentre ~= nil then data.centre = fcentre == true else data.centre = data.centreFixed end
            data.tilt = tonumber(ftilt)
            data.fit = type(ffit) == 'table' and ffit or nil
        end
    end

    --- Copy a registry record onto the entry a renderer reads. Every frame for everything visible.
    local function refreshEntry(e, data)
        if data.follow then
            local costFollow = interactOpen and WhipCost.start() or nil
            applyFollow(data)
            WhipCost.stop('prompts, part: following what moves', costFollow)
        end

        e.x, e.y, e.z = data.x, data.y, data.z
        e.heading = data.heading
        e.tilt = data.tilt
        e.pull = data.pull
        e.wrap = data.wrap
        e.centre = data.centre
        e.fit = data.fit
        e.flashAt = data._flashAt
        e.flashR, e.flashG, e.flashB = data._flashR, data._flashG, data._flashB
        e.pressAt = data._pressAt
        -- Progress through a hold to use, 0..1 or nil.
        e.holdP = data._holdP
        e.holdDoneAt = data._holdDoneAt

        e.sel = data._sel
    end

    --- Take everything off screen. Every reason (blocked, nothing registered, nothing in range) goes through here.
    ---@param why string|nil  for a held prompt: 'blocked' (hidden by a screen, downed, seated) or 'lost'
    ---@param keepHold boolean|nil  only a progress bar: a held prompt and its typing stay (blockedOnlyByBar)
    local function clearAll(why, keepHold)
        -- A held prompt cannot outlive this: its holder is told.
        if holdState and not keepHold then endHold(why or 'lost') end

        -- Before the early-out, so no state can skip the cancel.
        if inputState and not (keepHold and holdState and inputState.id == holdState.id) then endInput(true) end
        -- A hold to use does not survive the prompt leaving the screen.
        if pressHold then
            local held = registry[pressHold.id]
            if held then held._holdP = nil end
            pressHold = nil
        end
        -- A key released while a screen had the keys never sends its release.
        selectHeldKb = false
        promptBlock('promptScroll', false)

        if not interactOpen then return end
        if activeRenderer and activeRenderer.clear then activeRenderer.clear() end
        interactOpen = false
        local blurred = currentFocusId
        currentFocusId = nil
        -- Wiped, not replaced: `visible` is one of the two swapped buffers.
        for k in pairs(visible) do visible[k] = nil end

        -- The focused prompt is told it lost focus (onBlur): being blocked is leaving.
        if blurred then
            local prev = registry[blurred]
            if prev and prev.onBlur then
                local ok, err = pcall(prev.onBlur)
                if not ok then
                    print(('[whip_core:interact] ERROR in onBlur for "%s": %s')
                        :format(blurred, tostring(err)))
                end
            end
        end
    end

    --- Use a prompt's selected option: a press of E, or a finished hold.
    ---@param data table  the prompt's registry record
    ---@param opt table|nil  its selected option
    ---@param cb function  the option's callback, else the prompt's
    local function fireSelected(data, opt, cb)
        -- Before the callback: opens the panel this interaction opened last time (client/inventory.lua).
        Inventory.notePanelTrigger(data.id)

        -- Activity log, under the selected option's label. whip_core's ground pickups, containers and
        -- conversations are skipped: their server handlers write richer rows.
        if not (ownerOf(data) == CORE and (data.group == 'ground_items' or data.group == 'containers'
                or data.group == 'conversation')) then
            -- An empty label counts as absent: the server's param validator rejects ''.
            local what = resolveField(data, opt, 'label')
            if what == nil or what == '' then what = data.id end
            if what == nil or what == '' then what = '?' end
            TriggerServerEvent('whip_core:server:interactionUsed', 'interact',
                tostring(what):sub(1, 60))
        end

        -- For a style's `press = 'pop'`.
        data._pressAt = GetGameTimer()

        local ok, err = pcall(cb)
        if not ok then
            print(('[whip_core:interact] ERROR in callback for "%s": %s'):format(tostring(data.id), tostring(err)))
        end
        -- The hand press plays after the option has run.
        if data.press then InteractPress.atPrompt(data) end
    end

    --- One pass of the loop, so each pass runs under pcall.
    local function tick()
        useRenderer()

        -- Blocked: hide everything and sleep. An editor's preview is never blocked.
        local preview = previewState
        local blocked = false
        local downed, seated, skipSoft = false, false, false
        if not preview then
            blocked = IsInteractionBlocked()
            if not blocked then downed, seated, skipSoft = softBlocked() end
        end
        if blocked or skipSoft then
            promptsBackAt = nil
            clearAll('blocked', blocked and holdState ~= nil and blockedOnlyByBar())
            Wait(500)
            goto continue
        end
        local now = GetGameTimer()

        -- A preview's E is the editor's, so to the keys the prompts are standing down.
        if preview then
            promptsBackAt = nil
        elseif not promptsBackAt then
            promptsBackAt = now
        end

        -- Nothing registered: sleep
        if not next(registry) then
            clearAll()
            Wait(500)
            goto continue
        end

        local cost = WhipCost.start()   -- /whipcost (lib/cost.lua); a pass that returns early is simply not counted

        frameCounter = frameCounter + 1
        -- The pass number, for what vehicle_prompts.lua reads once a pass.
        Interactions.pass = frameCounter
        -- Score about every SCORE_MS while a prompt is up; with none showing, every idle wake scores.
        local isScoreFrame = (not interactOpen) or scoreSoon
            or (frameCounter - lastScoreFrame >= 2 and (lastScoreAt == nil or now - lastScoreAt >= SCORE_MS))
        if isScoreFrame then lastScoreAt, lastScoreFrame, scoreSoon = now, frameCounter, false end

        -- What scoring reads, only on score frames. camPos and the forward go on to the renderer.
        local px, py, pz, onlyGroup, cfx, cfy, cfz, visibleRange, activeRange, camPos
        if isScoreFrame then
            local playerCoords = GetEntityCoords(PlayerPedId())
            px, py, pz = playerCoords.x, playerCoords.y, playerCoords.z
            -- A preview is seen from the editor's camera.
            if preview and preview.from then
                local ok, x, y, z = pcall(preview.from)
                if ok and tonumber(x) and tonumber(y) and tonumber(z) then px, py, pz = x, y, z end
            end
            -- The group on screen alone: a preview's, else a solo's (both filter below).
            onlyGroup = preview and preview.group or soloGroup
            cfx, cfy, cfz = InteractGetCameraForward()
            -- Matches clampVisibleRange's fallback: the grid search radius and the scorer's range must agree.
            visibleRange = Config.InteractVisibleRange or 5.0
            activeRange  = Config.InteractActiveRange or 3.0
        end

        -- Diffs for the renderer: only a score frame produces them, otherwise nil (nothing structural changed).
        local changed, removed = nil, nil

        -- /whipcost: the scoring part, which includes the conditions and following it calls.
        local costScore = isScoreFrame and interactOpen and WhipCost.start() or nil
        if isScoreFrame then
            -- Score frame: full scoring and state diffing.
            -- The buffer that is not current becomes the new set, wiped here so the old set stays readable.
            local newVisible = (visible == visibleA) and visibleB or visibleA
            for k in pairs(newVisible) do newVisible[k] = nil end

            -- Items whose state is new or changed, cleared as an array.
            for i = #stateChanges, 1, -1 do stateChanges[i] = nil end

            -- Focus: range decides what is reachable, then focusMode picks among them.
            -- 'aim' (default): a cone out of the screen, what you look at wins. 'near': closest wins, wider cone.
            -- Both score into the same 0..1 space; the mode only weights the aim and distance terms.
            camPos = GetFinalRenderedCamCoord()

            local coneAim  = math.cos(math.rad(Config.InteractFocusCone or 40.0))
            local coneNear = math.cos(math.rad(Config.InteractFocusConeNear or 100.0))
            local nearW    = Config.InteractFocusNearWeight or 0.85

            -- A sign seen from behind counts as not there, under the world renderer only.
            local cullSigns = Interactions.getRendererName() == 'world'
                and (Config.Interact3D or {}).cullBehind ~= false

            local bestScore = -1.0
            local bestId = nil

            -- Candidates come from the grid cells around the player.
            local myCell = gridCellKey(px, py)
            if myCell ~= cachedCell or visibleRange ~= cachedRange then
                cachedCell = myCell
                cachedRange = visibleRange
                cachedNearby = rebuildNearby(px, py, visibleRange)
            end

            -- Gathered into a scratch list first, so a condition removing points mid-loop is safe.
            local candCount = 0
            for c = 1, #cachedNearby do
                local bucket = grid[cachedNearby[c]]
                if bucket then
                    for id in pairs(bucket) do
                        candCount = candCount + 1
                        candidates[candCount] = id
                    end
                end
            end

            for ci = 1, candCount do
              local id = candidates[ci]
              local data = registry[id]
              -- Solo and hold filter here; the next diff takes the rest off screen.
              local held = holdState ~= nil and id == holdState.id
              if data and (onlyGroup == nil or data.group == onlyGroup) and (holdState == nil or held)
                  and (not downed or data.allowDowned) and (not seated or data.allowSeated) then
                -- This point's own ranges, else the global pair.
                local vRange = data.visibleRange or visibleRange
                local aRange = data.activeRange or activeRange

                local score, dist
                if held then
                    -- Held: in range is enough, however the camera turns.
                    local hx, hy, hz = data.x - px, data.y - py, data.z - pz
                    dist = sqrt(hx * hx + hy * hy + hz * hz)
                    score = (dist <= vRange) and 1.0 or -1
                else
                  -- Most prompts in the nearby cells are far out of range: skip them cheaply.
                  local ox, oy, oz = data.x - px, data.y - py, data.z - pz
                  local reach = vRange + REFOLLOW_SLACK
                  if ox * ox + oy * oy + oz * oz > reach * reach then
                    score = -1
                  else
                    score, dist = InteractComputeScore(px, py, pz, cfx, cfy, cfz, data.x, data.y, data.z, vRange)

                    -- `follow` runs only for what is on screen, so a prompt about to be turned away is
                    -- asked where it is now first, at most every REFOLLOW_MS.
                    if data.follow and not visible[id] and dist <= vRange + REFOLLOW_SLACK
                        and (score < 0 or (cullSigns and seenFromBehind(data, camPos))) then
                        if now >= (data._refollowAt or 0) then
                            data._refollowAt = now + REFOLLOW_MS
                            applyFollow(data)
                            score, dist = InteractComputeScore(px, py, pz, cfx, cfy, cfz, data.x, data.y, data.z, vRange)
                        end
                    end
                  end
                end

                -- A sign seen from behind is not there, so it must not win focus.
                if score >= 0 and cullSigns and seenFromBehind(data, camPos) then
                    score = -1
                end

                if score >= 0 then
                    local costCond = interactOpen and WhipCost.start() or nil
                    local conditionOk = true
                    if data.condition then
                        local ok, result = pcall(data.condition)
                        -- A throwing condition fails closed, and is reported.
                        if not ok then reportThrow(data.id, 'condition', result) end
                        if ok then conditionOk = result else conditionOk = false end
                    end

                    -- A prompt with no offerable option draws nothing.
                    if conditionOk and refreshOptions(data) == 0 then
                        conditionOk = false
                    end
                    -- Counted under the prompt's owner.
                    if costCond then WhipCost.stop(conditionCostName(data._owner), costCond) end

                    if conditionOk then
                        -- A prompt you cannot see is not shown, under either renderer. One being typed into
                        -- stays (the player may look round while typing; it is the typing that is drawn).
                        local onScreen = held or (inputState ~= nil and inputState.id == id)
                            or World3dToScreen2d(data.x, data.y, data.z)
                        if onScreen then
                            local isActive = dist <= aRange

                            -- Track the best for focus.
                            if isActive then
                                local ax = data.x - camPos.x
                                local ay = data.y - camPos.y
                                local az = data.z - camPos.z
                                local alen = sqrt(ax * ax + ay * ay + az * az)
                                if alen > 0.001 then
                                    local aim = (cfx * ax + cfy * ay + cfz * az) / alen

                                    local isNear = (data.focusMode == 'near')
                                    local cone   = isNear and coneNear or coneAim
                                    local w      = isNear and nearW or 0.0

                                    if aim >= cone then
                                        -- 1 at dead centre, 0 at this registration's cone edge.
                                        local aimTerm = (cone < 1.0)
                                            and ((aim - cone) / (1.0 - cone)) or 1.0
                                        -- 1 at your feet, 0 at this point's own range edge.
                                        local nearTerm = 1.0 - (dist / aRange)
                                        if nearTerm < 0.0 then nearTerm = 0.0 end

                                        local s = (1.0 - w) * aimTerm + w * nearTerm
                                        if s > bestScore then
                                            bestScore = s
                                            bestId = id
                                        end
                                    end
                                end
                            end

                            -- The entry is reused when the prompt was already visible, so a renderer can
                            -- keep its own bookkeeping on it.
                            local e = visible[id]
                            if not e then
                                e = { id = id }
                            end

                            local wasActive = e.active
                            refreshEntry(e, data)

                            -- The selected option's icon and label, not the prompt's own.
                            local sel = selectedOption(data)
                            -- labelFor, not resolveField: a status talks over the option's label.
                            e.label   = labelFor(data, sel)
                            e.icon    = resolveField(data, sel, 'icon')
                            -- Optional picture, drawn above the label by the world renderer.
                            e.image   = resolveField(data, sel, 'image')

                            e.active  = isActive
                            e.dist    = dist
                            e.focused = false          -- set below, after the best is known

                            -- The option stack is shared with the registry record, not copied.
                            e.avail   = data._avail
                            e.availN  = data._availN
                            e.sel     = data._sel

                            -- Badge size is judged at the point's own range (sizeRange, not aRange, which setRange can widen).
                            e.sizeRange = data.sizeRange or aRange
                            e.scale     = data.scale

                            -- Resolved style: its own, else its group's, else 'default'.
                            e.style     = InteractStyle.of(data.style, data.group)

                            newVisible[id] = e

                            -- Changed or new, diffed against the resolved label and icon and the selection.
                            if wasActive == nil
                                or wasActive ~= isActive
                                or e._sentLabel ~= e.label
                                or e._sentIcon ~= e.icon
                                or e._sentSel ~= e.sel then
                                e._sentLabel = e.label
                                e._sentIcon  = e.icon
                                e._sentSel   = e.sel
                                stateChanges[#stateChanges + 1] = {
                                    id     = id,
                                    label  = e.label,
                                    icon   = e.icon,
                                    active = isActive,
                                    dist   = dist,
                                    entry  = e,
                                }
                            end
                        end
                    end
                end
              end
            end

            -- A prompt being typed into keeps focus, so camera drift does not lose the digits. Pinned before
            -- the focus-change block fires onBlur. Falling out of newVisible cancels the input.
            if inputState then
                if newVisible[inputState.id] then
                    bestId = inputState.id
                else
                    endInput(true)
                end
            end

            -- A held prompt keeps focus the same way; out of newVisible, the holder hears why.
            if holdState then
                if newVisible[holdState.id] then
                    bestId = holdState.id
                else
                    endHold('lost')
                end
            end

            -- Mark focused item
            if bestId and newVisible[bestId] then
                newVisible[bestId].focused = true
            end

            -- The option stack, for the focused prompt only (others draw a plain ring).
            if bestId then
                local fe = newVisible[bestId]
                local fd = registry[bestId]
                if fe and fd then
                    -- Selection restarts at the top on focus gain only.
                    if bestId ~= currentFocusId then
                        fd._sel = 1
                        fe.sel = 1
                        -- labelFor, so a status message survives a focus change.
                        fe.label = labelFor(fd, selectedOption(fd))
                        fe.icon  = resolveField(fd, selectedOption(fd), 'icon')
                    end

                    local icons = fe.optIcons
                    if not icons then icons = {}; fe.optIcons = icons end

                    -- Every option's text, so scrolling is an instant row change in the world renderer.
                    local labels = fe.optLabels
                    if not labels then labels = {}; fe.optLabels = labels end

                    local avail, n = fd._avail, fd._availN or 0
                    for k = 1, n do
                        local opt = fd.options[avail[k]]
                        icons[k] = resolveField(fd, opt, 'icon') or 'E'
                        -- resolveField, not labelFor: a status covers the selected option only.
                        labels[k] = resolveField(fd, opt, 'label') or ''
                    end
                    for k = n + 1, #icons do icons[k] = nil end
                    for k = n + 1, #labels do labels[k] = nil end
                end
            end

            if bestId ~= currentFocusId then
                -- The outgoing prompt is told it lost focus, before anything below touches the entries.
                if currentFocusId then
                    local prev = registry[currentFocusId]
                    if prev and prev.onBlur then
                        local ok, err = pcall(prev.onBlur)
                        if not ok then
                            print(('[whip_core:interact] ERROR in onBlur for "%s": %s')
                                :format(currentFocusId, tostring(err)))
                        end
                    end
                end

                if bestId and newVisible[bestId] then
                    local found = false
                    for i = 1, #stateChanges do
                        if stateChanges[i].id == bestId then
                            stateChanges[i].focused = true
                            found = true
                            break
                        end
                    end
                    if not found then
                        stateChanges[#stateChanges + 1] = {
                            id      = bestId,
                            focused = true,
                            entry   = newVisible[bestId],
                        }
                    end
                end
                -- Unfocus the previous one, unless it vanished (then it is in `removed`).
                if currentFocusId and newVisible[currentFocusId] then
                    newVisible[currentFocusId].focused = false
                    local found = false
                    for i = 1, #stateChanges do
                        if stateChanges[i].id == currentFocusId then
                            stateChanges[i].focused = false
                            found = true
                            break
                        end
                    end
                    if not found then
                        stateChanges[#stateChanges + 1] = {
                            id      = currentFocusId,
                            focused = false,
                            entry   = newVisible[currentFocusId],
                        }
                    end
                end
            end

            currentFocusId = bestId

            -- Items that disappeared, cleared as an array like stateChanges.
            for i = #removedIds, 1, -1 do removedIds[i] = nil end
            for id in pairs(visible) do
                if not newVisible[id] then
                    removedIds[#removedIds + 1] = id
                end
            end
            removed = removedIds

            -- Swap after `removed` is computed against the old set.
            visible = newVisible
            changed = stateChanges
            WhipCost.stop('prompts, part: scoring (about 30 a second)', costScore)

        else
            -- Non-score frame: refresh positions so a moving point is drawn where it is now.
            for id, e in pairs(visible) do
                local data = registry[id]
                if data then
                    refreshEntry(e, data)
                end
            end
        end

        -- Hand to the renderer, every frame. The fourth argument says whether this is a score frame.
        if next(visible) then
            interactOpen = true
            if activeRenderer and activeRenderer.frame then
                local drawn, drawnChanged = visible, changed
                -- Not drawn: a hidden hold's prompt (its holder draws it) and the one being typed into (the
                -- typing stands in its place). The renderer gets everything else.
                local skipA = (holdState and holdState.hidden and visible[holdState.id]) and holdState.id or nil
                local skipB = (inputState and visible[inputState.id]) and inputState.id or nil
                if skipA or skipB then
                    drawn = heldScratch
                    for k in pairs(drawn) do drawn[k] = nil end
                    for k, e in pairs(visible) do
                        if k ~= skipA and k ~= skipB then drawn[k] = e end
                    end
                    if changed then
                        drawnChanged = heldChanges
                        for i = #drawnChanged, 1, -1 do drawnChanged[i] = nil end
                        for i = 1, #changed do
                            local cid = changed[i].id
                            if cid ~= skipA and cid ~= skipB then drawnChanged[#drawnChanged + 1] = changed[i] end
                        end
                    end
                end
                local costDraw = WhipCost.start()
                -- The camera is nil on non-score frames: the renderer reads its own.
                activeRenderer.frame(drawn, drawnChanged, removed, isScoreFrame, camPos, cfx, cfy, cfz, now)
                WhipCost.stop('prompts, part: the 3D renderer (every frame)', costDraw)
            end
        else
            clearAll()
        end
        local costKeys = interactOpen and WhipCost.start() or nil

        -- Typing has the keys (client/prompt_typing.lua): the prompts' own presses meanwhile are dropped, so a key
        -- typed into the capsule (E, a scroll) never lands on a prompt after.
        if inputState then
            InteractTakeNav('select')
            InteractTakeNav('up')
            InteractTakeNav('down')
        end

        -- Scroll: pick an option, only when the focused prompt has more than one. The wheel controls
        -- (14-17) are held off meanwhile so scrolling does not cycle weapons. Not while typing or in a preview.
        local scrolling = false
        if currentFocusId and not inputState and not preview then
            local data = registry[currentFocusId]
            local n = data and data._availN or 0
            if n > 1 then
                scrolling = true

                -- Clamped, not wrapped. The binding only: reading control 16 too would step twice per notch.
                if InteractTakeNav('down') then
                    if data._sel < n then data._sel = data._sel + 1; scoreSoon = true end
                    if WhipPadDebugFire then
                        WhipPadDebugFire('interact', 'option down', ('%d/%d'):format(data._sel, n))
                    end
                elseif InteractTakeNav('up') then
                    if data._sel > 1 then data._sel = data._sel - 1; scoreSoon = true end
                    if WhipPadDebugFire then
                        WhipPadDebugFire('interact', 'option up', ('%d/%d'):format(data._sel, n))
                    end
                end
            end
        end
        promptBlock('promptScroll', scrolling)

        -- The bound key, or the pad's accept (control 201, read without a binding and gated on the pad:
        -- on a keyboard 201 is Enter). Not while LB is held (LB + A is talk), nor in a preview, nor while typing
        -- (the typing gives its value itself: Enter or Done, Interactions.submitInput).
        if currentFocusId and not preview and not inputState and (InteractTakeNav('select')
            or (WhipPadActive and not WhipPadModHeld and IsDisabledControlJustPressed(0, 201)
                and pressIsTheirs(now))) then
            if WhipPadDebugFire then WhipPadDebugFire('interact', 'select', currentFocusId) end
            -- Whatever the press changes shows on the next pass.
            scoreSoon = true
            local data = registry[currentFocusId]

            -- The selected option's callback, else the prompt's own.
            local opt = data and selectedOption(data)
            local cb = (opt and opt.callback) or (data and data.callback)

            if data and cb then
                -- An option that asks to be held starts the hold here; the block below runs it.
                local holdMs = (opt and opt.holdMs) or data.holdMs
                if holdMs and holdMs > 0 then
                    pressHold = { id = currentFocusId, sel = data._sel, start = now, ms = holdMs }
                    data._holdP = 0.0
                else
                    fireSelected(data, opt, cb)
                end
            end
        end

        -- Hold to use: runs while the same option of the same prompt stays focused and the key stays
        -- down; anything else cancels it. `_holdP` (0..1) is what the renderer draws the ring from.
        if pressHold then
            local held = registry[pressHold.id]
            if not held or currentFocusId ~= pressHold.id or held._sel ~= pressHold.sel or preview
                or not selectHeld() then
                if held then held._holdP = nil end
                pressHold = nil
            else
                local p = (now - pressHold.start) / pressHold.ms
                if p < 1.0 then
                    held._holdP = p
                else
                    held._holdP = nil
                    held._holdDoneAt = now
                    scoreSoon = true
                    pressHold = nil
                    local opt = selectedOption(held)
                    local cb = (opt and opt.callback) or held.callback
                    if cb then fireSelected(held, opt, cb) end
                end
            end
        end

        WhipCost.stop('prompts, part: keys, scroll and hold', costKeys)
        WhipCost.stop(interactOpen and 'prompts: a pass with a prompt up (every frame)'
            or 'prompts: an idle pass (5 a second)', cost)

        Interactions.pass = nil

        if interactOpen then
            Wait(0)  -- Every frame when visible
        else
            Wait(200)  -- Idle poll
        end

        ::continue::
    end

    -- Each pass runs under pcall so one bad value from a satellite cannot end the loop. The first few failures are reported.
    local failures = 0
    while true do
        local ok, err = pcall(tick)
        if not ok then
            Interactions.pass = nil
            failures = failures + 1
            if failures <= 3 then
                print(('[whip_core:interact] ERROR in the interaction loop (it keeps running): %s'):format(tostring(err)))
            end
            Wait(500)
        end
    end
end)

-- Cleanup

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then
        -- First, so the caller's onCancel still runs.
        if inputState then endInput(true) end

        registry = {}
        grid = {}
        interactOpen = false
        currentFocusId = nil
        -- Clear, then detach (detach releases the world renderer's browsers).
        if activeRenderer then
            if activeRenderer.clear then activeRenderer.clear() end
            if activeRenderer.detach then activeRenderer.detach() end
        end
        return
    end

    -- Another resource stopped: remove its prompts.
    local removed = Interactions.removeByOwner(res)
    if removed > 0 and currentFocusId and registry[currentFocusId] == nil then
        -- Stops E firing into a dead callback until the next score frame.
        currentFocusId = nil
    end
end)
