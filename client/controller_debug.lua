-- ============================================
-- PAD OVERLAY — /paddebug
-- ============================================
--
-- Controller input passes through four layers (a physical button, a GTA control ID, whip's read,
-- then an action), and every layer fails the same way: nothing happens. This draws the whole chain
-- live: which controls are down, which button each one is on a pad, which whip has claimed and for
-- what, and a running log of the actions that actually fired.
--
-- It is for the collisions: two control IDs can be the same physical button (A is both INPUT_SPRINT
-- 21 and INPUT_FRONTEND_ACCEPT 201; LB is both INPUT_PICKUP 38 and INPUT_FRONTEND_LB 205).
--
-- No NUI focus, ever: a read-only HUD (pointer events off in CSS), so it stays up while you drive,
-- fight and open panels, and taking focus would change the input being debugged.
--
-- Client-side and ungated, like /radar: it reads this client's own input and changes nothing.

local open = false

-- ============================================
-- What to watch
-- ============================================

--- Every row carries both bindings: a control is one abstract action the engine wires to a key AND
--- a button.
---
---     14 / 15 are the scroll wheel on a keyboard; on a pad they are D-pad right/left AND the
---     TRIGGERS (pulling RT fires 14, LT fires 15).
---     189 / 190 are the arrow keys on a keyboard, and on a pad D-pad left/right and nothing else.
---
--- So the wheel is read on 16/17 (SELECT_NEXT/PREV_WEAPON, no pad binding at all); 14/15 are still
--- DISABLED wherever a wheel is used (silenced everywhere, read nowhere), or they switch the player's
--- weapon on a keyboard. The rows below check that it stays that way.
---
--- `claim` is whip's own use of that control, or nil for one the framework does not read. Those are
--- still listed: a row that stays dark says the press produced NOTHING.
---
--- `pad` and `kb` are what the control is on each device, as GTA ships it. A blank means that
--- device has no binding for it — which is the most valuable cell in the table, because a scroll
--- control with an EMPTY pad column is a scroll control that cannot be fired by a trigger.
local GROUPS = {
    {
        title = 'Face buttons',
        rows = {
            { control = 201, pad = 'A', kb = 'Enter', name = 'FRONTEND_ACCEPT', claim = "interact: select · modes' E on a pad · LB+A: TALK (never A)" },
            { control = 21,  pad = 'A', kb = 'LShift', name = 'SPRINT',         claim = 'held off by the pad reader (not with SprintOnA): sprint is the L3 double click' },
            { control = 22,  pad = 'X', kb = 'Space', name = 'JUMP',            claim = 'held off only while LB + X holds something' },
            { control = 202, pad = 'B', kb = 'Bksp',  name = 'FRONTEND_CANCEL', claim = 'panel nav: back' },
            { control = 203, pad = 'X', kb = 'Space', name = 'FRONTEND_X',      claim = 'panel nav: buttonX · LB+X: RADIO' },
            { control = 204, pad = 'Y', kb = 'Tab',   name = 'FRONTEND_Y',      claim = 'panel nav: buttonY' },
        },
    },
    {
        title = 'D-pad — CLEAN (no trigger)',
        rows = {
            { control = 188, pad = 'D-Up',    kb = 'Up',    name = 'FRONTEND_UP',    claim = 'panel nav: up · prompt: option up (no panel)' },
            { control = 187, pad = 'D-Down',  kb = 'Down',  name = 'FRONTEND_DOWN',  claim = 'panel nav: down · prompt: option down · HOLD: radial (no panel)' },
            { control = 189, pad = 'D-Left',  kb = 'Left',  name = 'FRONTEND_LEFT',  claim = 'panel nav: left · vehicle: ENGINE TOGGLE (pad, no panel)' },
            { control = 190, pad = 'D-Right', kb = 'Right', name = 'FRONTEND_RIGHT', claim = 'panel nav: right · INVENTORY (no panel)' },
        },
    },
    {
        title = 'Scroll — IN USE (no pad binding)',
        rows = {
            { control = 17, pad = '', kb = 'Wheel up',   name = 'SELECT_PREV_WEAPON', claim = 'interact: option up · vehicle: engine ON · rotate left' },
            { control = 16, pad = '', kb = 'Wheel down', name = 'SELECT_NEXT_WEAPON', claim = 'interact: option down · vehicle: engine OFF · rotate right' },
        },
    },
    {
        title = 'Scroll — RETIRED, contaminated by triggers',
        rows = {
            { control = 15, pad = 'D-Left  + LT', kb = 'Wheel up',   name = 'WEAPON_WHEEL_PREV', claim = 'silenced everywhere, read nowhere' },
            { control = 14, pad = 'D-Right + RT', kb = 'Wheel down', name = 'WEAPON_WHEEL_NEXT', claim = 'silenced everywhere, read nowhere' },
        },
    },
    {
        title = 'Scroll — other candidates, unverified',
        rows = {
            { control = 180, pad = '', kb = 'Wheel down', name = 'CELLPHONE_SCROLL_FWD',    claim = nil },
            { control = 181, pad = '', kb = 'Wheel up',   name = 'CELLPHONE_SCROLL_BACK',   claim = nil },
            { control = 241, pad = '', kb = 'Wheel up',   name = 'CURSOR_SCROLL_UP',        claim = nil },
            { control = 242, pad = '', kb = 'Wheel down', name = 'CURSOR_SCROLL_DOWN',      claim = nil },
            { control = 99,  pad = '', kb = 'Wheel down', name = 'VEH_SELECT_NEXT_WEAPON',  claim = nil },
            { control = 100, pad = '', kb = 'Wheel up',   name = 'VEH_SELECT_PREV_WEAPON',  claim = nil },
        },
    },
    {
        title = 'Shoulders and triggers',
        rows = {
            { control = 38,  pad = 'LB', kb = 'E',      name = 'PICKUP',      claim = "modes' E (respawn, place, give, emote place): keyboard only; nothing on a pad" },
            { control = 205, pad = 'LB', kb = 'Q',      name = 'FRONTEND_LB', claim = 'COMBO KEY · panel nav: tabPrev (on release, no combo)' },
            { control = 206, pad = 'RB', kb = 'E',      name = 'FRONTEND_RB', claim = 'panel nav: tabNext' },
            { control = 207, pad = 'LT', kb = 'PgDn',   name = 'FRONTEND_LT', claim = nil },
            { control = 208, pad = 'RT', kb = 'PgUp',   name = 'FRONTEND_RT', claim = nil },
        },
    },
    {
        title = 'Sticks and menu',
        rows = {
            { control = 36,  pad = 'L3',    kb = 'LCtrl',  name = 'DUCK',            claim = "GTA's sneak: held off on a pad" },
            { control = 209, pad = 'L3',    kb = 'LShift', name = 'FRONTEND_LS',     claim = 'once: JOG, twice: SPRINT, until the stick is centred' },
            { control = 210, pad = 'R3',    kb = 'LCtrl',  name = 'FRONTEND_RS',     claim = nil },
            { control = 199, pad = 'Start', kb = 'P',      name = 'FRONTEND_PAUSE',  claim = nil },
            { control = 217, pad = 'Back',  kb = 'Caps',   name = 'FRONTEND_SELECT', claim = nil },
        },
    },
    {
        title = 'Mouse',
        rows = {
            { control = 24,  pad = 'RT', kb = 'LMB', name = 'ATTACK',        claim = nil },
            { control = 25,  pad = 'LT', kb = 'RMB', name = 'AIM',           claim = nil },
            { control = 329, pad = '',   kb = 'MMB', name = 'CURSOR_ACCEPT', claim = nil },
            { control = 330, pad = '',   kb = 'RMB', name = 'CURSOR_CANCEL', claim = nil },
        },
    },
    {
        title = "Keyboard — whip's own claimed keys",
        rows = {
            { control = 200, pad = '', kb = 'Esc', name = 'FRONTEND_PAUSE_ALT', claim = 'atm / housing: cancel' },
            { control = 26,  pad = '', kb = 'C',   name = 'LOOK_BEHIND',        claim = 'atm / housing / placing / inventory: cancel' },
        },
    },
}

