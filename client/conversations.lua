-- Conversations, client: draws the dialog capsule for a conversation the server opens (server/conversations.lua
-- decides what is said) and takes the answers.
--
--   * Capsule: one browser (html/interact3d/dialog.html) paints the NPC's line and up to four answers into a texture
--     of four cells, cell k with answer k selected. One quad orbits the NPC on the camera's side; moving the selection
--     is a UV switch.
--   * Keys: the conversation is a prompt of its own ('conv') that follows the NPC and holds the focus
--     (Interactions.hold). Scroll moves, E answers; no NUI focus. It ends when the player walks away, a screen opens,
--     or they go down.
--   * An answer whose reply the server sent ahead (`next`) shows it at once; otherwise the capsule dims until the
--     server speaks.
--   * An answer that takes an amount (`input`) becomes a field when chosen (Interactions.beginInput,
--     client/prompt_typing.lua): on a keyboard the digits show in the answer's row (no capsule: the dialog is it),
--     Enter gives it, Esc or Backspace on an empty field steps back; on a pad the number pad hangs under the dialog.
--   * A haggle (`haggle` on the line) draws a ruler over the answers; the amount starts mid-range and ← → move it
--     (a keyboard: the pad's D-pad is the number pad's).
--
-- One draw thread at frame rate, only while a conversation is open.

Conversations = {}

local CFG = Config.Conversations or {}
local PROMPT = 'conv'
local TXD, TEX = 'whip_dialog_txd', 'dialog'

local conv = nil      -- the open conversation: { convId, netId, speaker, layout, layer, waiting, ang }
local looping = false
local boxes = {}      -- [model] = the model box's centre and half-extents, read once

--- The browser, made once and kept, and made early (warm) so the first line does not wait on a page load.
local page = DuiPage.new({
    name = 'conversations', url = 'interact3d/dialog.html', width = 1024, height = 2048, txd = TXD, tex = TEX,
    without = 'conversations will not draw',
})

local function send(msg)
    page:send(msg)
end

function Conversations.warm()
    page:ensure()
end

local function entityOf(netId)
    if type(netId) ~= 'number' or not NetworkDoesNetworkIdExist(netId) then return nil end
    local ent = NetworkGetEntityFromNetworkId(netId)
    if ent == 0 or not DoesEntityExist(ent) then return nil end
    return ent
end

local TYPING_HINT = 'Type the amount · Enter to give it · Esc to go back'
local TEAM_TYPING_HINT = 'Type their character ID · Enter to ask them · Esc to go back'
local HAGGLE_TYPING_HINT = '← → or type it · Enter to ask · Esc to go back'

--- What a typed answer shows while it is being typed: "$1250|".
local function typedLabel(c)
    local t = c.typing
    if not t then return nil end
    return t.prefix .. (Interactions.inputText(PROMPT) or '') .. Interactions.inputCaret()
end

-- A team page lists more than four answers: the capsule shows four rows at a time (`top` is the first), so scrolling
-- within them is still a UV switch and only moving the window repaints.
local TEAM_ROWS_SHOWN = 4

local function paint()
    if not conv then return end
    local labels = {}
    for i, o in ipairs(conv.layer.options or {}) do
        labels[i] = (conv.typing and conv.typing.id == o.id) and typedLabel(conv) or (o.label or '')
    end
    local team, haggle = conv.layer.team, conv.layer.haggle
    -- The keys' words on a keyboard; on a pad the number pad under the dialog has its own.
    local keyboard = PromptTyping.look() == 'capsule'
    local hint = (conv.typing and keyboard) and (team and TEAM_TYPING_HINT or haggle and HAGGLE_TYPING_HINT or TYPING_HINT) or ''
    local asking = haggle and conv.typing and tonumber(Interactions.inputText(PROMPT) or '') or nil
    send({ layout = team and 'team' or haggle and 'haggle' or conv.layout, speaker = conv.speaker or '', line = conv.layer.line or '',
           options = labels, waiting = conv.waiting == true, hint = hint,
           team = team, top = team and (conv.top or 0) or 0, haggle = haggle, asking = asking })
