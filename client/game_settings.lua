-- ============================================
-- GAME SETTINGS — GTA's own settings, on whip's pause menu page
-- ============================================
--
-- The pause menu's Settings (html/js/settings-page.js), under Game, is GTA's settings in whip's look: every tab GTA has
-- (Audio, Display, Graphics...) read from GTA, and changed through GTA, so they are kept where GTA keeps them.
--
-- GTA'S SETTINGS MENU RUNS UNDER WHIP'S PAGE, NOT DRAWN. stream/scaleform/pause_menu_pages_settings.gfx is GTA's
-- settings page with whip's questions added (its source and how to build it: dev/pause_settings/). Asked for a column
-- named "whip|<what>|...", the page answers instead (GET_COLUMN_SELECTION). GTA answers a frame later at the earliest,
-- so questions go in batches and come back together; an answer carries CHUNK characters of text, a longer one is read
-- in pieces.
--
-- A CHANGE IS MADE AS A PLAYER MAKES IT: the row clicked, then left or right pressed, and GTA's menu does the rest. A
-- graphics change waits for Apply, GTA asks its own questions (keep these display settings? restart needed?), a list
-- GTA fills as it goes (the radio stations) steps through. GTA ignores a press to a menu it does not draw, so the menu
-- is drawn for the press only, under whip's page, which covers it. Its questions are shown on whip's page and
-- answered from there.
--
-- One job at a time: each callback waits its turn. The page going back to the menu, the pause menu shutting or
-- whip_core stopping shuts GTA's menu.

local MENU = 'FE_MENU_VERSION_LANDING_MENU'   -- the menu that opens on the settings, without the pause tabs
local FRONTEND = 2                            -- the control group GTA's menus read
local KEY = { left = 189, right = 190, accept = 201, cancel = 202, x = 203 }
local MAX_PENDING = 8         -- questions waiting at once; GTA's own limit is unknown
local CHUNK = 60              -- text one answer carries ("W1|" and 60 characters come back whole)
local PAGE_WAIT_MS = 10000    -- GTA's settings page answering after it opens: about 3 s the first time
local STEP_TRIES = 3          -- GTA now and then drops a press on quick repeats: a step is pressed again if it did not land
local MAX_STEPS = 40          -- a slider set by dragging: presses toward the value, at most

local KEYS_TAB = 1131         -- Key Bindings: GTA's own screen, a page of its own (pause.lua opens it)
local HIDDEN_TABS = { [1139] = true }          -- Voice Chat: GTA's voice chat, which FiveM servers do not use
local GRAPHICS_TABS = { [1137] = true, [1138] = true }

--- A row's kind by GTA's type: 0 something to do (Restore Defaults), 1 a list, 2 a slider. Others are shown only.
local KINDS = { [0] = 'button', [1] = 'list', [2] = 'slider' }

--- GTA's questions whip knows, by the hash of their text's label: a title and buttons, each the key GTA takes for it.
--- Any other is shown as GTA's question with OK and Back.
local QUESTIONS = {}
for _, q in ipairs({
    { label = 'GFX_WARNING_MP', title = 'Apply graphics changes?', buttons = { { 'Apply', KEY.accept }, { 'Cancel', KEY.cancel } } },
    { label = 'GFX_BACK_OUT_BODY', title = 'Graphics changes not applied',
      buttons = { { 'Apply', KEY.accept }, { 'Discard', KEY.x }, { 'Cancel', KEY.cancel } } },
    { label = 'GFX_WARNING_BODY', title = 'Keep these display settings?', buttons = { { 'Keep', KEY.accept }, { 'Revert', KEY.cancel } },
      body = 'GTA goes back to the old display settings by itself in a few seconds unless you keep these.' },
    { label = 'GFX_RESTART_BODY', title = 'Restart needed', buttons = { { 'Restart the game', KEY.accept }, { 'Not now', KEY.cancel } } },
    { label = 'GFX_WRITE_FAILED', title = 'Settings not saved', buttons = { { 'OK', KEY.accept } } },
    { label = 'GFX_NO_APPLY_BODY', title = 'Graphics changes not applied', buttons = { { 'OK', KEY.accept } } },
}) do
    QUESTIONS[GetHashKey(q.label) & 0xffffffff] = q
