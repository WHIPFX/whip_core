-- ============================================
-- RADIAL MENU — Client
--
-- A wheel of the things you can do right now, opened with F1.
--
-- Options register themselves with a condition, and the wheel shows whichever currently apply.
-- Other resources put an option here with AddAction (`at = { radial = true }`, client/actions.lua).
--
-- The aim target asks what you are LOOKING at (lockpick this car, open that door); the radial asks
-- what you are IN (your engine, your lights, your boot).
-- ============================================

local _options   = {}     -- [id] = { label, group, condition, callback, owner, key }
local _byKey     = {}     -- ['<owner>\0<group>\0<data.id or label>'] = id — see AddOption
local _nextId    = 0
local _open      = false
local _shown     = {}     -- [id] = true — what is on screen right now, for select validation
local _hotkeys   = false  -- the pad opened it: the hotkeys wheel (pocket slots 1-5) is up beside the actions
local startWatch          -- the "close when it no longer applies" watcher; started on open, below

--- Is the wheel up? For client/ui.lua: a dialog does not open over it.
function RadialIsOpen() return _open end

-- The id of the "nothing to do here" placeholder. Prefixed so it can never collide with a real
-- registration id, which are always 'radial_<n>'.
local RADIAL_NONE = '__radial_none'

-- Is the wheel currently showing nothing but that placeholder? Read by the context watchdog,
-- which must not treat a deliberately empty wheel as one that has lost its reason to exist.
local _placeholderOnly = false

-- ============================================
-- Registration
-- ============================================

