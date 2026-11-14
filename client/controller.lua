-- ============================================
-- CONTROLLER BRIDGE — reading the gamepad for NUI panels
-- ============================================
--
-- Whip's panels read the keyboard in the browser, and a gamepad produces no keyboard events. The
-- browser cannot read the pad either: NUI pages are iframes, and the Gamepad API needs a
-- Permissions-Policy only FiveM's parent document can grant. So the pad is read HERE and posted to
-- the page.
--
-- (The 3D prompts need none of this: GTA control ids map to whatever hardware is in the player's
-- hands. Options cycle on 16/17, not 14/15, which are also a pad's triggers.)
--
-- ============================================
-- The one non-obvious constraint
-- ============================================
--
-- `IsControlJustPressed` stops working while `SetNuiFocus(true, …)` is on (focus goes to the
-- browser). `SetNuiFocusKeepInput(true)` keeps the game receiving input, ALL of it, so while the
-- driver runs every gameplay control is held off (the 'padNav' control block, all = true), and the
-- nav controls are read with the `Disabled` variants.

-- ============================================
-- Which controls, and what they mean
-- ============================================

--- The frontend set, which GTA's own menus use. The keyboard column is for orientation only: nav is
--- sent only while a pad is the active device.
---
---     nav          control                      keyboard        pad
---     up           188 INPUT_FRONTEND_UP        arrow up        D-pad up
---     down         187 INPUT_FRONTEND_DOWN      arrow down      D-pad down
---     left         189 INPUT_FRONTEND_LEFT      arrow left      D-pad left
---     right        190 INPUT_FRONTEND_RIGHT     arrow right     D-pad right
---     select       201 INPUT_FRONTEND_ACCEPT    enter           A
---     back         202 INPUT_FRONTEND_CANCEL    backspace/esc   B
---     buttonX      203 INPUT_FRONTEND_X         space           X
---     buttonY      204 INPUT_FRONTEND_Y         tab             Y
---     tabPrev      205 INPUT_FRONTEND_LB        Q               LB
---     tabNext      206 INPUT_FRONTEND_RB        E               RB
---
--- Named by meaning, except X and Y, which have no shared meaning across panels: `buttonX` /
--- `buttonY`, and each panel decides.

--- Directions repeat while held. Everything else fires once per press.
local NAV_HELD = {
    { nav = 'up',    control = 188 },
    { nav = 'down',  control = 187 },
    { nav = 'left',  control = 189 },
    { nav = 'right', control = 190 },
}

--- `combo` marks the two that are LB + A / LB + X while LB is held (client/pad.lua): those presses
--- talk and are not sent. tabPrev (205, LB) is not here: LB is the combo key, so it goes on LB's
--- release — see DriveFrame. Any other button with LB is the combo's too while the player's layout
--- puts something that works in menus on it (PadComboInMenus).
local NAV_PRESS = {
    { nav = 'select',  control = 201, combo = true },
    { nav = 'back',    control = 202 },
    { nav = 'buttonX', control = 203, combo = true },
    { nav = 'buttonY', control = 204 },
    { nav = 'tabNext', control = 206 },
}

--- LB: whether it was down last frame, and whether this driver saw it go down (a press carried in
--- from before the panel opened does not turn the page when it is let go).
local LB_CONTROL = 205
local lbWasDown, lbPressedHere = false, false

--- Left stick, so the stick navigates as well as the D-pad.
local AXIS_X, AXIS_Y = 195, 196

--- How far the stick must travel before it counts as a direction: well past a worn stick's
--- resting noise.
local STICK_DEADZONE = 0.6

--- Which way is up on the Y axis. GTA reports stick-up as NEGATIVE on the frontend axis.
---
--- If the stick navigates upside down, flip this to 1.
local STICK_UP_SIGN = -1

-- ============================================
-- The stick and triggers as numbers (the pause map pans on the stick and zooms on the triggers)
-- ============================================
--
-- A scope that asks for them (router.js activeNavAnalog) gets the positions, and the stick stops
-- being up/down/left/right for it; the D-pad still is. Sent when they change, at most one message per
-- ANALOG_GAP_MS while they move and at once when they are let go: the page keeps moving at the last
-- numbers it was sent, so a steady push costs no messages at all.

--- Below this far from the centre the stick reads 0. Small, unlike STICK_DEADZONE: here a light push
--- is a slow pan, not a press. Past it the travel is rescaled, so moving off it does not jump.
local ANALOG_DEADZONE = 0.18
local ANALOG_STEP = 0.02      -- positions are rounded to this, so a shaking thumb is not a stream of messages
local ANALOG_GAP_MS = 33
-- (The triggers: WhipPadTrigger, below.)

--- The right stick too (either stick aims the radial wheel), as rx/ry. The frontend right
--- stick, as the skill check reads it (client/ui.lua) and /paddebug shows it; up negative, like the left.
local RIGHT_X, RIGHT_Y = 197, 198

-- ============================================
-- Repeat timing
-- ============================================

--- Before a held direction starts repeating, and how fast it repeats after that.
---
--- Without the first delay a single press (held ~100ms) scrolls several items; without the second,
--- holding walks the list at one item per frame. The first thing to tune if a menu feels sticky or
--- runaway.
local REPEAT_DELAY_MS = 380
local REPEAT_RATE_MS  = 110

-- ============================================
-- State
-- ============================================

--- Name of the NUI scope currently able to take controller input, or nil for none.
---
--- Reported by the browser (NuiRouter's scope list; html/js/controller.js posts it on every change).
---
--- nil also means "a panel is open but has no controller support": the driver must not take the pad
--- for a panel that cannot use it, or the player is sealed inside it.
local navScope = nil

--- That scope wants the stick and triggers as numbers (see ANALOG_DEADZONE). Reported with navScope.
local navAnalog = false

--- What the page was last sent of them, and when.
local sentX, sentY, sentLT, sentRT, analogSentAt = 0, 0, 0, 0, 0
local sentRX, sentRY = 0, 0
local sentA = false   -- A held (the Director's cursor drags while it is)

--- The same answer as a plain global, for per-frame readers in other client files.
---
--- A file that reads a pad button for its own purpose has to know when a PANEL is using that button
--- instead (D-pad left in the inventory must not also fire the world's D-pad left).
WhipNavScopeOpen = false

--- Was the last input a gamepad? Polled, because the game gives no event for it.
local padActive = false

--- The same answer as a plain global, for per-frame readers in other client files.
---
--- A boolean rather than the export (`IsControllerActive`, for satellites): client/interact.lua
--- reads it every frame.
WhipPadActive = false

--- Whether this file currently holds SetNuiFocusKeepInput (set and cleared once per session of
--- control, not every frame).
local holdingInput = false

--- Per-direction repeat clocks: when it went down, and when it last fired.
local heldSince, lastFired = {}, {}

--- Directions already down when the driver took the pad: the D-pad right that OPENED the inventory is not a press for
--- it (Josh, 1 Nov: the inventory opened on its second slot), any more than an A carried in is (presses fire only
--- on JustPressed) or an LB is (lbPressedHere). Each is ignored until it is let go, then works as any press does.
--- Only what is down in the panel's FIRST frame (carryNext): a keyboard player who picks up the pad in an open panel
--- gets that very press, as UpdateDevice's comment in DriveFrame says.
local carried = {}
local carryNext = false   -- the next DriveFrame is the panel's first: what is down then is carried
local driving = false     -- a panel's driver is running (RunDriver, until StopDriver)

--- Forget every repeat clock. Called whenever control is taken or released, and when the player
--- switches to a keyboard, so a direction that was held cannot fire into the next panel that opens.
--- Above UpdateDevice, which calls it.
local function ResetRepeats()
    for i = 1, #NAV_HELD do
        heldSince[NAV_HELD[i].nav] = nil
        lastFired[NAV_HELD[i].nav] = nil
        carried[NAV_HELD[i].nav] = nil
    end
end

-- ============================================
-- Device detection
-- ============================================

--- True when the player's LAST input came from a gamepad.
---
--- The native has two names (`IsInputDisabled`, `IsUsingKeyboard`), and which one a build exposes
--- is unknown: both are tried, and with neither the answer is "keyboard" (the bridge off). Index 2
--- asks about the last input METHOD rather than a pad slot.
---@return boolean
local function PadIsActive()
    if IsInputDisabled then return not IsInputDisabled(2) end
    if IsUsingKeyboard then return not IsUsingKeyboard(2) end
    return false
end

--- The same answer, asked NOW, for client/pad.lua's presses: the frontend controls it reads are also
--- arrow keys, Q and Shift, and the settled answer lags a player putting the pad down.
WhipLastInputIsPad = PadIsActive

-- ============================================
-- A mode's keys: one key on a keyboard, one button on a pad
-- ============================================
--
-- A mode with keys of its own (placing, a camera, an editor walked round in) reads one control on a keyboard
-- and another on a pad, whichever device is in the player's hands, never both: a pad's buttons are keys on a
-- keyboard too (A is Enter, B Backspace, X Space, LB E and Q), so reading both at once fires a keyboard
-- player's key from their pad and the other way round. On a pad, never with LB held: LB + a button is whip's
-- combo (client/pad.lua). The device is asked now, not settled: the press is what it means now.
--
-- Read through blocks (the IsDisabled* readers): a mode holds its keys off for the game with BlockControls.

--- `key` went down this frame on a keyboard, or `button` on a pad (never with LB held). Either may be nil: that
--- device has no such key. `button` is never LB (205), whip's combo key.
---@param key number|nil   a control, read on a keyboard
---@param button number|nil  a control, read on a pad
---@return boolean
function WhipKeyPressed(key, button)
    if PadIsActive() then
        return button ~= nil and not WhipPadModHeld and IsDisabledControlJustPressed(0, button) and true or false
    end
    return key ~= nil and IsDisabledControlJustPressed(0, key) and true or false
end

--- The same, held down.
---@param key number|nil
---@param button number|nil
---@return boolean
function WhipKeyHeld(key, button)
    if PadIsActive() then
        return button ~= nil and not WhipPadModHeld and IsDisabledControlPressed(0, button) and true or false
    end
    return key ~= nil and IsDisabledControlPressed(0, key) and true or false
end

--- That key for a UI.ShowText hint: '[Space]' on a keyboard, the button's PICTURE on a pad — the {pad:x} marker,
--- which the text band draws from html/img/pad. `button` is a picture's name (a, b, x, y, lb, rb, lt, rt, ls, rs,
--- l3, r3, dpad, dpad_up ... dpad_right, view, menu), or a list shown side by side ({ 'lt', 'rt' }). Either may be
--- nil: '' on that device. GTA's own help text (BeginTextCommandDisplayHelp) cannot draw a picture.
---@param keyText string|nil  the key's name on a keyboard: 'E', 'Space', 'Scroll'
---@param button string|string[]|nil
---@return string
function WhipKeyHint(keyText, button)
    if not WhipPadActive then
        return type(keyText) == 'string' and keyText ~= '' and ('[' .. keyText .. ']') or ''
    end
    local list = type(button) == 'table' and button or { button }
    local out = {}
    for i = 1, #list do
        local name = list[i]
        if type(name) == 'string' and name:match('^[%w_]+$') then out[#out + 1] = '{pad:' .. name .. '}' end
    end
    return table.concat(out)
end

-- A MODE'S "E" IS THE INTERACT KEY (Josh, 9 Nov 2026). On a keyboard, placing, giving, an emote's spot and the
-- respawn hold confirm on whatever key the Interact binding is on (E unless the player moved it in GTA's Key
-- Bindings), as the prompts do, and their hint names that key. Not control 38: that is always E, so a player who
-- moved Interact had one key for prompts and another for modes. On a pad it is A (201), as the 3D prompts' is:
-- GTA puts E and LB on one control (38), and LB is the combo key. A mode's "C" (cancel, 26, INPUT_LOOK_BEHIND,
-- which a pad has on R3) is B (202, the frontend cancel).
--
-- The binding is a command (client/interact.lua's +whip_interact), heard on its own thread whenever it fires, so
-- its press is kept here (WhipInteractKey) for the mode to find, the way the prompts park theirs. Kept apart from
-- the prompts' own: those are cleared whenever the prompts stand down, and a mode stands them down.

local interactKey = { pressFrame = nil, held = false }

--- Who is asking (WhipAcceptJustPressed), counted in frames: from = the first frame of this run of asking (a mode
--- asks every frame), last = the latest. taken / takenIn: the press already reported, and the frame it was.
local acceptLook = { from = nil, last = nil, taken = nil, takenIn = nil }

--- A run of asking that stopped this many frames ago has ended: the next asking is a new mode, and a press from
--- before it is not that mode's. (A mode may skip asking for a moment: placing asks only while the spot is valid.)
local LOOK_GAP_FRAMES = 15

--- The Interact binding went down (true) or came up (client/interact.lua's +whip_interact / -whip_interact).
---@param down boolean
function WhipInteractKey(down)
    if down then interactKey.pressFrame = GetFrameCount() end
    interactKey.held = down == true
end

--- The Interact key went down this frame, for a mode. Only a press made while the mode was already asking: the
--- press that STARTED it (a prompt's E that began the placing) is not its first "place". A command can land before
--- or after the mode's look in a frame (the game picks), so this frame's press or the last frame's.
---@return boolean
local function interactKeyJustPressed()
    local f = GetFrameCount()
    local L = acceptLook
    if L.last == nil or f - L.last > LOOK_GAP_FRAMES then L.from = f end
    L.last = f
    if L.takenIn == f then return true end   -- asked again in the frame it was reported
    local p = interactKey.pressFrame
    if p ~= nil and p ~= L.taken and p > L.from and f - p <= 1 then
        L.taken, L.takenIn = p, f
        return true
    end
    return false
end

--- The Interact key is held, for a mode's hold (the respawn hold). A key let go while a screen or the pause menu had
--- the keys never sends its release, so one coming up counts as letting go: hold it again after.
---@return boolean
local function interactKeyHeld()
    if interactKey.held and (IsNuiFocused() or IsPauseMenuActive()) then interactKey.held = false end
    return interactKey.held
end

--- The Interact key's name on a keyboard, for a hint ('E', or where the player moved it).
---@return string
local function interactKeyName()
    local name = Interactions and Interactions.keyName and Interactions.keyName()
    return type(name) == 'string' and name ~= '' and name or 'E'
end

--- The mode's "E" went down this frame: the Interact key on a keyboard, A on a pad (never LB + A).
---@return boolean
function WhipAcceptJustPressed()
    local key = interactKeyJustPressed()   -- asked on either device: it keeps count of who is asking (above)
    if PadIsActive() then return WhipKeyPressed(nil, 201) end
    return key
end

--- The mode's "E" is held (the respawn hold).
---@return boolean
function WhipAcceptHeld()
    if PadIsActive() then return WhipKeyHeld(nil, 201) end
    return interactKeyHeld()
end

--- '[E]' (the Interact key's name) on a keyboard, the A button's picture on a pad.
---@return string
function WhipAcceptHint() return WhipKeyHint(interactKeyName(), 'a') end

--- The mode's "C" went down this frame: C on a keyboard, B on a pad (never LB + B).
---@return boolean
function WhipCancelJustPressed() return WhipKeyPressed(26, 202) end

--- '[C]' on a keyboard, the B button's picture on a pad.
---@return string
function WhipCancelHint() return WhipKeyHint('C', 'b') end

---- WhipAcceptKey / WhipCancelKey ('E' / 'A', 'C' / 'B' for GTA's help text) and their exports AcceptKey /
---- CancelKey: DELETED 9 Nov 2026, nothing called them (prompts name their key with Interactions.keyLabel). ----

-- ============================================
-- The triggers
-- ============================================

--- Each trigger is several controls, and which carries the travel depends on where the player is
--- (client/controller_debug.lua's Triggers bars): frontend, on foot, in a car. The most of them wins.
local TRIGGER = { lt = { 207, 25, 72 }, rt = { 208, 24, 71 } }

--- A trigger short of this is resting, not pulled.
local TRIGGER_DEADZONE = 0.08

--- How far a trigger is pulled, 0 to 1: the most any of its controls reports (read through blocks), or 0 short of
--- `dead` (TRIGGER_DEADZONE when left out). Not rescaled: past `dead` it is the trigger's own travel.
---@param side 'lt'|'rt'
---@param dead number|nil
---@return number
function WhipPadTrigger(side, dead)
    local controls = TRIGGER[side]
    if not controls then return 0.0 end
    local v = 0.0
    for i = 1, #controls do
        local n = GetDisabledControlNormal(0, controls[i])
        if n > v then v = n end
    end
    return v > (dead or TRIGGER_DEADZONE) and v or 0.0
end

--- What whip_core:pad:deviceChanged last said (nil: nothing yet).
local emittedDevice = nil

--- Tell the page which device is in the player's hands, so it can show the right glyph — and any resource, once
--- the answer changes: whip_core:pad:deviceChanged { pad }, the moment whip's own hints swap, so a resource's
--- hints swap with them instead of asking IsControllerActive on a timer.
local function PublishDevice()
    SendNUIMessage({ action = 'controllerDevice', pad = padActive })
    if padActive ~= emittedDevice then
        emittedDevice = padActive
        WhipEmit('whip_core:pad:deviceChanged', { pad = padActive })
    end
end

--- Re-read the device and tell the page if it changed.
---
--- Called every frame while a panel is open: the first press on a pad IS the input that changes the
--- answer, so the press and the answer must land on the same frame.
local function UpdateDevice()
    local now = PadIsActive()
    if now == padActive then return end
    padActive = now
    WhipPadActive = now     -- kept in step here, the one place padActive is ever written

    -- On the switch to a keyboard, and only then: the one moment the clocks can hold anything.
    if not now then ResetRepeats() end
end

--- What the page was last told, and when the answer started disagreeing with it.
local publishedDevice, disagreeingSince = nil, 0

--- How long the device has to stay settled before the page is told about it.
---
--- The flag is instant (`padActive` decides what a press MEANS); the message, which only swaps a
--- glyph, is damped: a hand resting on a mouse while the other holds a pad makes the answer flap,
--- and every message restyles the whole document.
local DEVICE_SETTLE_MS = 400

--- Tell the page, once the answer has stopped changing its mind.
local function PublishIfSettled()
    if padActive == publishedDevice then
        disagreeingSince = 0
        return
    end

    if disagreeingSince == 0 then
        disagreeingSince = GetGameTimer()
        return
    end

    if GetGameTimer() - disagreeingSince < DEVICE_SETTLE_MS then return end

    publishedDevice  = padActive
    disagreeingSince = 0
    PublishDevice()
    if PadDeviceChanged then PadDeviceChanged(padActive) end   -- client/pad.lua: A's sprint, settled
end

-- ============================================
-- Taking and releasing the pad
-- ============================================

--- Start or stop holding game input open while the browser has focus.
---
--- Through Focus.padInput (client/focus.lua), a layer over whatever screen holds the focus. One call
--- in, one call out.
---@param want boolean
local function HoldInput(want)
    if want == holdingInput then return end
    holdingInput = want
    Focus.padInput(want)
end

--- Should the driver be running right now?
---
--- On the panel, not on the device: `padActive` only becomes true once the player has pressed
--- something on the pad, so gating on it lets that first press leak into gameplay (F2 then B
--- punches). Controls are disabled from the moment the page reports a panel; the device only
--- decides whether to SEND nav. The report itself starts the driver (RunDriver), leaving only the
--- page's own throttle as a window.
local function ShouldDrive()
    return navScope ~= nil
end

-- (ResetRepeats lives above UpdateDevice, which calls it.)

-- ============================================
-- Reading
-- ============================================

--- Is this direction being held, by either the D-pad or the stick?
---
--- The stick position is read once per frame by the driver and handed in.
---@param nav string
---@param control number
---@param x number  left stick X this frame
---@param y number  left stick Y this frame, with up positive (STICK_UP_SIGN applied)
---@return boolean
local function DirectionHeld(nav, control, x, y)
    -- The D-pad, unless LB + it talks (PadComboInMenus); the stick still moves through the menu then.
    if IsDisabledControlPressed(0, control) and not PadComboInMenus(control) then return true end

    if nav == 'left'  then return x < -STICK_DEADZONE end
    if nav == 'right' then return x > STICK_DEADZONE end
    if nav == 'up'    then return y > STICK_DEADZONE end
    return y < -STICK_DEADZONE
end

--- The left stick past ANALOG_DEADZONE, rescaled so its edge is 0. A NaN reads as the middle.
---@return number, number
local function StickPast(x, y)
    local m = math.sqrt(x * x + y * y)
    if not (m > ANALOG_DEADZONE) then return 0.0, 0.0 end
    local k = math.min(1.0, (m - ANALOG_DEADZONE) / (1.0 - ANALOG_DEADZONE)) / m
    return x * k, y * k
end

--- One trigger for the page, 0-1: past TRIGGER_DEADZONE, rescaled so its edge is 0 (a light pull is a slow zoom,
--- not a jump).
---@param side 'lt'|'rt'
---@return number
local function TriggerAt(side)
    local v = WhipPadTrigger(side)
    if v == 0.0 then return 0.0 end
    return math.min(1.0, (v - TRIGGER_DEADZONE) / (1.0 - TRIGGER_DEADZONE))
end

local function Quantise(v)
    return math.floor(v / ANALOG_STEP + 0.5) * ANALOG_STEP
end

--- Send the sticks and triggers if they changed (see ANALOG_GAP_MS), and `a`, whether A is held: the
--- page hears A's press as 'select' but never its release, and a cursor that drags needs both (the
--- Director's). A going down or up is sent at once, never held back by the gap, so a
--- quick tap is a press and a release. Scopes that do not read `a` never see a difference.
local function SendAnalog(x, y, lt, rt, rx, ry, a, now)
    x, y, lt, rt = Quantise(x), Quantise(y), Quantise(lt), Quantise(rt)
    rx, ry = Quantise(rx), Quantise(ry)
    if x == sentX and y == sentY and lt == sentLT and rt == sentRT and rx == sentRX and ry == sentRY
        and a == sentA then return end
    local letGo = x == 0 and y == 0 and lt == 0 and rt == 0 and rx == 0 and ry == 0
    if not letGo and a == sentA and now - analogSentAt < ANALOG_GAP_MS then return end
    sentX, sentY, sentLT, sentRT, analogSentAt = x, y, lt, rt, now
    sentRX, sentRY, sentA = rx, ry, a
    SendNUIMessage({ action = 'navAnalog', x = x, y = y, lt = lt, rt = rt, rx = rx, ry = ry, a = a })
end

--- Stop whatever the page is moving on them, if anything: the pad was put down, the panel closed, or
--- the scope stopped asking. A held is let go too, so a drag never outlives the pad.
local function ClearAnalog()
    if sentX == 0 and sentY == 0 and sentLT == 0 and sentRT == 0 and sentRX == 0 and sentRY == 0
        and not sentA then return end
    sentX, sentY, sentLT, sentRT, sentRX, sentRY, sentA = 0, 0, 0, 0, 0, 0, false
    SendNUIMessage({ action = 'navAnalog', x = 0, y = 0, lt = 0, rt = 0, rx = 0, ry = 0, a = false })
end

--- RB, held under a press (in the inventory RB + A is a shift-click, the fast transfer).
--- RB's own press still goes as tabNext; this says it is STILL DOWN when another button goes, which the
--- page cannot know (it hears presses, never releases).
local RB_CONTROL = 206

--- Send one nav intent to the page, with `rb` when RB is held under it, and `held`: for a direction, how long
--- it has been down in ms (0 on the press, more on each repeat), so a page can speed up a long hold (the
--- inventory's Split amount).
local function SendNav(nav, held)
    -- Announced to the debug overlay, if one is listening (client/controller_debug.lua defines this
    -- global only while its panel is open).
    if WhipPadDebugFire then WhipPadDebugFire('nav', nav, navScope) end

    local rb = nav ~= 'tabNext' and IsDisabledControlPressed(0, RB_CONTROL) and true or nil
    SendNUIMessage({ action = 'navInput', nav = nav, rb = rb, held = held })
end

-- ============================================
-- The driver
-- ============================================

--- Born when a panel opens, gone when it closes. The driver is the 'padNav' control
--- block: EVERY gameplay control off for as long as a panel can take a pad (held from the frame the
--- panel says so), with one frame of driving as its per-frame hook. Harmless for a keyboard player:
--- those panels hold NUI focus, so their keyboard and mouse were not reaching gameplay anyway.
local DRIVE_BLOCK = { all = true }

--- One frame of driving: the device, and the nav a pad sends.
local function DriveFrame()
    -- Inline, not on the watcher's 200ms tick: the press about to be read below may be the very
    -- input that makes the answer "gamepad". See UpdateDevice.
    UpdateDevice()

    -- The panel's first frame: what is held now came from before the panel (see `carried`). Taken here, before the
    -- keyboard return, so a keyboard player's later switch to the pad is not a "first frame".
    local fresh = carryNext
    carryNext = false

    -- A keyboard player with a panel open gets the disable and nothing else (their keys already
    -- reach the page; nav as well would step a list twice).
    if not padActive then
        ClearAnalog()
        if holdingInput then HoldInput(false) end
        return
    end

    -- The first frame with the pad: the repeat clocks start again.
    if not holdingInput then
        HoldInput(true)
        ResetRepeats()
        lbWasDown, lbPressedHere = IsDisabledControlPressed(0, LB_CONTROL), false
    end

    local now = GetGameTimer()

    -- The stick, once each axis per frame (see DirectionHeld). GetDisabledControlNormal rather than
    -- GetControlNormal: the axes are disabled along with everything else above, and the plain
    -- reader returns 0.0 for a disabled control.
    local stickX = GetDisabledControlNormal(0, AXIS_X)
    local stickY = GetDisabledControlNormal(0, AXIS_Y) * STICK_UP_SIGN

    -- A scope that takes the stick as numbers gets them, and the stick is no direction for it.
    if navAnalog then
        local ax, ay = StickPast(stickX, stickY)
        local bx, by = StickPast(GetDisabledControlNormal(0, RIGHT_X),
                                 GetDisabledControlNormal(0, RIGHT_Y) * STICK_UP_SIGN)
        -- A held, and never with LB down: LB + A talks, and is never A.
        local aHeld = IsDisabledControlPressed(0, 201) and not IsDisabledControlPressed(0, LB_CONTROL)
        SendAnalog(ax, ay, TriggerAt('lt'), TriggerAt('rt'), bx, by, aHeld and true or false, now)
        stickX, stickY = 0.0, 0.0
    else
        ClearAnalog()
    end

    for i = 1, #NAV_HELD do
        local d = NAV_HELD[i]
        local down = DirectionHeld(d.nav, d.control, stickX, stickY)
        if fresh and down then carried[d.nav] = true end
        if carried[d.nav] then
            -- Held since before the panel: nothing until it is let go.
            if not down then carried[d.nav] = nil end
        elseif down then
            local since = heldSince[d.nav]
            if not since then
                -- First frame down: fire immediately, so a press feels instant.
                heldSince[d.nav] = now
                lastFired[d.nav] = now
                SendNav(d.nav, 0)
            elseif now - since >= REPEAT_DELAY_MS
                and now - (lastFired[d.nav] or 0) >= REPEAT_RATE_MS then
                lastFired[d.nav] = now
                SendNav(d.nav, now - since)
            end
        else
            heldSince[d.nav] = nil
            lastFired[d.nav] = nil
        end
    end

    -- LB first, so the combo state below is this frame's. PadModSync too, in case LB's key binding
    -- does not fire under a panel; told twice, it does nothing the second time.
    local lbDown = IsDisabledControlPressed(0, LB_CONTROL)
    if PadModSync then PadModSync(lbDown, 'panel driver') end
    if lbDown and not lbWasDown then lbPressedHere = true end
    if lbWasDown and not lbDown then
        if lbPressedHere and not WhipPadComboUsed then SendNav('tabPrev') end
        lbPressedHere = false
    end
    lbWasDown = lbDown

    for i = 1, #NAV_PRESS do
        local b = NAV_PRESS[i]
        if IsDisabledControlJustPressed(0, b.control) and not (b.combo and WhipPadModHeld)
            and not PadComboInMenus(b.control) then
            SendNav(b.nav)
        end
    end
end

--- The panel closed: let go of the controls and anything held. The next panel starts again.
local function StopDriver()
    driving, carryNext = false, false
    ControlBlocks.release('padNav')
    ClearAnalog()
    if holdingInput then
        HoldInput(false)
        ResetRepeats()
    end
end

local function DriveHook()
    if not ShouldDrive() then StopDriver() return end
    DriveFrame()
end

local function RunDriver()
    -- A panel taking the pad (not a scope change inside one already driven): its first frame carries what is held
    if not driving then driving, carryNext = true, true end
    ControlBlocks.hold('padNav', DRIVE_BLOCK, DriveHook)
end

-- ============================================
-- Device watch
-- ============================================

CreateThread(function()
    while true do
        -- The slow path, for when no panel is open (the driver calls UpdateDevice every frame):
        -- here only a prompt's glyph depends on it.
        UpdateDevice()          -- which clears the repeat clocks itself on a switch to keyboard
        PublishIfSettled()      -- only this path publishes; the driver only updates the flag
        Wait(200)
    end
end)

-- ============================================
-- NUI callbacks
-- ============================================

--- The browser telling us which panel, if any, can take a pad. See navScope above for why nil
--- from a panel that IS open is both possible and important.
RegisterNUICallback('navScope', function(data, cb)
    navScope = (type(data) == 'table' and type(data.scope) == 'string' and data.scope ~= '')
        and data.scope or nil
    navAnalog = navScope ~= nil and type(data) == 'table' and data.analog == true
    WhipNavScopeOpen = navScope ~= nil   -- kept in step here, the one place navScope is written
    if navScope then RunDriver() else StopDriver() end   -- this frame
    cb('ok')
end)

-- ============================================
-- Seams for the pad overlay (client/controller_debug.lua)
-- ============================================
--
-- The whole chain in one answer: the device native missing, the browser never reporting a scope,
-- the scope nil (the panel has no onNav), or the pad not read all look like "nothing happens".
-- Globals, not exports: one resource.

--- Everything the overlay needs to show about this file's state.
---@return table
function ControllerDebugState()
    return {
        detector   = IsInputDisabled and 'IsInputDisabled(2)'
                  or IsUsingKeyboard and 'IsUsingKeyboard(2)'
                  or nil,          -- nil means NEITHER exists and the bridge is disabled
        padActive  = padActive,
        navScope   = navScope,
        holding    = holdingInput,
        driving    = ShouldDrive(),
    }
end

-- ============================================
-- Seam
-- ============================================

--- Is the player using a gamepad right now?
---
--- Exported: a satellite drawing its own prompt needs to know whether to write "E" or a button glyph.
---@return boolean
local function IsControllerActive()
    return padActive
end

exports('IsControllerActive', IsControllerActive)

-- A satellite's own mode (placing, aiming a tool, a minigame) confirms and cancels the way whip's do:
-- E / A and C / B, never LB + A or LB + B (those are whip's combos). Read them every frame of the mode;
-- they answer for whichever device is in the player's hands. The hints go in UI.ShowText. Any other key of the
-- mode: IsKeyPressed(key, button) / IsKeyHeld / KeyHint, the same rules for a key and a button you name.
exports('IsAcceptPressed', function() return WhipAcceptJustPressed() end)
exports('IsAcceptHeld',    function() return WhipAcceptHeld() end)
exports('AcceptHint',      WhipAcceptHint)
exports('IsCancelPressed', function() return WhipCancelJustPressed() end)
exports('CancelHint',      WhipCancelHint)
exports('IsKeyPressed', function(key, button) return WhipKeyPressed(tonumber(key), tonumber(button)) end)
exports('IsKeyHeld',    function(key, button) return WhipKeyHeld(tonumber(key), tonumber(button)) end)
exports('KeyHint',      function(keyText, button) return WhipKeyHint(keyText, button) end)

-- (SetNuiFocusKeepInput outlives whip_core: client/focus.lua clears it, and the focus, when whip_core
-- stops.)

-- Sent on ready, and again when a character loads: onReady means the client files have run, not
-- that the page is listening (client/ready.lua), and a message sent before html/js/controller.js
-- listens is dropped. By the time a character loads the page is up. Straight to the page, bypassing
-- the settle timer, and recorded as published so the timer does not re-send it.
local function PublishDeviceNow()
    publishedDevice = padActive
    PublishDevice()
    if PadDeviceChanged then PadDeviceChanged(padActive) end
end

AddEventHandler('whip_core:onReady', function(info)
    -- Once per whip_core start, not on every resource that starts after it.
    if type(info) == 'table' and info.reason ~= 'coreStarted' then return end
    PublishDeviceNow()
end)

RegisterNetEvent('whip_core:client:playerLoaded', function() PublishDeviceNow() end)