end
local UNKNOWN_QUESTION = { title = 'GTA is asking', buttons = { { 'OK', KEY.accept }, { 'Back', KEY.cancel } },
    body = 'GTA wants an answer before it goes on: OK goes ahead, Back does not.' }

--- GET_WARNING_MESSAGE_TITLE_HASH, by name or, on a client whose Lua lacks it, by hash.
local warningHash = GetWarningMessageTitleHash or function()
    return Citizen.InvokeNative(0x81DF9ABA6C83DFF9, Citizen.ResultAsInteger())
end

local active = false          -- GTA's settings menu is up for whip's page
local gen = 0                 -- bumped on every open and close: a job from an older one stops
local busy = false            -- a job is running
local drawn = false           -- GTA's menu drawn this frame (a press is on its way)
local pressing = nil          -- the control held down this frame, or nil
local asked = nil             -- the hash of the question GTA is asking now, or nil
local tabs = nil              -- GTA's tabs as read: { index, id, label }
local labels = {}             -- [tab id] = { [row id] = name }: they do not change while the menu is up
local options = {}            -- [tab id] = { [row id] = { count, texts } }: a list's options, kept while their count holds
--- [graphics tab id] = { [row id] = { from = { value, text }, steps } }: graphics changes made here and waiting for
--- Apply, each with what it was and how many steps it has moved (right +, left -), which is how Undo takes it back. Kept
--- here, not read from GTA: the "changed" mark GTA shows on such a row is on the row drawn, not on the data the page reads.
local pending = {}

local function anyPending()
    for _, rows in pairs(pending) do
        if next(rows) then return true end
    end
    return false
end

-- ============================================
-- Asking the page
-- ============================================

local function send(cmd)
    if not BeginScaleformMovieMethodOnFrontend('GET_COLUMN_SELECTION') then return 0 end
    ScaleformMovieMethodAddParamTextureNameString(cmd)
    return EndScaleformMovieMethodReturnValue()
end

local function stillOpen(g) return active and gen == g end

