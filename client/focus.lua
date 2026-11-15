-- Focus: who holds the NUI focus. The one caller of SetNuiFocus / SetNuiFocusKeepInput in whip_core's client. A screen
-- takes the focus under its own id and releases it, and the natives are set from every hold at once, so one screen
-- closing cannot take the keyboard and cursor from another:
--
--     Focus.take('radial', { screen = true })                 -- cursor on by default
--     Focus.release('radial')
--
-- `screen = true` counts for FocusScreenUp (client/inventory.lua). The newest hold decides the cursor and keep-input;
-- releasing one hands the focus back to whatever still holds it. The pad's keep-input (client/controller.lua) is a
-- layer on top: Focus.padInput(on).
--
-- No cursor while the pad drives the screen: that layer takes the cursor away through SetNuiFocus's hasCursor, since
-- CSS `cursor: none` reaches FiveM as no cursor handle and it puts the default cursor up. Moving the mouse brings the
-- cursor back (the driver lets go). A screen the pad cannot drive (the character creator) never gets here, so it
-- keeps its cursor.

Focus = {}

local holds   = {}      -- [id] = { cursor, keepInput, screen, seq }
local seq     = 0
local padKeep = false
local setKeep = false   -- what was last passed to SetNuiFocusKeepInput

-- A screen opened on a pad waits for the driver before showing a cursor (the driver takes over once the page reports a
-- nav scope). If it has not by PAD_CURSOR_WAIT_MS, the pad cannot drive that screen and the cursor comes on.
local PAD_CURSOR_WAIT_MS = 500
local padWait = 0       -- non-zero: the take this is waiting on (its seq)

local function newest()
    local top
    for _, h in pairs(holds) do
        if not top or h.seq > top.seq then top = h end
    end
    return top
end

--- The cursor the newest hold gets: its own, unless a pad drives the screen or is about to.
local function cursorFor(top)
    return top.cursor and not padKeep and padWait == 0
end

local function apply()
    local top = newest()
    SetNuiFocus(top ~= nil, top ~= nil and cursorFor(top))
    local keep = (top ~= nil and top.keepInput) or padKeep
    if keep ~= setKeep then
        setKeep = keep
        SetNuiFocusKeepInput(keep)
    end
end

--- Take the focus. Taking again under the same id makes it the newest hold with the new options.
---@param id string
---@param opts table|nil  { cursor = true (default), keepInput = false, screen = false }
function Focus.take(id, opts)
    opts = opts or {}
    seq = seq + 1
    holds[id] = { cursor = opts.cursor ~= false, keepInput = opts.keepInput == true, screen = opts.screen == true, seq = seq }
    if holds[id].cursor and not padKeep and WhipPadActive then
        local mine = seq
        padWait = mine
        SetTimeout(PAD_CURSOR_WAIT_MS, function()
            if padWait ~= mine then return end
            padWait = 0
            if newest() ~= nil then apply() end
        end)
    else
        padWait = 0
    end
    apply()
end

-- Turning the camera with the mouse in a screen that has a cursor: while the right button turns the camera, the cursor
-- goes. On Legacy the hold is retaken without the cursor. On Enhanced, setting the focus again drops the held button,
-- so the focus is left alone: the page takes no mouse and wears a see-through cursor (html.whip-mouse-look in
-- css/ui.css), and the cursor is held where the look began.

local lookOn = nil   -- { id, x, y } while a look runs on Enhanced (x, y: where the cursor was, 0 to 1)

local function endLook()
    if not lookOn then return end
    lookOn = nil
    SendNUIMessage({ action = 'mouseLook', on = false })
end

--- The right button went down (on = true) or came up, in the screen holding `id`.
---@param id string  that screen's hold
---@param on boolean
function Focus.mouseLook(id, on)
    local h = holds[id]
    if not h then return end
    if not GamePlatform.enhanced then
        Focus.take(id, { cursor = not on, keepInput = h.keepInput, screen = h.screen })
        return
    end
    if not on then
        if lookOn and lookOn.id == id then endLook() end
        return
    end
    if lookOn then return end
    local w, ht = GetActiveScreenResolution()
    local cx, cy = GetNuiCursorPosition()
    local mine = { id = id, x = (w > 0 and cx) and cx / w or 0.5, y = (ht > 0 and cy) and cy / ht or 0.5 }
    lookOn = mine
    SendNUIMessage({ action = 'mouseLook', on = true })
    CreateThread(function()
        while lookOn == mine do
            SetCursorLocation(mine.x, mine.y)
            Wait(0)
        end
    end)
end

--- Let go: the focus goes to whatever still holds it, or back to the game.
---@param id string
function Focus.release(id)
    if holds[id] == nil then return end
    holds[id] = nil
    if lookOn and lookOn.id == id then endLook() end
    if next(holds) == nil then padWait = 0 end
    apply()
end

--- Let go of every hold: the failsafe (/resetcomposer) for a player stuck under the focus.
function Focus.releaseAll()
    holds = {}
    endLook()
    padWait = 0
    apply()
end

---@param id string
---@return boolean
function Focus.held(id)
    return holds[id] ~= nil
end

--- Is `id` the one hold, with nothing else holding the focus? (Typing into a prompt: its hold is the prompts' own.)
---@param id string
---@return boolean
function Focus.onlyHeld(id)
    if holds[id] == nil then return false end
    for other in pairs(holds) do
        if other ~= id then return false end
    end
    return true
end

--- Set the natives again from the holds, to win back a focus something outside whip_core took (the landing page).
function Focus.reassert()
    apply()
end

--- Is a screen (a hold with `screen`) up, other than `except`?
---@param except string|nil
---@return boolean
function Focus.screenUp(except)
    for id, h in pairs(holds) do
        if h.screen and id ~= except then return true end
    end
    return false
end

--- The pad driving a panel (client/controller.lua) keeps game input and hides the cursor (see the top of this file).
---@param on boolean
function Focus.padInput(on)
    on = on == true
    if on == padKeep then return end
    padKeep = on
    padWait = 0
    local top = newest()
    if top ~= nil then SetNuiFocus(true, cursorFor(top)) end
    local keep = (top ~= nil and top.keepInput) or padKeep
    if keep ~= setKeep then
        setKeep = keep
        SetNuiFocusKeepInput(keep)
    end
end

-- Hand the focus back on stop, or the player cannot move.
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    holds, padKeep, setKeep = {}, false, false
    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(false)
end)