--- Register an option on the radial menu.
---
--- Registering the same option again replaces it (satellites re-register on every onReady). An
--- option is identified by who registered it, its group, and `data.id` (or its label when no id is
--- given). Pass `id` to have two options with the same label.
---@param data table { label, id?, group?, icon?, description?, condition?, callback }
---@return string|nil id
local function AddOption(data)
    if type(data) ~= 'table' then return nil end
    -- A string, or anything callable (read when the wheel opens — see CollectOptions).
    if data.label == nil or data.label == '' then return nil end

    -- Present, not `type(...) == 'function'`: a function handed over through an export is a
    -- callable whose Lua type is not 'function'. Both call sites pcall this.
    if data.callback == nil then return nil end

    -- Always whip_core: every caller is a whip_core file, and a satellite's wheel entry arrives
    -- through AddAction, which mounts it AS whip_core (not GetInvokingResource, which would name the
    -- satellite while the unmount looks for 'whip_core:act:...').
    local owner = GetCurrentResourceName()
    local key = owner .. '\0' .. tostring(data.group or '') .. '\0' .. tostring(data.id or data.label)

    -- The id handed to the NUI stays 'radial_<n>' — the key above holds a satellite's label,
    -- which has no business inside something the page uses as an identifier.
    local id = _byKey[key]
    if not id or not _options[id] then
        _nextId = _nextId + 1
        id = 'radial_' .. _nextId
        _byKey[key] = id
    end

    _options[id] = {
        id        = id,
        key       = key,
        -- The caller's own name for it (their id, else the label), so RadialRemove can take what
        -- they registered with rather than only the 'radial_<n>' handle.
        ownId     = tostring(data.id or data.label),
        label     = data.label,
        group     = data.group,
        -- The slab's picture and the pill's second line. Strings, or
        -- callables read when the wheel opens, like the label. Both optional: no icon draws the
        -- label's first letter, no description leaves the pill to the name.
        icon        = data.icon,
        description = data.description,
        -- Taken as given (an export's callable is not type 'function'). Guarded truthily and
        -- pcall'd below.
        condition = data.condition,
        callback  = data.callback,
        -- Offered while downed too (an action's `alive = false`). Set by client/actions.lua.
        allowDowned = data.allowDowned == true,
        -- Picking it keeps the wheel up (Seats): its callback shows a second page of the
        -- wheel with RadialPage.show. whip_core's own options only; AddAction never sets it.
        keepOpen  = data.keepOpen == true,
        owner     = owner,
    }
    return id
end

local function dropOption(id)
    local opt = _options[id]
    if not opt then return end
    if _byKey[opt.key] == id then _byKey[opt.key] = nil end
    _options[id] = nil
end

--- Remove one of the caller's own options: by the id (or label) it was registered with, or by the
--- 'radial_<n>' handle AddOption returned.
---@return boolean ok
---@return string|nil reason
local function RemoveOption(id)
    if id == nil then return false, 'which option?' end
    local owner = GetCurrentResourceName()   -- whip_core's, always: see AddOption
    local found = false
    for handle, opt in pairs(_options) do
        if opt.owner == owner and (handle == id or opt.ownId == tostring(id)) then
            dropOption(handle)
            found = true
        end
    end
    if not found then return false, ('no radial option "%s" of yours'):format(tostring(id)) end
    return true
end

--- Remove every one of the caller's own options in a group (only your own).
---@return boolean ok
---@return number|string countOrReason
local function RemoveGroup(group)
    if type(group) ~= 'string' or group == '' then return false, 'a group name is required' end
    local owner = GetCurrentResourceName()   -- whip_core's, always: see AddOption
    local n = 0
    for id, opt in pairs(_options) do
        if opt.group == group and opt.owner == owner then
            dropOption(id)
            n = n + 1
        end
    end
    return true, n
end

--- Is the wheel open? A question about the player's state, not a registration, so it stays.
exports('IsRadialOpen', function() return _open end)

-- Other resources put an option on the wheel with AddAction (`at = { radial = true }`,
-- client/actions.lua).

-- Globals, for whip_core's own files (client/actions.lua and client/vehicles.lua among them): one
-- Lua state, so they call the function rather than the export.
WhipRadialAddOption   = AddOption
WhipRadialRemove      = RemoveOption
WhipRadialRemoveGroup = RemoveGroup

-- A satellite that stops takes its options with it (a callback in a dead resource does nothing).
AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then return end
    for id, opt in pairs(_options) do
        if opt.owner == resource then dropOption(id) end
    end
end)

-- ============================================
-- Open / close
-- ============================================

--- Everything whose condition passes right now.
---
--- Conditions are pcall'd: one satellite's broken condition must not stop the wheel opening. A
--- condition that errors is treated as "no" (fail closed).
--- Did a condition say yes?
---
--- FiveM-truthy: yes on true or any non-zero number; no on false, nil and 0. Many GTA natives
--- answer 1/0 (IsPedInAnyVehicle), so a bare `if` passes 0 and `== true` rejects 1.
local function isTrue(v)
    if v == nil or v == false then return false end
    if v == 0 then return false end
    return true
end

--- Conditions that have thrown, reported once each rather than on every opening of the wheel.
local _conditionReported = {}

--- An option's icon or description: a string as it is, a callable asked now. One that throws or
--- answers nothing is left off — the wheel draws without it.
local function readText(v)
    if v == nil then return nil end
    if type(v) ~= 'string' then
        local good, res = pcall(v)
        v = (good and res ~= nil) and tostring(res) or nil
    end
    if v == '' then return nil end
    return v
end

local function CollectOptions()
    local list = {}
    local downed = PlayerIsDead == true
    for id, opt in pairs(_options) do
        local ok = not downed or opt.allowDowned
        if ok and opt.condition then
            local success, result = pcall(opt.condition)
            ok = success and isTrue(result)
            if not success and not _conditionReported[id] then
                _conditionReported[id] = true
                print(('[whip_core:radial] condition for "%s" (%s) errored — option hidden (reported once): %s')
                    :format(tostring(opt.ownId), tostring(opt.owner), tostring(result)))
            end
        end
        if ok then
            -- A label may be a function (client/actions.lua mounts `label = function(ctx) ... end`),
            -- read when the wheel opens. One that throws or answers nothing hides the option.
            local label = opt.label
            if type(label) ~= 'string' then
                local good, res = pcall(label)
                label = (good and res ~= nil) and tostring(res) or ''
            end
            if label ~= '' then
                list[#list + 1] = { id = id, label = label, icon = readText(opt.icon),
                                    desc = readText(opt.description), keep = opt.keepOpen or nil }
            end
        end
    end

    -- Stable order (pairs() is not), so options do not move between openings.
    table.sort(list, function(a, b)
        if a.label == b.label then return a.id < b.id end
        return a.label < b.label
    end)
    return list
end

--- The second page on screen (RadialPage.show), or nil on the first page.
local _page = nil

--- The page goes: its own onClose is told, so whatever kept it live stops.
local function endPage()
    local p = _page
    _page = nil
    if p and p.onClose then
        local ok, err = pcall(p.onClose)
        if not ok then print(('[whip_core:radial] page "%s" onClose errored: %s'):format(tostring(p.id), tostring(err))) end
    end
end

local function CloseRadial()
    if not _open then return end
    _open = false
    _shown = {}
    _hotkeys = false
    endPage()
    Focus.release('radial')
    SendNUIMessage({ action = 'uiRadialHide' })
end

--- Off; true here turns it on — this prints on every keypress when on.
RadialDebug = false

local function dbg(fmt, ...)
    if RadialDebug then
        print(('[whip_core:radial] ' .. fmt):format(...))
    end
end

--- The first page's list: what applies now, or the placeholder. Nil when a downed player has nothing
--- (DOWNED: only what opted in, allowDowned, and no "nothing here" placeholder: a dead player
--- pressing F1 with nothing for them sees nothing).
---@return table[]|nil
local function mainList()
    local list = CollectOptions()
    if PlayerIsDead and #list == 0 then return nil end

    -- It always opens, even with nothing to offer (a key that does nothing looks broken): one
    -- placeholder that closes on click.
    if #list == 0 then
        local total = 0
        for _ in pairs(_options) do total = total + 1 end
        dbg('opening empty: no options passed their condition (%d registered in total)', total)
        list = { { id = RADIAL_NONE, label = 'No actions available', desc = 'Nothing to do here right now',
                   placeholder = true } }
        _placeholderOnly = true
    else
        dbg('opening with %d option(s)', #list)
        _placeholderOnly = false
    end
    return list
end

--- Draw the first page: on opening (which takes the focus), and on coming back from a second one.
local function showMain(list, opening)
    _shown = {}
    for _, opt in ipairs(list) do _shown[opt.id] = true end
    -- The cursor starts in the middle, the wheel's centre (the wheel aims the mouse by its angle
    -- from there): it opens neutral, not on whatever the cursor was left pointing at. Before the
    -- focus is taken.
    SetCursorLocation(0.5, 0.5)
    if opening then Focus.take('radial', { screen = true }) end
    SendNUIMessage({ action = 'uiRadialShow', options = list, hotkeys = _hotkeys or nil })
end

--- Open the wheel. `fromPad`: D-pad down held (below), which brings the hotkeys wheel up too.
local function OpenRadial(fromPad)
    if _open then return end

    -- Every refusal says why, behind the debug flag.
    -- MayOpenScreen (client/inventory.lua): no other screen, bar, dialog or focus holder.
    if MayOpenScreen and not MayOpenScreen('radial') then
        dbg('not opening: another screen or dialog is up (MayOpenScreen)')
        return
    end
    local list = mainList()
    if not list then
        dbg('not opening: player is dead and no option is offered while downed')
        return
    end

    _open = true
    -- Two wheels on a pad: opened with the pad, the hotkeys 1-5 come up beside the
    -- actions — html/js/ui.js §5 draws them from the inventory the page holds, as the hotbar does. Not
    -- while downed: the hotbar's keys refuse a dead player too.
    _hotkeys = fromPad == true and not PlayerIsDead
    startWatch()
    showMain(list, true)
end

local function ToggleRadial()
    if _open then CloseRadial() else OpenRadial() end
end

-- ============================================
-- A second page (Seats)
-- ============================================
--
-- Picking an option registered with `keepOpen = true` does not close the wheel: its callback shows a
-- page of the wheel in the ring's place, with the centre disc and the pill kept. The page is
-- whip_core's (client/seats.lua is the one); the NUI draws it by its id (html/js/ui.js §5).
--   pick   A, a click, Enter: the wheel closes, then `onPick(value)`.
--   back   B, a right-click, Backspace: the first page again, as it is now.
--   close  Escape (or F1): the wheel closes.

RadialPage = {}

--- Show a page of the open wheel. `data` goes to the page as it is.
---@param page table { id = string, data = table, onPick = fn(value), onClose = fn()|nil }
---@return boolean shown  false when the wheel is not open
function RadialPage.show(page)
    if not _open or type(page) ~= 'table' or type(page.id) ~= 'string' then return false end
    endPage()
    _page = page
    _shown = {}   -- the first page is off screen: a late click on one of its options is refused
    SetCursorLocation(0.5, 0.5)
    SendNUIMessage({ action = 'uiRadialPage', page = page.id, data = page.data })
    return true
end

--- New data for the page on screen (someone took a seat). False when that page is not up.
function RadialPage.update(id, data)
    if not _open or not _page or _page.id ~= id then return false end
    SendNUIMessage({ action = 'uiRadialPageUpdate', page = id, data = data })
    return true
end

--- Open the wheel (F1's own path, with all its refusals). True when it is up.
function RadialPage.open()
    OpenRadial()
    return _open
end

--- Close the wheel, page and all.
function RadialPage.close() CloseRadial() end

-- ============================================
-- NUI
-- ============================================

RegisterNUICallback('radialSelect', function(data, cb)
    cb('ok')

    local id = data and data.id
    -- Must be something we put on screen this time: a click landing after the wheel closed (the
    -- exit animation outlives the close) cannot fire an option no longer offered.
    if not id or not _shown[id] then
        CloseRadial()
        return
    end

    -- The placeholder has no callback: clicking it just shuts the wheel.
    if id == RADIAL_NONE then
        CloseRadial()
        return
    end

    local opt = _options[id]
    if not opt then CloseRadial() return end
    -- An option that opens a second page keeps the wheel up for it (see RadialPage).
    if not opt.keepOpen then CloseRadial() end

    -- Activity log: which wheel option was picked (whip_autos' Whiplash entry, every
    -- satellite's actions — all of them, from this one dispatch site).
    --
    -- Empty is absent: '' is truthy in Lua, and the server's validator rejects an empty label.
    local logLabel = (type(opt.label) == 'string' and opt.label ~= '') and opt.label or '?'
    TriggerServerEvent('whip_core:server:interactionUsed', 'radial', logLabel:sub(1, 60))

    -- After the close, or a callback that opens another screen loses the NUI focus to the wheel's
    -- release a frame later.
    local ok, err = pcall(opt.callback)
    if not ok then
        print(('[whip_core:radial] callback for "%s" (%s) errored: %s')
            :format(tostring(opt.label), tostring(opt.owner), tostring(err)))
    end
    -- Kept open for a page that did not come (the callback refused, or threw): nothing to show.
    if opt.keepOpen and _open and not _page then CloseRadial() end
end)

RegisterNUICallback('radialClose', function(_, cb)
    cb('ok')
    CloseRadial()
end)

-- A hotkey picked on the pad's second wheel: the wheel closes, then that pocket slot is used as its
-- number key would be (Inventory.useHotbarSlot, client/inventory.lua). Only while that wheel is up — not a
-- late pick after it closed, nor from a page — and only slots 1-5. The server checks the slot again.
RegisterNUICallback('radialUseSlot', function(data, cb)
    cb('ok')
    local slot = type(data) == 'table' and math.tointeger(data.slot) or nil
    local ok = _open and _hotkeys and not _page and slot ~= nil and slot >= 1 and slot <= 5
    CloseRadial()
    if ok and slot then Inventory.useHotbarSlot(slot, true) end   -- no hotbar after: the wheel showed the slot
end)

-- A pick on the page on screen. Only that page's: a pick from a page that has gone closes the wheel.
RegisterNUICallback('radialPagePick', function(data, cb)
    cb('ok')
    local p = _page
    if not p or type(data) ~= 'table' or data.page ~= p.id then
        CloseRadial()
        return
    end
    CloseRadial()   -- the page's onClose, then the wheel; the pick runs on a closed wheel
    local ok, err = pcall(p.onPick, data.value)
    if not ok then
        print(('[whip_core:radial] page "%s" pick errored: %s'):format(tostring(p.id), tostring(err)))
    end
end)

-- Back from a page to the first one, as it is now. On the first page, back is close.
RegisterNUICallback('radialBack', function(_, cb)
    cb('ok')
    if not _open then return end
    if not _page then CloseRadial() return end
    endPage()
    local list = mainList()
    if not list then CloseRadial() return end
    showMain(list)
end)

-- ============================================
-- Key + context watchdog
-- ============================================

RegisterCommand('whip_radial', function()
    dbg('key pressed (open=%s)', tostring(_open))
    ToggleRadial()
end, false)

-- Hold D-pad down on a pad: Config.Controller.RadialHoldMs, then the wheel opens; B closes it
-- (html/js/ui.js, the 'radial' scope). A tap stays a prompt's "option down" (client/interact.lua).
-- client/pad.lua's reader runs '+' and '-' on D-pad down's press and release. In the wheel either
-- stick aims, A uses, D-pad left / right step; up and down do nothing, so the D-pad down still held
-- from opening it cannot move it. Opened this way it has two wheels: the actions on the left stick,
-- the hotkeys 1-5 on the right, one stick in control at a time.
local padHeld, padPress = false, 0

-- How long the hold is: each player's own (Settings → Server, client/player_prefs.lua), the server's figure the default.
PlayerPrefs.define({
    key = 'pad.radialHoldMs', group = 'Controller', type = 'slider', label = 'Hold for the radial menu',
    help = 'How long D-pad down is held before the radial menu opens.',
    min = 150, max = 2000, step = 50, unit = 'ms',
    default = function() return (Config.Controller and tonumber(Config.Controller.RadialHoldMs)) or 500 end,
})

RegisterCommand('+whip_radial_pad', function()
    if WhipPadDebugFire then WhipPadDebugFire('bind', 'radial (D-pad down)', WhipNavScopeOpen and 'ignored: a panel is open' or 'holding') end
    if WhipNavScopeOpen then return end   -- inside a panel D-pad down moves through it
    padPress = padPress + 1
    local press = padPress
    padHeld = true
    local holdMs = tonumber(PlayerPrefs.get('pad.radialHoldMs')) or 500
    SetTimeout(holdMs, function()
        if padHeld and press == padPress then
            dbg('pad hold (open=%s)', tostring(_open))
            OpenRadial(true)
            if WhipPadDebugFire then WhipPadDebugFire('bind', 'radial', 'held ' .. holdMs .. ' ms -> ' .. (_open and 'opened' or 'refused')) end
        end
    end)
end, false)
RegisterCommand('-whip_radial_pad', function() padHeld = false end, false)

-- F1 by default, and rebindable: Settings -> Key Bindings -> FiveM -> "Radial Menu". The default
-- only applies on a player's FIRST load; after that their own binding is kept.
--
-- F2 is the inventory, F3 the emote menu, M the phone (whip_phone), F6 chat, F7 the debug overlays,
-- and F8 belongs to the FiveM console.
RegisterKeyMapping('whip_radial', 'Radial Menu', 'keyboard', 'F1')

-- THE WHEEL FOLLOWS WHAT APPLIES WHILE IT IS UP, as the inventory's glovebox panel follows the seat
-- (client/vehicles.lua, the reconcile). Opened while getting into a car, it showed the on-foot
-- options until it was closed and opened again. Level-triggered, the same way: every pass the
-- conditions are run again and compared with what is on screen, so getting in, getting out or
-- anything else a condition reads redraws it, without any of them being named.
--
-- The SET of options is compared, not their words: a label that changes on its own (a countdown)
-- would redraw the wheel every pass and throw the player's aim away each time.
--
-- None left: a wheel that HAD something and lost it closes (out of the car with only car options
-- up); a wheel showing the placeholder is empty on purpose and stays. A second page keeps itself
-- honest (it closes the wheel when it no longer applies). Started when the wheel opens, ended when
-- it closes.
local watchRunning = false

--- Is `list` the set of options on the first page now?
local function sameAsShown(list)
    local n = 0
    for _ in pairs(_shown) do n = n + 1 end
    if n ~= #list then return false end
    for _, opt in ipairs(list) do
        if not _shown[opt.id] then return false end
    end
    return true
end

local function watch()
    while _open do
        Wait(250)
        if _open and not _page then
            local list = CollectOptions()
            if #list == 0 then
                if not _placeholderOnly then CloseRadial() end
            elseif _placeholderOnly or not sameAsShown(list) then
                dbg('options changed while open: %d now', #list)
                _placeholderOnly = false
                showMain(list)
            end
        end
    end
    watchRunning = false
end

startWatch = function()
    if watchRunning then return end
    watchRunning = true
    CreateThread(watch)
end

-- Never leave the cursor captured if the resource goes down with the wheel up.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    if _open then
        _open = false
        _page = nil
        Focus.release('radial')
    end
end)