end

--- A round step (1, 2 or 5 of a power of ten) of about a fortieth of the ruler.
local function niceStep(span)
    local raw = math.max(1, span / 40)
    local p = 10 ^ math.floor(math.log(raw, 10))
    for _, m in ipairs({ 1, 2, 5, 10 }) do
        if m * p >= raw then return math.max(1, math.floor(m * p)) end
    end
    return math.max(1, math.floor(10 * p))
end

--- Where a haggle's amount starts: mid-way through where their limit can still be, on a step.
local function haggleStart(h)
    local a = h.a or h.best or h.lo
    local b = h.b or h.hi
    local step = niceStep(h.hi - h.lo)
    local mid = (a + b) / 2
    return math.max(h.lo, math.min(h.hi, math.floor(mid / step + 0.5) * step)), step
end

--- The first row a team page shows, so the selected one (1-based) is among the four.
local function windowTop(sel, n, top)
    top = top or 0
    if sel - 1 < top then top = sel - 1 end
    if sel > top + TEAM_ROWS_SHOWN then top = sel - TEAM_ROWS_SHOWN end
    return math.max(0, math.min(top, math.max(0, n - TEAM_ROWS_SHOWN)))
end

local choose   -- defined below

local function promptOptions(layer)
    local out = {}
    for i, o in ipairs(layer.options or {}) do
        local id = o.id
        out[i] = { id = id, label = o.label, callback = function() choose(id) end }
    end
    return out
end

--- Take everything down. `tellServer`: this side is the one ending it (walked away, blocked).
local function close(tellServer, why)
    local c = conv
    if not c then return end
    conv = nil
    if c.typing then Interactions.cancelInput(PROMPT) end
    Interactions.release(PROMPT)
    Interactions.remove(PROMPT)
    if tellServer then TriggerServerEvent('whip_core:server:conversationLeft', c.convId, why or 'left') end
end

local applyUpdate   -- defined below

--- An answer that takes an amount: the prompt becomes the field. onSubmit sends the answer with the number;
--- onCancel (Backspace on an empty field) puts the answers back.
local function beginTyping(c, opt)
    local maxDigits = #tostring(math.floor(tonumber(opt.input.max) or 999999999))
    c.typing = { id = opt.id, prefix = opt.input.prefix or '' }
    local started = Interactions.beginInput(PROMPT, {
        max = math.max(1, math.min(9, maxDigits)),
        title = opt.label, prefix = opt.input.prefix,
        -- On a keyboard the answer's row is the field (paint), so no capsule; on a pad the number pad hangs under
        -- the dialog, from its lower edge (drawLoop keeps where that is).
        capsule = false, hang = true,
        anchor = function()
            local at = conv == c and c.dialogAt or nil
            if not at then return nil end
            return at.x, at.y, at.z
        end,
        onSubmit = function(text)
            if conv ~= c then return end
            c.typing = nil
            local n = tonumber(text)
            if not n then
                -- E on an empty field: nothing to give; a held page shows now.
                if c.deferred then local d = c.deferred c.deferred = nil applyUpdate(c, d) else paint() end
                return
            end
            c.deferred = nil   -- the server answers this with the page as it is now
            TriggerServerEvent('whip_core:server:conversationChoice', c.convId, opt.id, math.floor(n))
            c.waiting = true
            paint()
        end,
        onCancel = function()
            if conv ~= c then return end
            c.typing = nil
            if c.deferred then local d = c.deferred c.deferred = nil applyUpdate(c, d) else paint() end
        end,
    })
    if not started then c.typing = nil end
    local h = c.layer.haggle
    if started and h then
        local start, step = haggleStart(h)
        c.typing.step, c.typing.lo, c.typing.hi = step, h.lo, math.min(h.hi, tonumber(opt.input.max) or h.hi)
        Interactions.setInputText(PROMPT, start)
    end
    paint()
end

