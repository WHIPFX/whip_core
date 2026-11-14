-- The pad in the world: whip's buttons, each player's layout, and the stick jog and sprint.
-- What a button does is a layout (Config.Controller.Layout is the default; each player can change theirs
-- on the pause menu's Controller screen, kept in a KVP). Other resources add actions with
-- RegisterPadAction. GTA's own buttons stay GTA's: only whip's actions move, between whip's buttons (SLOTS).
-- The buttons are read as frontend controls every frame while a pad is the device (ControlBlocks
-- 'padRead'), since FiveM key bindings never fired from a pad. Each press also asks WhipLastInputIsPad,
-- as the frontend controls are arrow keys on a keyboard. Actions wait for IsGameInputFree unless they
-- work in menus. While LB is held, a prompt's A, a bar's cancel and a panel's select and X step aside.

--- LB is down as the combo key.
WhipPadModHeld = false

--- A button of the LB layer went down during this LB hold; kept until LB's next press.
WhipPadComboUsed = false

local function log(source, label, what)
    if WhipPadDebugFire then WhipPadDebugFire(source, label, what) end
end

-- Per-player settings (pause menu, Server Settings); the server's Config.Controller figures are the defaults.
PlayerPrefs.define({
    key = 'pad.sprintOnA', group = 'Controller', type = 'toggle', label = 'A sprints too',
    help = 'Hold A to sprint, as GTA does, as well as clicking the left stick twice.',
    default = function() return Config.Controller ~= nil and Config.Controller.SprintOnA == true end,
})
PlayerPrefs.define({
    key = 'pad.doubleClickMs', group = 'Controller', type = 'slider', label = 'Double click to sprint',
    help = 'How quickly the second click of the left stick has to follow the first to sprint.',
    min = 100, max = 1000, step = 25, unit = 'ms',
    default = function() return (Config.Controller and tonumber(Config.Controller.SprintDoubleClickMs)) or 300 end,
})

PlayerPrefs.define({
    key = 'pad.vehicleControls', group = 'Controller', type = 'toggle', label = 'Show a vehicle\'s controls',
    help = 'Taking the driver\'s seat shows that vehicle\'s buttons beside the dial for a few seconds: the engine and what it is fitted with, like nitrous. On a keyboard, the engine\'s key.',
    default = function() return not (Config.Controller ~= nil and Config.Controller.VehicleControls == false) end,
})
-- Each player's own only: no server default
PlayerPrefs.define({
    key = 'pad.vehicleControlsKeys', group = 'Controller', type = 'toggle', label = 'Vehicle controls in white keys',
    help = 'Each button beside the dial sits in a white key, like the prompts you walk up to. Off: just the button pictures.',
    default = false,
})

local function sprintOnA()
    return PlayerPrefs.get('pad.sprintOnA') == true
end

-- whip's buttons, and the actions that go on them

--- Each is a frontend control (one physical button whatever GTA's layout). `lb`: read while LB is held.
--- `block`: GTA controls held off while LB is held and something is on it. `dir`: a prompt's options
--- step on it. `car`: read only in a vehicle, and a prompt in view takes it first. `foot`: read only
--- on foot. A `car` or `foot` button is GTA's own, taken only while what is on it is ready
--- (SetPadActionReady); `gta` lists the controls held off then. Listed in the controller screen's
--- order; the first button keeps an action a layout names twice.
local SLOTS = {
    { id = 'dpad_up',       control = 188, name = 'D-Up',       dpad = true, dir = 'up' },
    { id = 'dpad_down',     control = 187, name = 'D-Down',     dpad = true, dir = 'down' },
    { id = 'dpad_left',     control = 189, name = 'D-Left',     dpad = true },
    { id = 'dpad_right',    control = 190, name = 'D-Right',    dpad = true },
    { id = 'l3',            control = 209, name = 'L3' },
    { id = 'veh_a',         control = 201, name = 'A (in a vehicle)', car = true, gta = { 73 } },        -- a bike's duck
    { id = 'foot_b',        control = 202, name = 'B (on foot)',      foot = true, gta = { 45, 140, 263 } },  -- reload, the light punch
    { id = 'lb_a',          control = 201, name = 'LB+A',       lb = true, block = { 73, 141 } },       -- duck in a car, the heavy punch
    { id = 'lb_b',          control = 202, name = 'LB+B',       lb = true, block = { 45, 140, 263 } },  -- reload, the light punch
    { id = 'lb_x',          control = 203, name = 'LB+X',       lb = true, block = { 22, 99 } },        -- jump, a car's next weapon
    { id = 'lb_y',          control = 204, name = 'LB+Y',       lb = true, block = { 23, 75 } },        -- get in, get out
    { id = 'lb_dpad_up',    control = 188, name = 'LB+D-Up',    lb = true },
    { id = 'lb_dpad_down',  control = 187, name = 'LB+D-Down',  lb = true },
    { id = 'lb_dpad_left',  control = 189, name = 'LB+D-Left',  lb = true },
    { id = 'lb_dpad_right', control = 190, name = 'LB+D-Right', lb = true },
}

local SLOT = {}         -- [id] = slot
local LB_SLOT_OF = {}   -- [control] = the LB slot on that button
local PLAIN = {}        -- the slots read without LB
for _, s in ipairs(SLOTS) do
    SLOT[s.id] = s
    if s.lb then LB_SLOT_OF[s.control] = s.id else PLAIN[#PLAIN + 1] = s end
end

--- What a button can do: whip's own here, another resource's in `registered`.
---   command     the key command it presses; a '+' one is let go with its button
---   onPress     ...or a function, run on the press; onRelease (optional) on the release
---   run         whip's own, for the stick
---   hold        the command times its own hold (the radial); it still starts on D-pad up or down when a prompt has choices
---   menus       it works with a screen or menu open too (talk, the radio); anything else waits for IsGameInputFree
---   move        it moves the player (jog / sprint); it also works in the editors walked round in (moveFree)
---   where       'car' or 'foot': where it does anything, for the screen's views
---   slot        a resource's: the button it goes on while that has nothing on it
local ACTIONS = {
    engine    = { label = 'Engine on/off', command = '+whip_ignition_toggle', where = 'car' },
    inventory = { label = 'Inventory',     command = 'whip_inventory_pad' },
    radial    = { label = 'Radial menu',   command = '+whip_radial_pad', hold = true },
    sprint    = { label = 'Jog / sprint',  where = 'foot', move = true },
}
local ACTION_ORDER = { 'engine', 'inventory', 'radial', 'sprint' }

--- [id] = an action another resource put on whip's buttons, with its `owner`.
local registered = {}

---@return table|nil
local function actionOf(id)
    return ACTIONS[id] or registered[id]
end

--- Can it go on a button: whip's own always, another resource's while it is registered (its resource runs).
local function available(id)
    return actionOf(id) ~= nil
end

--- Is a command of that name registered by anything? Asked per press, never per frame.
local function commandExists(name)
    for _, c in ipairs(GetRegisteredCommands() or {}) do
        if c.name == name then return true end
    end
    return false
end

-- The layout: whip's default, or the player's own

local KVP_KEY = 'whip_pad_layout'
local KVP_VERSION = 1

--- The player's own, as saved: { [slot id] = action id | false }, or nil for whip's default. It keeps an
--- action whose resource is not running; a button with no entry is left to a resource that asks for it.
local mine = nil

--- In force: [slot id] = action id. Each action on one button at most.
local layout = {}

--- [slot id] = what its press is holding down: a '-' command, or { fn = onRelease } for a function.
local running = {}

local reading = false   -- the read is held: a pad is the device (PadDeviceChanged)
local holdReader        -- the read's block, held again for a new layout (assigned below)

--- `t` made sound: known buttons, actions that are on here, each once (the first button keeps it).
local function clean(t)
    local out, used = {}, {}
    if type(t) ~= 'table' then return out end
    for _, s in ipairs(SLOTS) do
        local a = t[s.id]
        if type(a) == 'string' and available(a) and not used[a] then
            out[s.id] = a
            used[a] = true
        end
    end
    return out
end

--- Each registered action no button holds goes on the one it asks for, if that is empty and `free(slot)`
--- allows it. In id order, so two asking for one button settle the same way.
local function suggest(t, free)
    local placed, ids = {}, {}
    for _, a in pairs(t) do placed[a] = true end
    for id in pairs(registered) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local s = registered[id].slot
        if s and not placed[id] and t[s] == nil and free(s) then
            t[s] = id
            placed[id] = true
        end
    end
    return t
end

--- whip's default: Config.Controller.Layout, then a resource's action on the button it asks for if empty.
local function defaults()
    return suggest(clean(Config.Controller and Config.Controller.Layout), function() return true end)
end

--- Every slot of `t`, an action or false.
local function full(t)
    local out = {}
    for _, s in ipairs(SLOTS) do out[s.id] = t[s.id] or false end
    return out
end

local function letGo(slotId)
    local r = running[slotId]
    running[slotId] = nil
    if type(r) == 'table' then
        -- Another resource's function may have stopped since, so a failure is only said.
        local ok, err = pcall(r.fn)
        if not ok then print(('[whip_core:pad] %s: the release failed: %s'):format(slotId, tostring(err))) end
    elseif r and commandExists(r) then
        ExecuteCommand(r)   -- its resource may have stopped since
    end
end

local function stopAll()
    for slotId in pairs(running) do letGo(slotId) end
end

--- The layout in force, again. A button held through the change lets go of what it pressed. The
--- player's own takes a resource's action only on a button it has no entry for.
local function resolve()
    stopAll()
    if mine then
        layout = suggest(clean(mine), function(s) return mine[s] == nil end)
    else
        layout = defaults()
    end
    if reading and holdReader then holdReader() end
end

local function loadMine()
    local raw = GetResourceKvpString(KVP_KEY)
    if type(raw) ~= 'string' or raw == '' then return nil end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= 'table' or type(data.layout) ~= 'table' then return nil end
    -- Any action name is kept: a resource registers after this file loads.
    local t = {}
    for _, s in ipairs(SLOTS) do
        local a = data.layout[s.id]
        if type(a) == 'string' and a:match('^[%a][%w_]*$') then t[s.id] = a
        elseif a ~= nil then t[s.id] = false end
    end
    return t
end

local function saveMine()
    if mine then
        SetResourceKvp(KVP_KEY, json.encode({ v = KVP_VERSION, layout = mine }))
    else
        DeleteResourceKvp(KVP_KEY)
    end
end

--- Put an action (false: nothing) on a button. The action leaves its old button, which takes this
--- button's old one (a swap). A layout equal to whip's default is not kept, so it follows the server's.
---@param slotId string
---@param actionId string|false
---@return boolean ok, table|string|nil  { slot, gave } of the swap, or why not
local function setSlot(slotId, actionId)
    if type(slotId) ~= 'string' or not SLOT[slotId] then return false, 'no such button' end
    if actionId ~= false and not available(actionId) then return false, 'no such action' end
    -- The layout in force, plus what it leaves out of the saved one (cleared buttons, actions not running).
    local t = {}
    for _, s in ipairs(SLOTS) do
        local a = layout[s.id]
        if a == nil and mine then a = mine[s.id] end
        t[s.id] = a
    end
    local old = t[slotId]
    local swap = nil
    if actionId then
        for _, s in ipairs(SLOTS) do
            if s.id ~= slotId and t[s.id] == actionId then
                t[s.id] = old or false   -- moved off on purpose: no resource refills it
                swap = { slot = s.id, gave = old or false }
            end
        end
    end
    t[slotId] = actionId
    local got, def = full(suggest(clean(t), function(s) return t[s] == nil end)), full(defaults())
    local same = true
    for _, s in ipairs(SLOTS) do
        if got[s.id] ~= def[s.id] then same = false break end
    end
    mine = (not same) and t or nil
    saveMine()
    resolve()
    return true, swap
end

local function resetLayout()
    mine = nil
    saveMine()
    resolve()
end

--- Press what a button holds. Answers what it did, for /paddebug.
local function press(slotId)
    local id = layout[slotId]
    local a = id and actionOf(id)
    if not a then return 'nothing on it' end
    if a.ready == false then return a.label .. ': not ready (the button is GTA\'s)' end
    if a.run then return a.run() end
    -- Not under a screen or a mode, unless it works in menus.
    if not a.menus and not IsGameInputFree() then return 'ignored: a screen or mode has the keys' end
    if a.onPress ~= nil then
        local ok, err = pcall(a.onPress)
        if not ok then return a.label .. ': failed: ' .. tostring(err) end
        if a.onRelease ~= nil then running[slotId] = { fn = a.onRelease } end
        return a.label
    end
    local cmd = a.command
    if not commandExists(cmd) then return cmd .. ': no such command' end
    ExecuteCommand(cmd)
    -- Only a '+' command has a release half to run.
    if cmd:sub(1, 1) == '+' then running[slotId] = '-' .. cmd:sub(2) end
    return cmd
end

-- LB, the combo key

local held = false
local down = {}   -- [lb slot id] = its button is down, during this LB hold

--- Held off while LB is down: GTA's actions on the buttons LB + something uses, and 21 (sprint) only
--- where A still sprints (SprintOnA) and LB + A holds something, else it would stop the stick sprint.
local function modBlock()
    local list = {}
    if sprintOnA() and layout.lb_a then list[1] = 21 end
    for _, s in ipairs(SLOTS) do
        if s.block and layout[s.id] and actionOf(layout[s.id]).ready ~= false then
            for _, c in ipairs(s.block) do list[#list + 1] = c end
        end
    end
    return { controls = list }
end

--- One frame while LB is held: the LB layer's buttons going down and up.
local function modFrame()
    -- Not once LB is up: ControlBlocks may run this once more that frame, and a press then would never be released.
    if not held then return end
    for _, s in ipairs(SLOTS) do
        if s.lb then
            local isDown = IsDisabledControlPressed(0, s.control)
            if isDown ~= down[s.id] then
                down[s.id] = isDown
                if isDown then
                    WhipPadComboUsed = true
                    local id = layout[s.id]
                    -- In a menu, only what works in menus.
                    if id and (not WhipNavScopeOpen or actionOf(id).menus) then log('combo', s.name, press(s.id)) end
                else
                    letGo(s.id)
                end
            end
        end
    end
end

--- LB down or up, from the read below or the panel driver (controller.lua); saying it twice does nothing.
---@param isDown boolean
---@param from string  who said so, for /paddebug
function PadModSync(isDown, from)
    if isDown == held then return end
    held = isDown
    log('combo', 'LB ' .. (isDown and 'down' or 'up'), from)
    WhipPadModHeld = isDown
    if isDown then
        WhipPadComboUsed = false
        -- A button already down when LB went down does not count.
        for _, s in ipairs(SLOTS) do
            if s.lb then down[s.id] = IsDisabledControlPressed(0, s.control) end
        end
        ControlBlocks.hold('padMod', modBlock(), modFrame)
    else
        ControlBlocks.release('padMod')
        for _, s in ipairs(SLOTS) do
            if s.lb then
                down[s.id] = false
                letGo(s.id)
            end
        end
    end
end

--- While LB is held: is this button LB + something that works in menus (talk)? Then the panel driver leaves its press to the combo.
---@param control number  a frontend control
---@return boolean
function PadComboTakes(control)
    if not held then return false end
    local id = LB_SLOT_OF[control]
    local a = id and layout[id]
    return a ~= nil and actionOf(a).menus == true
end

-- For a satellite's pad reader (Whip.padScreen): the rule the panel driver keeps (controller.lua DriveFrame).
-- While LB is held, A, X and buttons whose LB slot works in menus are whip's combo, not the screen's; the
-- screen's own LB press goes on LB's release, only if no combo was used.

--- Does LB + this button belong to whip's combo rather than to the screen? false when LB is not held.
---@param control number|nil  a frontend control (201 A, 202 B, 203 X, 204 Y, 206 RB, the D-pad 187-190)
---@return boolean
exports('PadComboTakes', function(control)
    control = tonumber(control)
    if not held or not control then return false end
    if control == 201 or control == 203 then return true end
    return PadComboTakes(control)
end)

--- Was a combo used during the current LB hold (or the last)? True means the screen's own LB press is not sent.
---@return boolean
exports('PadComboUsed', function()
    return WhipPadComboUsed == true
end)

-- The stick: one click jogs, two sprint, each until the stick goes back to the middle (the 'sprint'
-- action, on L3 by default). The first click jogs at once; one click while sprinting drops to the jog.
-- The read holds off 36 (duck), so there is no sneak on a pad.
-- Jog = a move blend of at least 2 (1 walks, 2 jogs, 3 sprints). Sprint = at least 3 with sprint (21)
-- held as well. GTA forgets both after a frame, so the read sets them every frame while one is on.
-- stickClick times the double click itself (SprintDoubleClickMs).

--- Below this far from the centre the stick is "in the middle".
local STICK_MIDDLE = 0.25

local run = nil            -- nil, 'jog' or 'sprint'
local lastClick = -100000

local padFrame   -- the read, below; the run switches its block

--- The read's block: 36 (sneak), 21 (A's sprint, not with SprintOnA), 80 (B's cinematic camera in a car),
--- and GTA's own action on a `car` or `foot` button while what is on it is ready (73 under A in a vehicle,
--- 45/140/263 under B on foot). Re-held as the player gets in or out. Nothing at all during the stick
--- sprint: ControlBlocks' "related actions" would stop the injected sprint.
holdReader = function()
    local controls = {}
    if run ~= 'sprint' then
        if not sprintOnA() then controls[#controls + 1] = 21 end
        controls[#controls + 1] = 36
        controls[#controls + 1] = 80
        local inCar = IsPedInAnyVehicle(PlayerPedId(), false)
        for _, s in ipairs(SLOTS) do
            if s.gta and ((s.car and inCar) or (s.foot and not inCar))
                and layout[s.id] and actionOf(layout[s.id]).ready ~= false then
                for _, c in ipairs(s.gta) do controls[#controls + 1] = c end
            end
        end
    end
    ControlBlocks.hold('padRead', { controls = controls }, padFrame)
end

---@param mode 'jog'|'sprint'|nil
---@param why string
local function setRun(mode, why)
    if mode == run then return end
    -- Leaving the jog or sprint: the floor goes back to 0.
    if run ~= nil then SetPedMinMoveBlendRatio(PlayerPedId(), 0.0) end
    run = mode
    if reading then holdReader() end
    log('pad', 'run', (mode or 'off') .. ' (' .. why .. ')')
end

--- One frame of the jog or sprint. A disabled stick (a panel's block) reads 0, which ends it.
local function runFrame()
    local ped = PlayerPedId()
    local x, y = GetControlNormal(0, 30), GetControlNormal(0, 31)
    if x * x + y * y < STICK_MIDDLE * STICK_MIDDLE then return setRun(nil, 'stick in the middle') end
    if not IsPedOnFoot(ped) or IsEntityDead(ped) then return setRun(nil, 'not on foot') end
    if UI ~= nil and UI.IsBusy ~= nil and UI.IsBusy() then return setRun(nil, 'a bar or dialog') end
    -- A block can cap the speed (BlockControls walk / jog): a walk ends the run, a jog turns a sprint into a jog.
    local cap = ControlBlocks.speedCap()
    if cap == 'walk' then return setRun(nil, 'held to a walk') end
    if cap == 'jog' and run == 'sprint' then setRun('jog', 'held to a jog') end
    -- The sprint is a move blend floor of 3 plus the held sprint button (21), which alone does not keep it.
    if run == 'sprint' then
        SetPedMinMoveBlendRatio(ped, 3.0)
        SetControlNormal(0, 21, 1.0)
    else
        SetPedMinMoveBlendRatio(ped, 2.0)
    end
    -- Stand up out of a sneak started on the keyboard.
    if GetPedStealthMovement(ped) then SetPedStealthMovement(ped, false, 'DEFAULT_ACTION') end
end

--- May the stick's jog and sprint start now? Not IsGameInputFree, which a mode (giving, placing, a throw)
--- says no to: modes own their keys, not the legs, and a keyboard's Shift runs through them. Only a screen,
--- a bar or dialog, the NUI's focus or a typed amount stops it. A mode wanting slower movement says so with
--- its block (ControlBlocks.speedCap).
---@return boolean
local function moveFree()
    if IsNuiFocused() then return false end
    if UI ~= nil and UI.IsBusy ~= nil and UI.IsBusy() then return false end
    if IsAnyScreenOpen ~= nil and IsAnyScreenOpen() and PropertyEditorActive ~= true then return false end
    if Interactions ~= nil and Interactions.inputActive ~= nil and Interactions.inputActive() then return false end
    if FocusScreenUp ~= nil and FocusScreenUp('none') then return false end
    return true
end

--- A click of the sprint's button: a jog, or the second within Config.Controller.SprintDoubleClickMs, a sprint.
---@return string  what it did, for /paddebug
local function stickClick()
    if not IsPedOnFoot(PlayerPedId()) then return 'ignored: not on foot' end   -- in a car L3 is the horn
    if not moveFree() then return 'ignored: a screen has the keys' end
    local cap = ControlBlocks.speedCap()
    if cap == 'walk' then return 'ignored: held to a walk' end
    local now = GetGameTimer()
    local window = tonumber(PlayerPrefs.get('pad.doubleClickMs')) or 300
    local gap = now - lastClick
    if gap <= window then
        lastClick = -100000   -- a third click starts a new pair
        if cap == 'jog' then
            setRun('jog', 'double click, held to a jog')
            return ('second, %d ms after the first: held to a jog'):format(gap)
        end
        setRun('sprint', 'double click')
        return ('second, %d ms after the first: sprint'):format(gap)
    end
    lastClick = now
    setRun('jog', 'click')
    return 'first: jog'
end

ACTIONS.sprint.run = stickClick

-- The read

--- A plain button pressed, outside a panel.
---@param s table  a slot of PLAIN
---@return string  what it did, for /paddebug
local function pressPlain(s)
    -- LB + this direction holds something of its own: modFrame has the press.
    local lbId = LB_SLOT_OF[s.control]
    if held and lbId and layout[lbId] then return 'LB + it has its own' end
    -- A screen or mode has the keys (a panel, or a resource's screen that reads the pad itself). The
    -- jog / sprint (`move`) asks its own question.
    local a = layout[s.id] and actionOf(layout[s.id])
    if not IsGameInputFree() and not (a and a.move and moveFree()) then return 'ignored: a screen or mode has the keys' end
    -- A prompt's choices keep D-pad up and down; a held action still starts (tap is the prompt's, hold the radial's).
    if s.dir and InteractHasChoices() then
        InteractPressNav(s.dir)
        local id = layout[s.id]
        if not (id and actionOf(id).hold) then return 'prompt option ' .. s.dir end
        return 'prompt option ' .. s.dir .. '; ' .. press(s.id)
    end
    -- A in a vehicle uses a prompt in view first; with LB held it is LB + A (B on foot likewise).
    if (s.car or s.foot) and held then return 'LB is held' end
    if s.car and InteractHasFocus() then return 'a prompt has A' end
    return press(s.id)
end

padFrame = function()
    -- LB first, in a panel too.
    local lb = IsDisabledControlPressed(0, 205)
    if lb ~= held and (not lb or WhipLastInputIsPad()) then PadModSync(lb, 'pad') end

    -- Let go anywhere of what a plain button's press is holding (the radial is a panel by the time D-pad down comes up).
    for i = 1, #PLAIN do
        local s = PLAIN[i]
        if running[s.id] and IsDisabledControlJustReleased(0, s.control) then letGo(s.id) end
    end

    if run then runFrame() end

    for i = 1, #PLAIN do
        local s = PLAIN[i]
        if IsDisabledControlJustPressed(0, s.control) and WhipLastInputIsPad()
            and not (s.car and not IsPedInAnyVehicle(PlayerPedId(), false))
            and not (s.foot and IsPedInAnyVehicle(PlayerPedId(), false)) then
            if not WhipNavScopeOpen then
                log('pad', s.name, pressPlain(s))
            elseif not s.dpad and not s.car and not s.foot then
                -- In a panel the D-pad and A are the panel's; other buttons run what works in menus.
                local id = layout[s.id]
                if id and actionOf(id).menus then log('pad', s.name, press(s.id)) end
            end
        end
    end
end

--- The settled device changed (controller.lua, after its 400 ms settle), or the page asked for it.
---@param pad boolean
function PadDeviceChanged(pad)
    pad = pad == true
    if pad == reading then return end
    reading = pad
    if pad then
        holdReader()
    else
        setRun(nil, 'the keyboard took over')
        ControlBlocks.release('padRead')
        PadModSync(false, 'the keyboard took over')
        stopAll()
    end
    log('pad', 'reader', pad and 'on (a pad is the device)' or 'off (keyboard)')
end

-- The controller screen (html/js/pad-layout.js, in the pause menu)

--- What the screen draws: the actions, the layout in force, whip's default, and whether it is the player's own.
local function pageState(extra)
    local actions = {}
    for _, id in ipairs(ACTION_ORDER) do
        local a = ACTIONS[id]
        actions[#actions + 1] = { id = id, label = a.label, where = a.where, menus = a.menus == true, on = true }
    end
    -- Then the resources' own, by label.
    local others = {}
    for id, a in pairs(registered) do
        others[#others + 1] = { id = id, label = a.label, where = a.where, menus = a.menus == true, on = true, owner = a.owner }
    end
    table.sort(others, function(x, y) return x.label < y.label end)
    for _, a in ipairs(others) do actions[#actions + 1] = a end
    local st = {
        actions = actions,
        layout = layout,
        defaults = defaults(),
        custom = mine ~= nil,
        sprintOnA = sprintOnA(),
    }
    if extra then
        for k, v in pairs(extra) do st[k] = v end
    end
    return st
end

--- The default, the player's layout or the registered actions changed: redraw the screen if it is up.
local function pushPage()
    SendNUIMessage({ action = 'padLayout', state = pageState() })
end

RegisterNUICallback('padLayout', function(_, cb)
    cb(pageState())
end)

RegisterNUICallback('padLayoutSet', function(data, cb)
    if type(data) ~= 'table' then return cb(pageState({ error = 'no such button' })) end
    local action = data.action
    if action == nil or action == '' then action = false end
    local ok, info = setSlot(data.slot, action)
    cb(pageState(ok and { swap = info } or { error = info }))
end)

RegisterNUICallback('padLayoutReset', function(_, cb)
    resetLayout()
    cb(pageState())
end)

-- A vehicle's controls over the dial: taking the driver's seat with a pad shows a column for
-- Config.Controller.VehicleControlsMs (html/js/vehicle-controls.js): the engine (on whichever button the
-- layout has it) and every other ready car action. A bicycle has no engine. A car action coming ready while
-- driving shows it again with the new row. On a keyboard the column is the engine alone, on its binding
-- (keyboardControls). Each player can switch it off (pad.vehicleControls).

--- A button's pictures (html/img/pad): LB's first for the LB layer; A for A in a vehicle, B for B on foot.
---@return string[]
local function slotGlyphs(s)
    if s.id == 'veh_a' then return { 'a' } end
    if s.id == 'foot_b' then return { 'b' } end
    if s.lb then return { 'lb', (s.id:gsub('^lb_', '')) } end
    return { s.id }
end

--- What the driver of `veh` has on the pad, in the order it is shown: { { glyphs, label } }.
---@return table[]
local function vehicleControls(veh)
    local rows = {}
    local bicycle = GetVehicleClass(veh) == 13
    -- The engine, then the rest in button order.
    for _, s in ipairs(SLOTS) do
        if layout[s.id] == 'engine' and not bicycle then
            local engineOn = GetIsVehicleEngineRunning(veh)
            rows[#rows + 1] = { glyphs = slotGlyphs(s), label = (engineOn == 1 or engineOn == true) and 'Engine off' or 'Start engine' }
        end
    end
    for _, s in ipairs(SLOTS) do
        local id = layout[s.id]
        local a = id and id ~= 'engine' and actionOf(id)
        if a and a.where == 'car' and a.ready ~= false then
            rows[#rows + 1] = { glyphs = slotGlyphs(s), label = a.label }
        end
    end
    return rows
end

--- The key a binding is on, as GTA's help text names it ('t_E' -> 'E'), or nil for one with no short name
--- (a mouse wheel) or none at all.
---@return string|nil
local function boundKey(command)
    local s = GetControlInstructionalButton(0, GetHashKey(command) | 0x80000000, true)
    local key = type(s) == 'string' and s:match('^t_(.+)$') or nil
    return (key and key ~= '' and #key <= 8) and key:upper() or nil
end

--- The keyboard's column: the engine on its binding. The toggle when a key is bound to it (none by default),
--- else the directional binding for what it would do now: wheel up starts (client/vehicles.lua), down stops.
--- A row's `keys` are words in the key, where a pad's `glyphs` are pictures.
---@return table[]
local function keyboardControls(veh)
    if GetVehicleClass(veh) == 13 then return {} end
    local engineOn = GetIsVehicleEngineRunning(veh)
    engineOn = engineOn == 1 or engineOn == true
    local key = boundKey('+whip_ignition_toggle')
        or boundKey(engineOn and '+whip_ignition_off' or '+whip_ignition_on')
        or (engineOn and 'SCROLL \u{25BC}' or 'SCROLL \u{25B2}')
    return { { keys = { key }, label = engineOn and 'Engine off' or 'Start engine' } }
end

local vcUntil = 0  -- GetGameTimer() until which the column is up

-- Where the vehicle's dial sits (client/vehicle_hud.lua's KIND).
local VC_KIND = { [14] = 'boat', [15] = 'air', [16] = 'air' }

--- Show the column for the vehicle the player drives, if they have it on: the pad's buttons, or on a keyboard
--- the engine's key.
local function showVehicleControls(veh)
    if PlayerPrefs.get('pad.vehicleControls') == false then return end
    if not veh or veh == 0 or not DoesEntityExist(veh) or GetPedInVehicleSeat(veh, -1) ~= PlayerPedId() then return end
    local rows = reading and vehicleControls(veh) or keyboardControls(veh)
    if #rows == 0 then return end
    local ms = math.max(500, tonumber(Config.Controller and Config.Controller.VehicleControlsMs) or 5000)
    vcUntil = GetGameTimer() + ms
    -- shape: the 3D prompts' key shape; keys: whether it wears one (pad.vehicleControlsKeys)
    SendNUIMessage({ action = 'vehicleControls', rows = rows, ms = ms, kind = VC_KIND[GetVehicleClass(veh)] or 'car',
                     shape = InteractStyle.baseTheme(), keys = not reading or PlayerPrefs.get('pad.vehicleControlsKeys') == true })
end

local function hideVehicleControls()
    if GetGameTimer() >= vcUntil then return end
    vcUntil = 0
    SendNUIMessage({ action = 'vehicleControls', rows = {} })
end

-- client/vehicles.lua says which seat on getting in and on every change of seat (the driver's is -1).
AddEventHandler('whip_core:vehicle:entered', function(data)
    if type(data) ~= 'table' then return end
    if data.seat == -1 then showVehicleControls(data.entity) else hideVehicleControls() end
    if reading then holdReader() end   -- GTA's buttons differ in a car
end)
AddEventHandler('whip_core:vehicle:exited', function()
    hideVehicleControls()
    if reading then holdReader() end
end)

-- Another resource's actions on whip's buttons:
--
--     exports.whip_core:RegisterPadAction('nitrous', {
--         label     = 'Nitrous',               -- what the Controller screen calls it
--         onPress   = function() boost() end,  -- or command = '+my_command' (its '-' half on the release)
--         onRelease = function() stop() end,
--         where     = 'car',                   -- 'car' / 'foot': where it does anything
--         slot      = 'veh_a',                 -- the button it goes on while that has nothing on it
--         ready     = false,                   -- not yet: the button stays GTA's (SetPadActionReady)
--     })
--
-- One owner per name: registering again replaces it, and it goes when its resource stops. It runs only
-- while no screen or mode has the keys, unless `menus = true`. A `slot` that whip's default already
-- gives another action starts on no button (F8 says so once, sayTaken). GetPadActionButton(id) says
-- which button an action is on.

local function validPadAction(id, def)
    if type(id) ~= 'string' or not id:match('^[%a][%w_]*$') or #id > 32 then
        return false, 'a pad action needs a name: a word of letters, digits and _ (up to 32)'
    end
    if ACTIONS[id] then return false, ('"%s" is one of whip\'s own pad actions'):format(id) end
    if type(def) ~= 'table' then return false, ('pad action "%s": the second argument is its table'):format(id) end
    if type(def.label) ~= 'string' or def.label == '' or #def.label > 32 then
        return false, ('pad action "%s": label must be text, up to 32 letters'):format(id)
    end
    if def.command ~= nil and (type(def.command) ~= 'string' or not def.command:match('^[%w_%+%-%.%:]+$')) then
        return false, ('pad action "%s": command must be a command name, such as +my_action'):format(id)
    end
    if (def.command == nil) == (def.onPress == nil) then
        return false, ('pad action "%s": give it a command or an onPress, one of the two'):format(id)
    end
    if def.onRelease ~= nil and def.onPress == nil then
        return false, ('pad action "%s": onRelease goes with onPress (a command\'s release is its - half)'):format(id)
    end
    if def.where ~= nil and def.where ~= 'car' and def.where ~= 'foot' then
        return false, ('pad action "%s": where is \'car\', \'foot\' or left out'):format(id)
    end
    if def.slot ~= nil and not SLOT[def.slot] then
        local ids = {}
        for _, s in ipairs(SLOTS) do ids[#ids + 1] = s.id end
        return false, ('pad action "%s": there is no button "%s" (whip\'s are: %s)'):format(id, tostring(def.slot), table.concat(ids, ', '))
    end
    return true
end

--- [id] = F8 has said its button is another action's in whip's default (once per registration).
local toldTaken = {}

--- Say in F8, once, that an action's requested button is another action's in whip's default (it still
--- registers and a player can place it). Not for a player's own layout.
local function sayTaken()
    local d = defaults()
    local placed = {}
    for _, a in pairs(d) do placed[a] = true end
    for id, a in pairs(registered) do
        local s = a.slot
        if s and not placed[id] and not toldTaken[id] then
            toldTaken[id] = true
            local holder = d[s] and actionOf(d[s])
            print(('[whip_core:pad] "%s" (%s) asked for %s, which has %s on it, so it starts on no button. A player can put it on one in the pause menu\'s Controller screen; GetPadActionButton says where it is.')
                :format(id, tostring(a.owner), SLOT[s].name, holder and ('"' .. holder.label .. '"') or 'another action'))
        end
    end
end

-- Nothing here yields: a stopping resource's sweep calls onRemove in a loop.
local padActionReg = Registry.new('padActions', {
    label    = 'pad action',
    store    = registered,
    validate = validPadAction,
    onAdd    = function() resolve(); pushPage(); sayTaken() end,
    onRemove = function(id) toldTaken[id] = nil; resolve(); pushPage() end,
})

--- Put one of your actions on whip's controller buttons.
---@param id string
---@param def table { label, command? | onPress?, onRelease?, where?, menus?, slot? }
---@return boolean ok, string|nil why
exports('RegisterPadAction', function(id, def)
    local owner = Registry.caller()   -- first, before anything can yield
    if type(def) ~= 'table' then return validPadAction(id, def) end
    local ok, why = padActionReg:add(owner, id, {
        label = def.label, command = def.command, onPress = def.onPress, onRelease = def.onRelease,
        where = def.where, menus = def.menus == true, slot = def.slot, ready = def.ready ~= false, owner = owner,
    })
    if not ok then return false, why --[[@as string]] end   -- a refusal's reason
    return true
end)

--- Take one of your pad actions off whip's buttons.
---@param id string
---@return boolean ok, string|nil why
exports('RemovePadAction', function(id)
    return padActionReg:remove(Registry.caller(), id)
end)

--- Can one of your pad actions do anything right now? If not ready, its button is GTA's again (the press
--- goes through and GTA's action is not held off). It keeps its button.
---@param id string
---@param ready boolean
---@return boolean ok, string|nil why
exports('SetPadActionReady', function(id, ready)
    local owner = Registry.caller()
    local a = registered[id]
    if not a or a.owner ~= owner then return false, ('pad action "%s" is not one of yours'):format(tostring(id)) end
    ready = ready ~= false
    if a.ready == ready then return true end
    a.ready = ready
    if reading then holdReader() end
    if held then ControlBlocks.hold('padMod', modBlock(), modFrame) end
    -- A vehicle action that just came ready while the player drives: show the vehicle's controls again.
    if ready and a.where == 'car' then
        for _, s in ipairs(SLOTS) do
            if layout[s.id] == id then
                showVehicleControls(GetVehiclePedIsIn(PlayerPedId(), false))
                break
            end
        end
    end
    return true
end)

--- Which button an action is on now in this player's layout, for your own hint ("{pad:lb}{pad:y} Cafe menu").
--- Any action, whip's own too ('radial', 'inventory', 'engine', 'sprint'). Ask when you show the hint: players move actions.
---@param id string
---@return string|nil slot  'lb_y'; nil when it is on no button (or there is no such action)
---@return string|nil hint  the button's pictures for UI.ShowText: '{pad:lb}{pad:y}'
---@return string|nil name  'LB+Y'
exports('GetPadActionButton', function(id)
    if type(id) ~= 'string' then return nil end
    for _, s in ipairs(SLOTS) do
        if layout[s.id] == id then
            local pictures = {}
            for _, g in ipairs(slotGlyphs(s)) do pictures[#pictures + 1] = '{pad:' .. g .. '}' end
            return s.id, table.concat(pictures), s.name
        end
    end
    return nil
end)

-- SprintOnA changed: hold the reader again with the matching block. The default layout changed:
-- resolve again. The other Controller figures are read at each press.
Settings.onChange('Controller.SprintOnA', function()
    if reading then holdReader() end
    pushPage()
end)
-- ...and the player's own choice of it.
PlayerPrefs.onChange('pad.sprintOnA', function()
    if reading then holdReader() end
    pushPage()
end)
Settings.onChange('Controller.Layout', function()
    resolve()
    pushPage()
    sayTaken()
end)

mine = loadMine()
resolve()

-- Stopping mid-sentence lets go of the talk key; ControlBlocks sweeps the blocks itself.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    stopAll()
end)
