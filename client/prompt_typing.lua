-- ============================================
-- PROMPT TYPING — typing a value into a 3D prompt (Interactions.beginInput)
-- ============================================
--
-- A prompt that asks for a value (the ATM's amount, a speaker's volume, a conversation's answer) does not take the
-- keys into its own label. When typing begins:
--
--   ON A KEYBOARD  a capsule in the chat capsule's look stands where the prompt was, saying "Start typing". The keys
--                  go to it: whip's page holds the keyboard (NUI focus, no cursor) and the game keeps its input, so
--                  the mouse still looks round while every other control is held off. Enter gives it, Esc (or
--                  Backspace on nothing) leaves it.
--   ON A PAD       whip's on-screen keyboard stands there in 3D. The left stick moves a circle over the keys (the
--                  inventory's: it slows over a key), the D-pad steps key to key, A types the key under it; X deletes,
--                  Y is a space, LT turns to the symbols, RB or Done gives it, B or Cancel leaves it. The right stick
--                  still looks round; walking and the rest are held off while it is up. LB is left alone: it is
--                  whip's combo key, and LB + A talks even here.
--
-- Swapping device while typing swaps the two, keeping what was typed. Both are painted by one browser
-- (html/interact3d/typing.html) and drawn as one quad (WorldQuad), placed and turned to face the camera as typing
-- begins and left there: looking round leaves it where it stands. A DUI cannot answer, so the keys, the text, the
-- highlight and the circle all live here and the page only paints what it is sent.
--
-- interact.lua owns what typing means (which prompt, onSubmit, onCancel); this file owns the keys, the browser and
-- the quad, and says what happened through the session's onChange / onDone / onCancel.

PromptTyping = {}

local HOLD  = 'promptTyping'   -- the focus hold (keyboard) and the control block (both)
local TXD, TEX = 'whip_typing_txd', 'typing'
local PAGE_W, PAGE_H = 1024, 640

-- The part of the page each look takes, in its pixels (the page lays itself out to the same numbers): the quad
-- draws only that part.
local RECT = {
    capsule = { w = 1024, h = 160 },
    keys    = { w = 1024, h = 640 },
    numpad  = { w = 560,  h = 640 },
}
-- How wide each looks on a 1440p screen, worked into metres at the quad's distance (as Config.Interact3D's figures).
local SCREEN_PX = { capsule = 640, keys = 1000, numpad = 560 }
local REFERENCE_H = 1440.0

-- The keyboard's key area inside the page (px): the circle and the hit test work in it, 0..1 each way.
local KEY_AREA = {
    keys   = { x = 28, y = 172, w = 968, h = 380 },
    numpad = { x = 28, y = 172, w = 504, h = 380 },
}

-- The circle, as the inventory's and pad-cursor.js's: a full push moves it this many key-area heights a second, a
-- light push slower (push ^ CURVE), and over a key (always, here) at SLOW of that.
local SPEED, CURVE, SLOW, DEAD = 3.0, 1.6, 0.45, 0.18
-- A held D-pad direction: the pause before it repeats, and how often after (client/controller.lua's).
local REPEAT_DELAY, REPEAT_RATE = 380, 110
-- Half the gap between two keys, as a share of the key area's width (the page's 5 px of 968).
local GAP = 0.005