--- ← → while a haggle's amount is typed: a step along the ruler per press, held to run (faster after a while).
local NUDGE_FIRST_MS, NUDGE_EVERY_MS, NUDGE_FAST_MS = 350, 70, 1500
local function nudge(c, now)
    local t = c.typing
    if not t or not t.step then return end
    DisableControlAction(0, 174, true)   -- the arrows and d-pad
    DisableControlAction(0, 175, true)
    local dir = IsDisabledControlPressed(0, 174) and -1 or IsDisabledControlPressed(0, 175) and 1 or 0
    if dir == 0 then t.held = nil return end
    local held = t.held
    if held and held.dir == dir then
        if now < held.next then return end
        held.next = now + NUDGE_EVERY_MS
    else
        held = { dir = dir, since = now, next = now + NUDGE_FIRST_MS }
        t.held = held
    end
    local step = t.step * ((now - held.since) > NUDGE_FAST_MS and 5 or 1)
    local cur = tonumber(Interactions.inputText(PROMPT) or '') or t.lo
    local nxt = math.max(t.lo, math.min(t.hi, math.floor(cur / t.step + 0.5) * t.step + dir * step))
    Interactions.setInputText(PROMPT, nxt)
end

choose = function(optionId)
    local c = conv
    if not c or c.waiting or c.typing then return end
    local opt
    for _, o in ipairs(c.layer.options or {}) do
        if o.id == optionId then opt = o break end
    end
    if not opt then return end
    if opt.input then beginTyping(c, opt) return end
    TriggerServerEvent('whip_core:server:conversationChoice', c.convId, optionId)
    if opt.ends then close(false) return end
    local nxt = c.layer.next and c.layer.next[optionId]
    if nxt then
        c.layer = { line = nxt.line, options = nxt.options }
        Interactions.setOptions(PROMPT, promptOptions(c.layer))
    else
        c.waiting = true
    end
    paint()
end

--- The ped's model box: centre and half-extents along its right and forward.
local function boxOf(model)
    local b = boxes[model]
    if b then return b end
    local mn, mx = GetModelDimensions(model)
    b = { cx = (mn.x + mx.x) / 2, cy = (mn.y + mx.y) / 2, hx = (mx.x - mn.x) / 2, hy = (mx.y - mn.y) / 2 }
    boxes[model] = b
    return b
end