--- Every question's answer, in order. GTA drops questions now and then: sent while its page is still loading (the
--- first open takes about 3 s), or on their way when GTA asks a question of its own. A batch not answered within
--- RESEND_MS goes again, until `patience` ms (3000) have gone by without an answer; after a question of GTA's, once
--- it has been answered.
local RESEND_MS = 500
local function askAll(cmds, g, patience)
    local out = {}
    local first = 1
    local giveUp = GetGameTimer() + (patience or 3000)
    while first <= #cmds do
        while asked and stillOpen(g) do Wait(0) end
        assert(stillOpen(g), 'closed')
        local handles = {}
        for i = first, math.min(first + MAX_PENDING - 1, #cmds) do handles[#handles + 1] = send(cmds[i]) end
        local resend = GetGameTimer() + RESEND_MS
        local ready = false
        repeat
            Wait(0)
            ready = true
            for _, h in ipairs(handles) do
                if h ~= 0 and not IsScaleformMovieMethodReturnValueReady(h) then ready = false break end
            end
        until ready or asked or not stillOpen(g) or GetGameTimer() > resend
        if ready and not asked then
            for _, h in ipairs(handles) do
                out[#out + 1] = h ~= 0 and (GetScaleformMovieMethodReturnValueString(h) or '') or ''
            end
            first = first + #handles
            giveUp = GetGameTimer() + (patience or 3000)
        elseif not asked then
            assert(GetGameTimer() < giveUp, 'GTA\'s settings did not answer')
        end
    end
    return out
end

local function ask(cmd, g, patience) return askAll({ cmd }, g, patience)[1] end

local function fields(answer)
    local t = {}
    for part in (answer .. '|'):gmatch('(.-)|') do t[#t + 1] = part end
    return t
end

--- GTA's text without its markup: <font> tags and ~colour~ codes.
local function plain(text)
    return (text:gsub('<[^>]*>', ''):gsub('~[^~]*~', ''):gsub('&amp;', '&'):gsub('&lt;', '<'):gsub('&gt;', '>'))
end

--- Texts from rows' data, each { col, index, field }: read in pieces of CHUNK until a piece comes back short.
local function readTexts(list, g)
    local texts, open, from = {}, {}, 0
    for i in ipairs(list) do texts[i] = '' open[i] = true end
    while next(open) do
        local order, cmds = {}, {}
        for i in pairs(open) do
            local t = list[i]
            order[#order + 1] = i
            cmds[#cmds + 1] = ('whip|text|%d|%d|%d|%d|%d'):format(t[1], t[2], t[3], from, CHUNK)
        end
        local answers = askAll(cmds, g)
        for k, i in ipairs(order) do
            local piece = answers[k]:sub(1, 3) == 'W1|' and answers[k]:sub(4) or ''
            texts[i] = texts[i] .. piece
            if #piece < CHUNK then open[i] = nil end
        end
        from = from + CHUNK
        if from > 1000 then break end
    end
    for i, t in ipairs(texts) do texts[i] = plain(t) end
    return texts
end

--- Rows' data in column `col` (1 the tabs, 2 the settings): { index, id, type, value, state, count }.
--- state is GTA's: 0 cannot be changed, 1 can, 2 changed and not applied.
local function readRows(col, count, g)
    local cmds = {}
    for i = 0, count - 1 do cmds[#cmds + 1] = ('whip|row|%d|%d'):format(col, i) end
    local rows = {}
    for i, a in ipairs(askAll(cmds, g)) do
        local f = fields(a)
        if f[1] == 'W1' then
            rows[#rows + 1] = { index = i - 1, id = tonumber(f[3]), type = tonumber(f[4]), value = tonumber(f[5]) or 0,
                state = tonumber(f[6]) or 0, count = tonumber(f[7]) or 0, menu = tonumber(f[2]) }
        end
    end
    return rows
end

--- What GTA shows: { tabs, rows, tab (the tab row chosen), menuState }.
local function head(g, patience)
    local f = fields(ask('whip|head', g, patience))
    if f[1] ~= 'W1' then return nil end
    return { tabs = tonumber(f[2]) or 0, rows = tonumber(f[3]) or 0, tab = tonumber(f[4]) or -1,
        menuState = tonumber(f[5]), sig = f[6] or '' }
end

-- ============================================
-- GTA's menu, held under the page
-- ============================================

local close

--- One frame while the menu is up: not drawn (bar a press), its cursor hidden, the pad kept off it, the press held, and
--- GTA's questions watched for. whip's pause menu shutting (Resume, Esc, logging out) shuts it.
local function frame()
    if not active then return end
    if not PauseMenuOpen then close() return end
    if not drawn then Citizen.InvokeNative(0xBA751764F0821256) end   -- SUPPRESS_FRONTEND_RENDERING_THIS_FRAME
    Citizen.InvokeNative(0x98215325A695E78A, false)                   -- SET_MOUSE_CURSOR_VISIBLE: whip's page has the mouse
    DisableAllControlActions(FRONTEND)
    if pressing then
        -- Both groups: GTA's menus read the frontend's, and some of its keys the player's too.
        for _, group in ipairs({ 0, FRONTEND }) do
            EnableControlAction(group, pressing, true)
            SetControlNormal(group, pressing, 1.0)
        end
    end
    local hash = IsWarningMessageActive() and (warningHash() & 0xffffffff) or nil
    if hash ~= asked then
        asked = hash
        local q = hash and (QUESTIONS[hash] or UNKNOWN_QUESTION)
        local msg = { action = 'gameSettingsQuestion', refresh = not hash }
        if q then
            local words = {}
            for i, b in ipairs(q.buttons) do words[i] = b[1] end
            msg.question = { title = q.title, body = q.body or (q.label and plain(GetLabelText(q.label))) or '',
                buttons = words }
        end
        SendNUIMessage(msg)
    end
end

function close()
    if not active then return end
    active = false
    gen = gen + 1
    drawn, pressing, asked, tabs = false, nil, nil, nil
    labels, options, pending = {}, {}, {}
    ControlBlocks.release('gameSettings')
    if IsPauseMenuActive() then SetFrontendActive(false) end
    SendNUIMessage({ action = 'gameSettingsQuestion' })
end

--- A control pressed for `holdMs` (100) and let go, with the menu drawn around it: GTA takes some presses as they are
--- let go.
local function press(control, g, holdMs)
    drawn = true
    Wait(150)
    pressing = control
    Wait(holdMs or 100)
    pressing = nil
    Wait(100)
    if stillOpen(g) then drawn = false end
end

--- GTA's settings menu up and answering, its tabs read. Opened again when something shut it.
local function ensureOpen(g)
    if tabs and IsPauseMenuActive() then return end
    tabs = nil
    if IsPauseMenuActive() then
        SetFrontendActive(false)
        Wait(100)
    end
    ActivateFrontendMenu(GetHashKey(MENU), false, -1)
    local deadline = GetGameTimer() + 5000
    while not IsPauseMenuActive() or IsPauseMenuRestarting() or not IsFrontendReadyForControl() do
        assert(stillOpen(g), 'closed')
        assert(GetGameTimer() < deadline, 'GTA\'s settings did not open')
        Wait(0)
    end
    -- GTA's menu coming up can take the keyboard and mouse from whip's page: given back.
    Focus.reassert()
    -- Its settings page loads after the menu says it is ready: GTA answers once it has (about 3 s the first time).
    local h
    deadline = GetGameTimer() + PAGE_WAIT_MS
    repeat
        local ok, got = pcall(head, g, math.max(1, deadline - GetGameTimer()))
        assert(stillOpen(g), 'closed')
        h = ok and got or nil
        if h and h.tabs > 0 then break end
        Wait(100)
    until GetGameTimer() > deadline
    assert(h and h.tabs > 0, 'GTA\'s settings page did not answer: is whip_core\'s stream folder streaming?')
    local rows = readRows(1, h.tabs, g)
    local list = {}
    for i, r in ipairs(rows) do list[i] = { 1, r.index, 6 } end
    local names = readTexts(list, g)
    tabs = {}
    for i, r in ipairs(rows) do
        if not HIDDEN_TABS[r.menu] and names[i] ~= '' then
            tabs[#tabs + 1] = { index = r.index, id = r.menu, label = names[i] }
        end
    end
end

local function tabOf(id)
    for _, t in ipairs(tabs or {}) do
        if t.id == id then return t end
    end
end

--- GTA showing tab `id`: clicked in its menu, then waited for until its rows are in.
local function showTab(id, g)
    local t = assert(tabOf(id), 'GTA has no such settings tab')
    local h = assert(head(g), 'GTA\'s settings page did not answer')
    if h.tab == t.index and h.rows > 0 then return h end
    local before = h.sig
    ask(('whip|click|1|%d'):format(t.index), g)
    local deadline = GetGameTimer() + 3000
    repeat
        Wait(50)
        h = head(g) or h
    until (h.tab == t.index and h.rows > 0 and (h.sig ~= before or h.menuState == id)) or GetGameTimer() > deadline
    assert(h.tab == t.index, 'GTA did not open that tab')
    Wait(50)
    return head(g) or h
end

-- ============================================
-- A tab as the page draws it
-- ============================================

--- GTA's video memory bar, as GTA last set it on a Graphics tab: { label, percent, percent2 } (percent2 -1: one bar),
--- or nil before GTA has.
local function readMemory(g)
    local f = fields(ask('whip|vidmem', g))
    if f[1] ~= 'W1' then return nil end
    local label, from = '', 0
    repeat
        local a = ask(('whip|vidtext|%d|%d'):format(from, CHUNK), g)
        local piece = a:sub(1, 3) == 'W1|' and a:sub(4) or ''
        label = label .. piece
        from = from + CHUNK
    until #piece < CHUNK or from > 600
    return { label = plain(label), percent = tonumber(f[2]) or 0, percent2 = tonumber(f[3]) or -1 }
end

--- Every row of the tab GTA shows: { id, label, kind, value, max, text, options, locked, changed }.
local function readTab(id, g)
    local h = showTab(id, g)
    local data = readRows(2, h.rows, g)
    local names = labels[id] or {}
    labels[id] = names
    local known = options[id] or {}
    options[id] = known

    -- Names once per tab; a list's options while their count holds, or always for a list of one (GTA fills it as it
    -- goes, so its one option is what it is set to).
    local want, why = {}, {}
    for _, r in ipairs(data) do
        if names[r.id] == nil then
            want[#want + 1] = { 2, r.index, 6 }
            why[#why + 1] = { r, 'name' }
        end
        if r.type == 1 and r.count > 0 then
            local k = known[r.id]
            if not k or k.count ~= r.count or r.count == 1 then
                known[r.id] = { count = r.count, texts = {} }
                for o = 0, r.count - 1 do
                    want[#want + 1] = { 2, r.index, 7 + o }
                    why[#why + 1] = { r, o + 1 }
                end
            end
        elseif r.type == 2 and r.count > 0 and not known[r.id] then
            known[r.id] = { count = r.count, texts = {} }
            want[#want + 1] = { 2, r.index, 7 }
            why[#why + 1] = { r, 1 }
        end
    end
    local texts = #want > 0 and readTexts(want, g) or {}
    for i, w in ipairs(why) do
        local r, what = w[1], w[2]
        if what == 'name' then names[r.id] = texts[i] else known[r.id].texts[what] = texts[i] end
    end

    local waiting = pending[id] or {}
    local rows = {}
    for _, r in ipairs(data) do
        local name = names[r.id] or ''
        if name ~= '' then
            local kind = KINDS[r.type] or 'info'
            local opts = known[r.id] and known[r.id].texts or {}
            local was = waiting[r.id] and waiting[r.id].from
            local row = { id = r.id, label = name, kind = kind, value = r.value,
                locked = r.state == 0, changed = was ~= nil, was = was and (was.text or was.value) or nil }
            if kind == 'slider' then
                row.max = math.max(1, tonumber(opts[1]) or 10)
            elseif kind == 'list' then
                row.text = (#opts > 1 and opts[r.value + 1]) or opts[1] or ''
                if #opts > 1 then row.options = opts end
            end
            rows[#rows + 1] = row
        end
    end
    return { id = id, label = tabOf(id).label, graphics = GRAPHICS_TABS[id] == true, rows = rows,
        vram = GRAPHICS_TABS[id] and readMemory(g) or nil }
end

--- Every change waiting for Apply, on any graphics tab: { tab, id, label, was }.
local function pendingList()
    local list = {}
    for tab, rows in pairs(pending) do
        for rowId, p in pairs(rows) do
            list[#list + 1] = { tab = tab, id = rowId, label = labels[tab] and labels[tab][rowId] or '',
                was = p.from.text or p.from.value }
        end
    end
    table.sort(list, function(a, b) return a.tab == b.tab and a.label < b.label or a.tab < b.tab end)
    return list
end

--- What every answer to the page carries: the tab as it is now, and the changes waiting for Apply.
local function answer(id, g, extra)
    local st = { tab = readTab(id, g), unapplied = anyPending(), pending = pendingList() }
    if extra then for k, v in pairs(extra) do st[k] = v end end
    return st
end

--- The tab's row `rowId` as GTA has it now: its data and, for a list, the option it shows.
local function rowNow(id, rowId, g)
    local h = showTab(id, g)
    for _, r in ipairs(readRows(2, h.rows, g)) do
        if r.id == rowId then
            if r.type == 1 then
                r.text = readTexts({ { 2, r.index, 7 + (r.count > 1 and r.value or 0) } }, g)[1]
            end
            return r
        end
    end
end

--- The row clicked in GTA's menu, so a press lands on it. Twice: the first click into the list moves GTA there, the
--- second tells GTA which row it is on.
local function focusRow(row, g)
    ask(('whip|click|2|%d'):format(row.index), g)
    Wait(50)
    ask(('whip|click|2|%d'):format(row.index), g)
    Wait(100)
end

--- One step left (-1) or right (1) on a row, pressed again if GTA dropped it. Answers whether it moved. A graphics
--- row that moved waits for Apply.
local function stepRow(id, rowId, dir, g)
    local row = assert(rowNow(id, rowId, g), 'that setting is gone')
    assert(row.state ~= 0, 'GTA does not let that one change here')
    local max = tonumber((options[id] and options[id][rowId] and options[id][rowId].texts[1]) or '') or 10
    if row.type == 2 and ((dir > 0 and row.value >= max) or (dir < 0 and row.value <= 0)) then return false end
    focusRow(row, g)
    -- A graphics row waits for Apply, keeping what it was; stepped back to it, it waits no more.
    local function moved()
        if GRAPHICS_TABS[id] then
            pending[id] = pending[id] or {}
            local p = pending[id][rowId]
            if not p then
                p = { from = { value = row.value, text = row.text }, steps = 0 }
                pending[id][rowId] = p
            end
            p.steps = p.steps + dir
            if p.steps == 0 then pending[id][rowId] = nil end
        end
        return true
    end
    for _ = 1, STEP_TRIES do
        press(dir > 0 and KEY.right or KEY.left, g)
        local now = rowNow(id, rowId, g)
        if not now then return moved() end
        if now.value ~= row.value or now.text ~= row.text then return moved() end
        Wait(100)
        now = rowNow(id, rowId, g)
        if now and (now.value ~= row.value or now.text ~= row.text) then return moved() end
    end
    return false
end

-- ============================================
-- One job at a time
-- ============================================

local function job(fn)
    local g = gen
    while busy do Wait(0) end
    if not stillOpen(g) then return { error = 'closed' } end
    busy = true
    local ok, st = pcall(fn, g)
    busy = false
    pressing = nil
    if stillOpen(g) then drawn = false end
    if ok then return st end
    local why = tostring(st):gsub('^.-:%d+: ', '')
    if stillOpen(g) then print('[whip_core:settings] ' .. why) end
    return { error = why }
end

--- A tab id from the page: a number GTA has.
local function tabArg(data)
    local id = type(data) == 'table' and tonumber(data.tab)
    return id and tabOf(id) and id or nil
end

local function rowArg(data)
    return type(data) == 'table' and math.tointeger(tonumber(data.id)) or nil
end

-- ============================================
-- The page's callbacks
-- ============================================

--- Settings opened: GTA's menu up, its tabs, and the one asked for (`tab`) or the first.
RegisterNUICallback('gameSettingsOpen', function(data, cb)
    if not PauseMenuOpen then return cb({ error = 'closed' }) end
    if not active then
        active = true
        gen = gen + 1
        ControlBlocks.hold('gameSettings', {}, frame)
    end
    cb(job(function(g)
        ensureOpen(g)
        local list = {}
        for i, t in ipairs(tabs) do list[i] = { id = t.id, label = t.label, keys = t.id == KEYS_TAB } end
        local first = tabArg(data)
        if not first or first == KEYS_TAB then
            for _, t in ipairs(tabs) do
                if t.id ~= KEYS_TAB then first = t.id break end
            end
        end
        return answer(first, g, { tabs = list })
    end))
end)

RegisterNUICallback('gameSettingsTab', function(data, cb)
    cb(job(function(g)
        ensureOpen(g)
        return answer(assert(tabArg(data), 'GTA has no such settings tab'), g)
    end))
end)

--- One step on a slider or a list: `dir` -1 or 1.
RegisterNUICallback('gameSettingsStep', function(data, cb)
    cb(job(function(g)
        ensureOpen(g)
        local id = assert(tabArg(data), 'GTA has no such settings tab')
        local rowId = assert(rowArg(data), 'no such setting')
        local moved = stepRow(id, rowId, tonumber(data.dir) == -1 and -1 or 1, g)
        return answer(id, g, { moved = moved })
    end))
end)

--- A slider to `value` (dragged there): stepped toward it until it is there or stops moving.
RegisterNUICallback('gameSettingsSet', function(data, cb)
    cb(job(function(g)
        ensureOpen(g)
        local id = assert(tabArg(data), 'GTA has no such settings tab')
        local rowId = assert(rowArg(data), 'no such setting')
        local want = math.tointeger(tonumber(data.value)) or 0
        for _ = 1, MAX_STEPS do
            local row = rowNow(id, rowId, g)
            if not row or row.value == want then break end
            if not stepRow(id, rowId, want > row.value and 1 or -1, g) then break end
        end
        return answer(id, g)
    end))
end)

--- A row that does something (Restore Defaults): pressed as Enter would. GTA may ask first.
RegisterNUICallback('gameSettingsPress', function(data, cb)
    cb(job(function(g)
        ensureOpen(g)
        local id = assert(tabArg(data), 'GTA has no such settings tab')
        local row = assert(rowNow(id, assert(rowArg(data), 'no such setting'), g), 'that setting is gone')
        assert(row.state ~= 0, 'GTA does not let that one be used here')
        focusRow(row, g)
        press(KEY.accept, g, 150)
        Wait(200)
        return answer(id, g)
    end))
end)

--- A graphics row waiting for Apply stepped back to what it was.
local function undoRow(id, rowId, g)
    local p = pending[id] and pending[id][rowId]
    if not p then return end
    local back = p.steps > 0 and -1 or 1
    for _ = 1, math.min(math.abs(p.steps), MAX_STEPS) do
        if not (pending[id] and pending[id][rowId]) then break end
        if not stepRow(id, rowId, back, g) then break end
    end
end

--- Undo on one change waiting for Apply (`id`), or every one (`all`).
RegisterNUICallback('gameSettingsUndo', function(data, cb)
    cb(job(function(g)
        ensureOpen(g)
        local shown = tabArg(data)
        if type(data) == 'table' and data.all == true then
            for tab, rows in pairs(pending) do
                local ids = {}
                for rowId in pairs(rows) do ids[#ids + 1] = rowId end
                for _, rowId in ipairs(ids) do undoRow(tab, rowId, g) end
            end
        else
            undoRow(assert(shown, 'GTA has no such settings tab'), assert(rowArg(data), 'no such setting'), g)
        end
        return answer(shown or next(pending) or tabs[1].id, g)
    end))
end)

--- The graphics changes applied, as GTA's Apply (Space) does, on a row that changed. GTA may ask first: its answer
--- (gameSettingsAnswer) decides; with no question they are applied.
RegisterNUICallback('gameSettingsApply', function(data, cb)
    cb(job(function(g)
        ensureOpen(g)
        local id = tabArg(data)
        if not (id and pending[id] and next(pending[id])) then
            id = nil
            for tab, rows in pairs(pending) do
                if next(rows) then id = tab break end
            end
        end
        assert(id, 'there is nothing to apply')
        local h = showTab(id, g)
        local row
        for _, r in ipairs(readRows(2, h.rows, g)) do
            if pending[id][r.id] then row = r break end
        end
        assert(row, 'there is nothing to apply')
        focusRow(row, g)
        press(KEY.x, g, 150)
        local deadline = GetGameTimer() + 1500
        while not asked and GetGameTimer() < deadline do Wait(50) end
        if not asked then pending = {} end
        return answer(id, g)
    end))
end)

--- GTA's question answered: button `index` (1 the first) pressed. Not a job: a job waits for the answer. Going ahead
--- (Apply, Keep, OK) or Discard ends the graphics changes waiting; Cancel keeps them waiting.
RegisterNUICallback('gameSettingsAnswer', function(data, cb)
    cb({})
    if not active or not asked then return end
    local q = QUESTIONS[asked] or UNKNOWN_QUESTION
    local b = q.buttons[math.tointeger(tonumber(type(data) == 'table' and data.index or nil)) or 0]
    if not b then return end
    if b[2] ~= KEY.cancel then pending = {} end
    press(b[2], gen, 150)
end)

--- Back to whip's menu, or the pause menu shut: GTA's menu shut with it. A change waiting for Apply is dropped.
RegisterNUICallback('gameSettingsClose', function(_, cb)
    close()
    cb({})
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() and active and IsPauseMenuActive() then SetFrontendActive(false) end
end)