--- The analog inputs, drawn as bars rather than lights.
---
--- TRIGGERS ARE SLIDERS AND THE BUTTON LIST LIES ABOUT THEM. A row in GROUPS above can only say
--- down or up, but a trigger has a position — and GTA's own digital reading of one flips at
--- HALF TRAVEL (the docs say so explicitly of L2_INDEX/R2_INDEX: "considered pressed half way
--- through the travel"). So a trigger appears here as well as there, deliberately: the bar shows
--- where it actually is, the row shows where the game decided to call it pressed, and seeing both
--- at once is the only way to understand a half-pull doing something a full pull does not.
---
--- `mark` draws that threshold on the bar.
---
--- SEVERAL CONTROLS PER PHYSICAL TRIGGER, because which one reports travel depends on context and
--- on the build: 207/208 are the frontend pair, 24/25 are attack and aim on foot, 71/72 are
--- throttle and brake in a vehicle. Listing them together is not indecision — it is the answer to
--- "which control is my trigger actually on right now", which changes as you get in and out of a
--- car and is not something this file can know in advance.
local AXIS_GROUPS = {
    {
        title = 'Sticks',
        range = 'bipolar',
        rows = {
            { control = 195, label = 'Left X' },
            { control = 196, label = 'Left Y' },
            { control = 197, label = 'Right X' },
            { control = 198, label = 'Right Y' },
        },
    },
    {
        title = 'Triggers',
        range = 'unipolar',
        mark  = 0.5,
        rows = {
            { control = 207, label = 'LT frontend' },
            { control = 208, label = 'RT frontend' },
            { control = 25,  label = 'LT aim' },
            { control = 24,  label = 'RT attack' },
            { control = 72,  label = 'LT brake' },
            { control = 71,  label = 'RT throttle' },
        },
    },
}

-- ============================================
-- Reading
-- ============================================

--- Is this control down, whether or not something has disabled it?
---
--- BOTH READERS, and that is not belt-and-braces. While a panel is open the bridge disables every
--- gameplay control, and the plain reader reports a disabled control as up — so an overlay using
--- only IsControlPressed would go completely dark at exactly the moment the bridge is doing its
--- work. Reading both means one row means "the button is down", in every state whip can be in.
---@param control number
---@return boolean
local function ControlDown(control)
    return IsControlPressed(0, control) or IsDisabledControlPressed(0, control)
end

--- Same reasoning for the analog axes: disabled axes read 0.0 through the plain accessor.
---@param control number
---@return number
local function AxisValue(control)
    local v = GetDisabledControlNormal(0, control)
    if v == 0.0 then v = GetControlNormal(0, control) end
    return v
end

-- ============================================
-- The action log
-- ============================================

--- Recent actions, newest last. Bounded — this is a live tail, not a transcript, and an unbounded
--- table behind a per-frame producer is a leak with extra steps.
local LOG_MAX = 14
local logLines, logSeq = {}, 0

--- Called by the rest of whip when something actually fires. GLOBAL AND ONLY DEFINED WHILE OPEN:
--- client/controller.lua nil-checks it, so when the overlay is shut the announcement costs one
--- comparison. That is what makes it safe to call from inside a per-frame path.
---@param source string
---@param label string
---@param detail? string
local function Fire(source, label, detail)
    -- And in F8: the overlay keeps 14 lines; F8 keeps the lot, in order with the
    -- "game saw" lines below, so a press that did nothing shows exactly where it stopped.
    print(('[whip_core:pad] %-8s %s%s'):format(source, label, detail ~= nil and ('  -> ' .. tostring(detail)) or ''))
    logSeq = logSeq + 1
    logLines[#logLines + 1] = {
        seq = logSeq, source = source, label = label, detail = detail,
        at = GetGameTimer(),
    }
    while #logLines > LOG_MAX do table.remove(logLines, 1) end
end

-- ============================================
-- Sending
-- ============================================

--- Build the static half once, so the per-frame message carries only what moves.
local function SendLayout()
    SendNUIMessage({ action = 'padDebugOpen', groups = GROUPS, axisGroups = AXIS_GROUPS })
end

--- Every analog control, flattened in the order the NUI will draw them, so the per-frame message
--- can be a bare array of numbers rather than repeating the control ids sixty times a second.
--- Built once at load: the layout never changes.
local AXIS_ORDER = {}
for gi = 1, #AXIS_GROUPS do
    local rows = AXIS_GROUPS[gi].rows
    for ri = 1, #rows do AXIS_ORDER[#AXIS_ORDER + 1] = rows[ri].control end
end

--- Quantise an axis before comparing. A stick at rest jitters in the far decimals forever; without
--- this the change check below would find a change every single frame and the overlay would send
--- sixty messages a second while nobody touched anything.
local function Q(v)
    return math.floor(v * 40 + 0.5) / 40
end

local lastSig, lastSeq = nil, 0

--- True while the overlay's send loop is alive, so opening twice cannot start two of them.
local overlayThreadRunning = false

--- Born with the overlay, not with the client (debug tooling is where idle cost hides). The loop
--- condition is the flag SetOpen maintains, so closing the overlay stops the thread.
local function StartOverlayThread()
    if overlayThreadRunning then return end
    overlayThreadRunning = true

    CreateThread(function()
        local wasDown = {}
        while open do
            local down, sig = {}, {}
            local saw, sawOrder = nil, nil   -- [pad label] = 'id NAME, ...' for controls that went down now

            for gi = 1, #GROUPS do
                local rows = GROUPS[gi].rows
                for ri = 1, #rows do
                    local row = rows[ri]
                    if ControlDown(row.control) then
                        down[#down + 1] = row.control
                        sig[#sig + 1] = row.control
                        if not wasDown[row.control] then
                            wasDown[row.control] = true
                            local label = row.pad ~= '' and row.pad or ('kb ' .. row.kb)
                            saw, sawOrder = saw or {}, sawOrder or {}
                            if not saw[label] then sawOrder[#sawOrder + 1] = label end
                            saw[label] = (saw[label] and (saw[label] .. ', ') or '') .. row.control .. ' ' .. row.name
                        end
                    else
                        wasDown[row.control] = nil
                    end
                end
            end

            -- "THE GAME SAW IT", one line per button, in F8 — the half the bindings' own lines
            -- cannot give: a press the game saw and no binding answered is a binding that did not fire.
            if saw then
                ---@cast sawOrder -nil   -- (made with saw)
                for i = 1, #sawOrder do
                    print(('[whip_core:pad] game saw %s  (%s)'):format(sawOrder[i], saw[sawOrder[i]]))
                end
            end

            local axes = {}
            for i = 1, #AXIS_ORDER do
                axes[i] = Q(AxisValue(AXIS_ORDER[i]))
                sig[#sig + 1] = axes[i]
            end

            local st = ControllerDebugState()
            sig[#sig + 1] = tostring(st.padActive)
            sig[#sig + 1] = st.navScope or '-'
            sig[#sig + 1] = tostring(st.holding)

            -- ONLY ON CHANGE, plus whenever the log has grown. Holding a button steady is the
            -- normal case while debugging and it should cost nothing.
            local nowSig = table.concat(sig, ',')
            if nowSig ~= lastSig or logSeq ~= lastSeq then
                lastSig, lastSeq = nowSig, logSeq
                SendNUIMessage({
                    action = 'padDebugState',
                    down   = down,
                    axes   = axes,
                    status = st,
                    log    = logLines,
                })
            end

            Wait(0)
        end

        overlayThreadRunning = false
    end)
end

-- ============================================
-- The opening dump (F8)
-- ============================================

--- What is in the way of a press, all at once: the device, the panel, the NUI focus and every
--- control block — 'padRead' among them is client/pad.lua reading the pad (only while it is the
--- device). The pad does not use FiveM key bindings (they never fired from a pad).
local function DumpState()
    local st = ControllerDebugState()
    print(('[whip_core:pad] ---- detector %s | pad active %s | panel scope %s | driving %s | NUI focused %s'):format(
        tostring(st.detector), tostring(st.padActive), tostring(st.navScope), tostring(st.driving),
        tostring(IsNuiFocused())))
    local blocks = ControlBlocks.describe()
    if #blocks == 0 then print('[whip_core:pad] control blocks: none') end
    for _, line in ipairs(blocks) do print('[whip_core:pad] control block ' .. line) end
    print('[whip_core:pad] ---- now press buttons: "game saw" = GTA got it, "pad" = whip read it and what it ran')
end

-- ============================================
-- The command
-- ============================================

local function SetOpen(want)
    open = want

    -- The hook is the global's EXISTENCE, not a flag it reads — see Fire above.
    WhipPadDebugFire = want and Fire or nil

    if want then
        logLines, logSeq, lastSig, lastSeq = {}, 0, nil, 0
        DumpState()
        SendLayout()
        -- AFTER `open` is set above, because the thread's loop condition IS that flag — starting
        -- it any earlier would have it read false and exit on the spot.
        StartOverlayThread()
    else
        -- Clearing `open` above is also how the thread is stopped: it exits on its next wake and
        -- clears overlayThreadRunning on the way out. Nothing here has to know it exists.
        SendNUIMessage({ action = 'padDebugClose' })
    end
end

DevCommand('paddebug', function()
    SetOpen(not open)
    print(('[whip_core:pad] overlay %s'):format(open and 'OPEN' or 'CLOSED'))
end)

--- Shut it if the resource stops, so a restart mid-session cannot leave a dead overlay drawn over
--- the screen with nothing left to clear it.
AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() and open then SetOpen(false) end
end)