-- ---- the keys (html/js/pad-keyboard.js's, in English) ----

local NUMBER_ROW = { '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-' }
local LETTERS = {
    { 'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', "'" },
    { 'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', '.', ',' },
    { 'z', 'x', 'c', 'v', 'b', 'n', 'm', '?', '!' },
}
local SYMBOLS = {
    { '/', '@', '#', '$', '%', '&', '*', '(', ')', '_', '=' },
    { '+', ':', ';', '"', "'", '[', ']', '{', '}', '<', '>' },
    { '~', '`', '^', '\\', '|', '£', '.', ',', '?', '!', 'back' },
}
local BOTTOM = { 'symbols', 'cancel', 'space', 'done' }
-- A number: digits only (an amount, a volume), so no minus or point; Done the whole last row.
local NUMPAD = {
    { '7', '8', '9' }, { '4', '5', '6' }, { '1', '2', '3' }, { 'cancel', '0', 'back' }, { 'done' },
}
local NAMED = {
    shift = { label = 'Caps' }, back = { label = '⌫' }, symbols = { label = 'Symbols', span = 2 },
    cancel = { label = 'Cancel', span = 2 }, space = { label = 'Space' }, done = { label = 'Done', span = 3 },
}

local s = nil     -- the session, or nil
local gen = 0     -- a new number each session: a late answer for an old one is dropped

local page = DuiPage.new({
    name = 'typing', url = 'interact3d/typing.html', width = PAGE_W, height = PAGE_H, txd = TXD, tex = TEX,
    idleMs = 60000, without = 'typing into a prompt draws nothing (the keys still work)',
})

-- ---- text ----

local function len(t) return utf8.len(t) or #t end

--- Cut to `max` characters (a whole character, never half of one).
local function cut(t, max)
    if not max or len(t) <= max then return t end
    local stop = utf8.offset(t, max + 1)
    return stop and t:sub(1, stop - 1) or t
end

--- What a session may hold: a number's digits (no leading zeros), else the text, cut to its length.
local function clean(sess, t)
    t = tostring(t or '')
    if sess.numeric then t = t:gsub('%D', ''):gsub('^0+(%d)', '%1') end
    return cut(t, sess.max)
end

-- ---- the keyboard's keys and where they are ----

local function rowsOf(sess)
    if sess.numeric then return NUMPAD end
    if sess.symbols then return { NUMBER_ROW, SYMBOLS[1], SYMBOLS[2], SYMBOLS[3], BOTTOM } end
    local third = { 'shift' }
    for _, k in ipairs(LETTERS[3]) do third[#third + 1] = k end
    third[#third + 1] = 'back'
    return { NUMBER_ROW, LETTERS[1], LETTERS[2], third, BOTTOM }
end

--- How many columns a key takes: Space what its row leaves, a named key its own, a letter one. On the number pad,
--- Done takes the row.
local function spanOf(k, row, cols)
    if #row == 1 then return cols end
    if k == 'space' then
        local used = 0
        for _, o in ipairs(row) do
            if o ~= 'space' then used = used + ((NAMED[o] and NAMED[o].span) or 1) end
        end
        return cols - used
    end
    return (NAMED[k] and NAMED[k].span) or 1
end

--- Every key with its box in the key area (0..1 each way). Kept on the session until the page turns.
local function layoutOf(sess)
    local rows = rowsOf(sess)
    local cols = sess.numeric and 3 or 11
    local keys = {}
    for r, row in ipairs(rows) do
        local c = 0
        for _, k in ipairs(row) do
            local span = sess.numeric and (#row == 1 and cols or 1) or spanOf(k, row, cols)
            keys[#keys + 1] = { k = k, row = r, span = span,
                x0 = c / cols, x1 = (c + span) / cols, y0 = (r - 1) / #rows, y1 = r / #rows }
            c = c + span
        end
    end
    return { keys = keys, rows = rows, cols = cols }
end

local function keyNamed(sess, k)
    for _, key in ipairs(sess.layout.keys) do
        if key.k == k then return key end
    end
    return nil
end

local function centre(key) return (key.x0 + key.x1) / 2, (key.y0 + key.y1) / 2 end

--- The key under a point of the key area (the nearest one, for a point in a gap or past the edge).
local function keyAt(sess, x, y)
    local best, bestD = nil, math.huge
    for _, key in ipairs(sess.layout.keys) do
        if x >= key.x0 and x <= key.x1 and y >= key.y0 and y <= key.y1 then return key end
        local cx, cy = centre(key)
        local d = (cx - x) ^ 2 + (cy - y) ^ 2
        if d < bestD then best, bestD = key, d end
    end
    return best
end

--- The nearest key that way (pad-keyboard.js's step): distance that way, plus three times how far off to the side;
--- left and right stay on the row and go round its ends.
local function stepFrom(sess, key, dir)
    local ax, ay = centre(key)
    local best, bestScore = nil, math.huge
    for _, b in ipairs(sess.layout.keys) do
        if b ~= key then
            local bx, by = centre(b)
            local along, across
            if dir == 'up' or dir == 'down' then
                if (dir == 'down' and by > ay + 1e-6) or (dir == 'up' and by < ay - 1e-6) then
                    along = math.abs(by - ay)
                    -- With the gap between keys (GAP), as the page draws them: a key that only touches this
                    -- one's edge is off to the side, one under it is not (from v, down is Space, not Cancel).
                    across = math.max(0, math.max(key.x0, b.x0) - math.min(key.x1, b.x1) + 2 * GAP)
                end
            elseif b.row == key.row then
                if (dir == 'right' and bx > ax + 1e-6) or (dir == 'left' and bx < ax - 1e-6) then
                    along, across = math.abs(bx - ax), 0
                end
            end
            if along then
                local score = along + across * 3
                if score < bestScore then best, bestScore = b, score end
            end
        end
    end
    if not best and (dir == 'left' or dir == 'right') then
        local row = {}
        for _, b in ipairs(sess.layout.keys) do if b.row == key.row then row[#row + 1] = b end end
        best = dir == 'right' and row[1] or row[#row]
    end
    return best
end

-- ---- the page ----

local function keyLabel(sess, k)
    if k == 'symbols' then return sess.symbols and 'ABC' or 'Symbols' end
    if NAMED[k] then return NAMED[k].label end
    return sess.caps and k:upper() or k
end

local PAD_HINTS_TEXT = { { 'a', 'Type' }, { 'x', 'Delete' }, { 'y', 'Space' }, { 'lt', 'Symbols' }, { 'rb', 'Done' }, { 'b', 'Cancel' } }
local PAD_HINTS_SYMBOLS = { { 'a', 'Type' }, { 'x', 'Delete' }, { 'y', 'Space' }, { 'lt', 'Letters' }, { 'rb', 'Done' }, { 'b', 'Cancel' } }
local PAD_HINTS_NUMBER = { { 'a', 'Type' }, { 'x', 'Delete' }, { 'rb', 'Done' }, { 'b', 'Cancel' } }

--- What the page shows, all of it.
local function paint(sess)
    local msg = {
        look = sess.look, title = sess.title, icon = sess.icon, prefix = sess.prefix, text = sess.text,
        placeholder = sess.placeholder, commas = sess.commas, max = sess.max,
    }
    if sess.look ~= 'capsule' then
        local keys = {}
        for i, key in ipairs(sess.layout.keys) do
            keys[i] = { k = key.k, label = keyLabel(sess, key.k), x0 = key.x0, x1 = key.x1, y0 = key.y0, y1 = key.y1,
                        named = NAMED[key.k] ~= nil, on = key.k == 'shift' and sess.caps or nil }
        end
        msg.keys = keys
        msg.area = KEY_AREA[sess.look]
        msg.focus = sess.focus
        msg.circle = { x = sess.cx, y = sess.cy }
        msg.hints = sess.numeric and PAD_HINTS_NUMBER or (sess.symbols and PAD_HINTS_SYMBOLS or PAD_HINTS_TEXT)
    end
    page:send(msg, 'state')
end

--- The circle and the highlight only (sent as the circle moves).
local function paintCursor(sess)
    page:send({ cursor = true, focus = sess.focus, circle = { x = sess.cx, y = sess.cy } }, 'cursor')
end

-- ---- where it stands ----

--- Placed once, facing the camera as typing begins (and again when the look changes size): looking round leaves it.
local function place(sess)
    local ax, ay, az = sess.anchor()
    if not ax then return false end
    local cam = GetFinalRenderedCamCoord()
    local dx, dy, dz = cam.x - ax, cam.y - ay, cam.z - az
    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
    if dist < 0.05 then dist = 0.05 end
    local nx, ny, nz = dx / dist, dy / dist, dz / dist
    -- Toward the camera, off whatever the prompt is on (an ATM's face, a wall): never past half the way.
    local pull = math.min(0.3, dist * 0.4)
    local qd = dist - pull
    local fov = GetFinalRenderedCamFov()
    if not fov or fov <= 0 then fov = 50.0 end
    local rect = RECT[sess.look]
    local w = (SCREEN_PX[sess.look] / REFERENCE_H) * 2.0 * qd * math.tan(math.rad(fov) * 0.5)
    local h = w * rect.h / rect.w
    local rx, ry, rz, ux, uy, uz = WorldQuad.billboardBasis()
    local cx, cy, cz = ax + nx * pull, ay + ny * pull, az + nz * pull
    -- `hang`: under the anchor (a conversation's keyboard, below what the NPC says) rather than on it.
    if sess.hang and sess.look ~= 'capsule' then
        local drop = h * 0.5 + 0.04
        cx, cy, cz = cx - ux * drop, cy - uy * drop, cz - uz * drop
    end
    sess.quad = { cx = cx, cy = cy, cz = cz, rx = rx, ry = ry, rz = rz, ux = ux, uy = uy, uz = uz, w = w, h = h,
                  u1 = rect.w / PAGE_W, v1 = rect.h / PAGE_H }
    return true
end

local function draw(sess)
    if sess.look == 'capsule' and not sess.capsule then return end
    -- Not placed yet (its anchor had no answer as typing began: a dialog not yet drawn): placed when it has one.
    if not sess.quad and not place(sess) then return end
    local q = sess.quad
    page:used()
    if not page:up() then return end
    WorldQuad.draw(TXD, TEX, q.cx, q.cy, q.cz, q.rx, q.ry, q.rz, q.ux, q.uy, q.uz, q.w, q.h,
        0.0, 0.0, q.u1, q.v1, 255, 255, 255, 255)
end

-- ---- what a key does ----

local function changed(sess)
    if sess.onChange then
        local ok, err = pcall(sess.onChange, sess.text)
        if not ok then print('[whip_core:typing] onChange threw: ' .. tostring(err)) end
    end
end

--- Set the text (from the page, a key, or the caller), and paint it.
local function setText(sess, t, fromPage)
    t = clean(sess, t)
    if t == sess.text then return end
    sess.text = t
    -- The keyboard's page keeps its own copy while it has the keys: a change from here goes to it.
    if sess.look == 'capsule' and not fromPage then
        SendNUIMessage({ action = 'promptTypingSet', id = sess.gen, text = t })
    end
    paint(sess)
    changed(sess)
end

local finish   -- below

local function typeChar(sess, ch)
    if sess.max and len(sess.text) >= sess.max then return end
    -- A number has no leading zero.
    if sess.numeric and ch == '0' and sess.text == '' then return end
    setText(sess, sess.text .. ch)
end

local function erase(sess)
    if sess.text == '' then return end
    local last = utf8.offset(sess.text, -1)
    setText(sess, last and sess.text:sub(1, last - 1) or '')
end

--- Letters ⇄ symbols, the highlight kept at the same row and column.
local function flipPage(sess)
    if sess.numeric then return end
    local from = keyNamed(sess, sess.focus)
    sess.symbols = not sess.symbols
    sess.layout = layoutOf(sess)
    if from then
        local row = sess.layout.rows[from.row]
        local idx = 1
        for i, k in ipairs(rowsOf({ symbols = not sess.symbols, numeric = false })[from.row]) do
            if k == from.k then idx = i break end
        end
        sess.focus = row[math.min(idx, #row)]
    end
    paint(sess)
end

local function press(sess, k)
    if k == 'shift' then sess.caps = not sess.caps; paint(sess)
    elseif k == 'back' then erase(sess)
    elseif k == 'space' then typeChar(sess, ' ')
    elseif k == 'symbols' then flipPage(sess)
    elseif k == 'done' then finish(true)
    elseif k == 'cancel' then finish(false)
    else typeChar(sess, sess.caps and k:upper() or k) end
end

-- ---- the two looks ----

--- What the session uses its keys with: the keyboard (`capsule`) or the pad (`keys`, or `numpad` for a number).
local function lookFor(sess, pad)
    if not pad then return 'capsule' end
    return sess.numeric and 'numpad' or 'keys'
end

--- Every control held off but looking round; Esc and the pause key named, so the pause menu stays shut (Esc is
--- this typing's, the page's on a keyboard).
local function holdControls()
    ControlBlocks.hold(HOLD, { all = true, except = { 1, 2 }, controls = { 199, 200 } })
end

local function enter(sess, pad)
    sess.look = lookFor(sess, pad)
    if sess.look == 'capsule' then
        Focus.take(HOLD, { cursor = false, keepInput = true })
        SendNUIMessage({ action = 'promptTypingOpen', id = sess.gen, numeric = sess.numeric, max = sess.max,
                         text = sess.text })
    else
        Focus.release(HOLD)
        SendNUIMessage({ action = 'promptTypingClose' })
        sess.layout = layoutOf(sess)
        local first = keyNamed(sess, sess.focus) or keyNamed(sess, sess.numeric and '1' or 'q')
        sess.focus = first.k
        sess.cx, sess.cy = centre(first)
        sess.dir, sess.dirSince, sess.dirFired = nil, 0, 0
        -- A press already down as it opened (the A that chose the option) is not a key.
        sess.armedAt = GetGameTimer() + 200
    end
    holdControls()
    place(sess)
    paint(sess)
end

-- ---- the pad ----

local DPAD = { up = 188, down = 187, left = 189, right = 190 }

local function padFrame(sess, now, dt)
    -- The left stick moves the circle; the highlight is the key under it.
    local lx, ly = GetDisabledControlNormal(0, 30), GetDisabledControlNormal(0, 31)
    local mag = math.sqrt(lx * lx + ly * ly)
    if mag > DEAD then
        local push = math.min(1.0, (mag - DEAD) / (1.0 - DEAD))
        local v = SPEED * (push ^ CURVE) * SLOW * dt
        local area = KEY_AREA[sess.look]
        local aspect = area.w / area.h
        sess.cx = math.max(0.0, math.min(1.0, sess.cx + (lx / mag) * v / aspect))
        sess.cy = math.max(0.0, math.min(1.0, sess.cy + (ly / mag) * v))
        local key = keyAt(sess, sess.cx, sess.cy)
        if key then sess.focus = key.k end
        paintCursor(sess)
    end

    -- The D-pad steps key to key, held to repeat, and the circle goes with it.
    local dir = nil
    for d, c in pairs(DPAD) do
        if IsDisabledControlPressed(0, c) then dir = d break end
    end
    if dir ~= sess.dir then
        sess.dir, sess.dirSince, sess.dirFired = dir, now, now
    elseif dir and now - sess.dirSince >= REPEAT_DELAY and now - sess.dirFired >= REPEAT_RATE then
        sess.dirFired = now
    else
        dir = nil
    end
    if dir then
        local from = keyNamed(sess, sess.focus) or sess.layout.keys[1]
        local to = stepFrom(sess, from, dir)
        if to then
            sess.focus = to.k
            sess.cx, sess.cy = centre(to)
            paintCursor(sess)
        end
    end

    if now < sess.armedAt then return end
    if IsDisabledControlJustPressed(0, 201) then press(sess, sess.focus)                         -- A
    elseif IsDisabledControlJustPressed(0, 202) then finish(false)                              -- B
    elseif IsDisabledControlJustPressed(0, 203) then erase(sess)                                -- X
    elseif IsDisabledControlJustPressed(0, 204) then if not sess.numeric then typeChar(sess, ' ') end   -- Y
    elseif IsDisabledControlJustPressed(0, 206) then finish(true)                               -- RB
    elseif IsDisabledControlJustPressed(0, 207) then flipPage(sess) end                         -- LT
end

-- ---- the session ----

local function release()
    Focus.release(HOLD)
    ControlBlocks.release(HOLD)
    SendNUIMessage({ action = 'promptTypingClose' })
    page:send({ look = 'off' }, 'state')
end

--- End it: Done (`keep`, onDone gets the text) or Cancel (onCancel).
function finish(keep)
    local sess = s
    if not sess then return end
    s = nil
    release()
    local fn = keep and sess.onDone or sess.onCancel
    if fn then
        local ok, err = pcall(fn, sess.text)
        if not ok then print(('[whip_core:typing] %s threw: %s'):format(keep and 'onDone' or 'onCancel', tostring(err))) end
    end
end

--- Begin typing. `spec`:
---   anchor()        -> x, y, z: where it stands (the prompt's point)
---   numeric         digits only (default true: an amount)     max  the most characters (default 9 for a number, 64 else)
---   title, icon     what is being typed ("Deposit"), and the prompt's glyph
---   prefix          before the text ("$")      commas  a number shown 1,250      placeholder  "Start typing"
---   value           the text it starts with
---   capsule         false: on a keyboard nothing is drawn (the caller shows the text, a conversation's dialog)
---   hang            the pad's keyboard hangs under the anchor instead of standing on it
---   onChange(text), onDone(text), onCancel()
--- Ends any typing already running (quietly: its owner is the one starting this). Returns true.
---@param spec table
---@return boolean
function PromptTyping.open(spec)
    if s then
        local old = s
        s = nil
        release()
        if old.onCancel then pcall(old.onCancel, old.text) end
    end
    gen = gen + 1
    local numeric = spec.numeric ~= false
    local sess = {
        gen = gen, anchor = spec.anchor, numeric = numeric,
        max = math.max(1, math.floor(tonumber(spec.max) or (numeric and 9 or 64))),
        title = spec.title and tostring(spec.title) or nil, icon = spec.icon and tostring(spec.icon) or nil,
        prefix = spec.prefix and tostring(spec.prefix) or '', commas = spec.commas == true and numeric,
        placeholder = spec.placeholder and tostring(spec.placeholder) or 'Start typing',
        capsule = spec.capsule ~= false, hang = spec.hang == true,
        onChange = spec.onChange, onDone = spec.onDone, onCancel = spec.onCancel,
        text = '', caps = false, symbols = false,
    }
    sess.text = clean(sess, spec.value or '')
    s = sess
    page:ensure()
    enter(sess, WhipPadActive == true)

    CreateThread(function()
        local last = GetGameTimer()
        while s == sess do
            local now = GetGameTimer()
            if sess.look ~= 'capsule' then padFrame(sess, now, math.min(0.05, (now - last) / 1000)) end
            last = now
            if s == sess then draw(sess) end
            Wait(0)
        end
    end)
    return true
end

--- End it with no answer to anyone (its owner is ending it: the prompt went, a screen opened).
function PromptTyping.close()
    if not s then return end
    s = nil
    release()
end

--- Is typing up?
---@return boolean
function PromptTyping.active() return s ~= nil end

--- 'capsule' (a keyboard), 'keys' or 'numpad' (a pad), or nil.
---@return string|nil
function PromptTyping.look() return s and s.look or nil end

--- The text so far, or nil.
---@return string|nil
function PromptTyping.text() return s and s.text or nil end

--- Put text in as if typed (cut and cleaned as typing is).
---@param t string|number
function PromptTyping.setText(t)
    if s then setText(s, t) end
end

--- Does typing hold the keyboard, and nothing else hold the NUI focus? Then for the prompts' own question
--- (IsGameInputFree(true)) it is not a screen: the prompt being typed into stays up.
---@return boolean
function PromptTyping.holdsFocusAlone()
    return s ~= nil and s.look == 'capsule' and Focus.onlyHeld(HOLD)
end

-- The keyboard's page: each change of the text, then Enter (done) or Esc (cancel).
RegisterNUICallback('promptTyping', function(data, cb)
    cb('ok')
    local sess = s
    if not sess or type(data) ~= 'table' or data.id ~= sess.gen or sess.look ~= 'capsule' then return end
    if data.cancel then finish(false) return end
    if type(data.text) == 'string' then setText(sess, data.text, true) end
    if data.done then finish(true) end
end)

-- A pad picked up or put down while typing: the other look, with what was typed.
AddEventHandler('whip_core:pad:deviceChanged', function(e)
    local sess = s
    if not sess or type(e) ~= 'table' then return end
    local want = lookFor(sess, e.pad == true)
    if want ~= sess.look then enter(sess, e.pad == true) end
end)

-- Exported for tests (whip_test): nothing outside whip_core starts typing but through a prompt.
PromptTyping._layoutOf, PromptTyping._stepFrom, PromptTyping._keyAt = layoutOf, stepFrom, keyAt