--- Every frame while a conversation is open: draws the capsule orbiting the NPC.
local function drawLoop()
    looping = true
    local last = GetGameTimer()
    local size = CFG.size or 1.0
    local height = CFG.height or 0.375   -- above the hips: from the chest to the shoulders
    local growFrom = tonumber(CFG.minSizeFrom) or 4.0
    local growMost = math.max(1.0, tonumber(CFG.maxGrow) or 1.75)
    local margin = CFG.margin or 0.12
    local rate = CFG.swing or 10.0
    while conv do
        local now = GetGameTimer()
        local dt = (now - last) / 1000
        last = now
        -- A typed amount is repainted when it changes, not every frame. ← → nudge a haggle on a keyboard (on a pad
        -- the D-pad is the number pad's).
        if conv.typing then
            if PromptTyping.look() == 'capsule' then nudge(conv, now) end
            local shown = typedLabel(conv)
            if shown ~= conv.typing.shown then
                conv.typing.shown = shown
                paint()
            end
        end
        local ped = entityOf(conv.netId)
        if ped and page:up() then
            local b = boxOf(GetEntityModel(ped))
            local pos = GetEntityCoords(ped)
            local hd = math.rad(GetEntityHeading(ped))
            local ex, ey = math.cos(hd), math.sin(hd)       -- the ped's right
            local fx, fy = -math.sin(hd), math.cos(hd)      -- the ped's forward
            local bx = pos.x + ex * b.cx + fx * b.cy
            local by = pos.y + ey * b.cx + fy * b.cy
            -- n: flat, from the box centre towards the camera, eased so it swings round.
            local cam = GetFinalRenderedCamCoord()
            local dx, dy = cam.x - bx, cam.y - by
            local target = (dx * dx + dy * dy > 0.0025) and math.atan(dy, dx) or (conv.ang or 0.0)
            if not conv.ang then conv.ang = target end
            local diff = (target - conv.ang + math.pi) % (2 * math.pi) - math.pi
            conv.ang = conv.ang + diff * math.min(1.0, dt * rate)
            local nx, ny = math.cos(conv.ang), math.sin(conv.ang)
            -- s: how far the box reaches along n; the capsule sits beyond it.
            local s = math.abs(nx * ex + ny * ey) * b.hx + math.abs(nx * fx + ny * fy) * b.hy
            local r = s + margin
            local rx, ry = -ny, nx          -- right; with up = (0, 0, 1) the drawn face points along n
            local idx = conv.waiting and 1 or (Interactions.getSelection(PROMPT) or 1)
            if conv.layer.team and not conv.waiting then
                -- The selection left the four rows shown: the window moves to it.
                local top = windowTop(idx, #conv.layer.options, conv.top)
                if top ~= (conv.top or 0) then
                    conv.top = top
                    paint()
                end
                idx = idx - (conv.top or 0)
            end
            if idx > 4 then idx = 4 end
            if idx < 1 then idx = 1 end
            -- Hung from the ped's root (about the hips). Beyond growFrom from the camera it grows, up to growMost times.
            local qx, qy, qz = bx + nx * r, by + ny * r, pos.z + height
            local w = size
            if growFrom > 0 then
                local cx, cy, cz = cam.x - qx, cam.y - qy, cam.z - qz
                local d = math.sqrt(cx * cx + cy * cy + cz * cz)
                if d > growFrom then w = size * math.min(growMost, d / growFrom) end
            end
            WorldQuad.draw(TXD, TEX, qx, qy, qz,
                rx, ry, 0.0, 0.0, 0.0, 1.0, w, w * 0.5,
                0.0, (idx - 1) / 4, 1.0, idx / 4, 255, 255, 255, 255)
            -- Its lower edge: where a pad's number pad hangs from while an amount is typed.
            local at = conv.dialogAt or {}
            at.x, at.y, at.z = qx, qy, qz - w * 0.25
            conv.dialogAt = at
        end
        Wait(0)
    end
    looping = false
end

-- From the server

local TEAM_STATES = { you = true, ['in'] = true, waiting = true }

--- A team page's slots, made safe to draw: { max, slots = { { name, state } } }, or nil.
local function readTeam(t)
    if type(t) ~= 'table' then return nil end
    local max = math.floor(tonumber(t.max) or 0)
    if max < 1 or max > 16 then return nil end
    local slots = {}
    for _, s in ipairs(type(t.slots) == 'table' and t.slots or {}) do
        if type(s) == 'table' and TEAM_STATES[s.state] and #slots < max then
            slots[#slots + 1] = { name = type(s.name) == 'string' and s.name or '', state = s.state }
        end
    end
    return { max = max, slots = slots }
end

--- A haggle's ruler, made safe to draw (server/conversations.lua readHaggle), or nil.
local HAGGLE_SAYS = { yes = true, no = true, insult = true }
local function readHaggle(h)
    if type(h) ~= 'table' then return nil end
    local lo, hi = tonumber(h.lo), tonumber(h.hi)
    if not lo or not hi or hi <= lo then return nil end
    local asks = {}
    for _, a in ipairs(type(h.asks) == 'table' and h.asks or {}) do
        if type(a) == 'table' and tonumber(a.p) and HAGGLE_SAYS[a.r] and #asks < 8 then
            asks[#asks + 1] = { p = tonumber(a.p), r = a.r, h = tonumber(a.h) or 0 }
        end
    end
    return { buys = h.buys == true, lo = lo, hi = hi, unit = h.unit == 'count' and 'count' or 'money', asks = asks,
             best = tonumber(h.best), a = tonumber(h.a), b = tonumber(h.b), left = tonumber(h.left) or 0,
             pat = tonumber(h.pat) or 0, patMax = tonumber(h.patMax) or 0 }
end

--- A layer made safe to draw: { line, options = { { id, label, ends, input } }, next }.
local function readLayer(v)
    if type(v) ~= 'table' then return nil end
    local team = readTeam(v.team)
    local out = { line = type(v.line) == 'string' and v.line or '', options = {}, team = team, haggle = readHaggle(v.haggle) }
    for _, o in ipairs(type(v.options) == 'table' and v.options or {}) do
        if type(o) == 'table' and type(o.id) == 'string' and #out.options < (team and 12 or 4) then
            local input = type(o.input) == 'table' and {
                max = tonumber(o.input.max) or 999999999,
                prefix = type(o.input.prefix) == 'string' and o.input.prefix or '',
            } or nil
            out.options[#out.options + 1] = { id = o.id, label = type(o.label) == 'string' and o.label or '', ends = o.ends == true,
                                              input = input }
        end
    end
    if type(v.next) == 'table' then
        out.next = {}
        for id, n in pairs(v.next) do
            local l = readLayer(n)
            if type(id) == 'string' and l then out.next[id] = { line = l.line, options = l.options, team = l.team, haggle = l.haggle } end
        end
    end
    return out
end

--- Do two lists hold the same answers (ids, in order)? Then the prompt's list is left alone, keeping the player's place
--- and anything being typed.
local function sameIds(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i].id ~= b[i].id then return false end
    end
    return true
end

--- An update from the server replaces what was shown. u = { layer, speaker }.
applyUpdate = function(c, u)
    local before, layer = c.layer, u.layer
    local sameTeamList = layer.team and before.team and sameIds(before.options, layer.options)
    -- A changed team list while an ID is being typed is held until typing ends (a new list would drop the digits).
    if c.typing and before.team and layer.team and not sameTeamList then
        c.deferred = u
        return
    end
    c.layer, c.waiting = layer, false
    if type(u.speaker) == 'string' then c.speaker = u.speaker end
    if layer.team and not before.team then c.top = 0 end    if not sameTeamList then
        local _, keep = Interactions.getSelection(PROMPT)
        Interactions.setOptions(PROMPT, promptOptions(layer))
        -- Stay on the answer the player was on, if it is still there.
        if layer.team and before.team and keep then Interactions.setSelection(PROMPT, keep) end
    end
    paint()
end

RegisterNetEvent('whip_core:client:conversation', function(convId, v)
    if type(v) ~= 'table' then
        if conv and conv.convId == convId then close(false) end        return
    end
    local layer = readLayer(v)
    if not layer or #layer.options == 0 then return end

    if conv and conv.convId == convId then
        applyUpdate(conv, { layer = layer, speaker = v.speaker })
        return
    end

    if conv then close(true, 'replaced') end
    local ped = entityOf(v.netId)
    if not ped then
        TriggerServerEvent('whip_core:server:conversationLeft', convId, 'gone')
        return
    end
    Conversations.warm()
    conv = { convId = convId, netId = v.netId, speaker = type(v.speaker) == 'string' and v.speaker or '',
             layout = v.layout == 'stack' and 'stack' or 'grid', layer = layer, waiting = false }
    local p = GetEntityCoords(ped)
    local netId = v.netId
    local ok, why = Interactions.register({
        id = PROMPT, x = p.x, y = p.y, z = p.z, label = '', icon = 'E', group = 'conversation',
        follow = function()
            local e = entityOf(netId)
            if not e then return nil end
            local c = GetEntityCoords(e)
            return c.x, c.y, c.z
        end,
        visibleRange = CFG.range or 6.0,
        activeRange = CFG.range or 6.0,
        options = promptOptions(layer),
    })
    if ok == false then
        print('[whip_core:conversations] could not open: ' .. tostring(why))
        conv = nil
        TriggerServerEvent('whip_core:server:conversationLeft', convId, 'gone')
        return
    end
    Interactions.hold(PROMPT, {
        hidden = true,
        -- Walked away, or a screen or going down took the prompts: the conversation is over.
        onLost = function(reason) close(true, reason == 'blocked' and 'blocked' or 'left') end,
    })
    paint()
    if not looping then CreateThread(drawLoop) end
end)

-- Ready before anyone talks to this player.
AddEventHandler('whip_core:player:loaded', function() Conversations.warm() end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    close(false)end)
