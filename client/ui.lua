-- UI library, client API: notifications, progress bars, dialogs, skill checks, drawtext.

UI = {}

local RESOURCE = GetCurrentResourceName()

-- Promise tracking for blocking components
local _promiseId = 0
local _promises  = {}

local function _nextId()
    _promiseId = _promiseId + 1
    return _promiseId
end

-- Active blocking component (only one at a time)
local _activeBlockingId = nil

--- What the active component is ('progress' or 'dialog') and which resource opened it (so a stopping resource
--- takes its dialog with it). IsAnyUIOpen asks UI.IsBusy.
local _activeKind  = nil
local _activeOwner = nil

--- [id] = true: a component cancelled before its page had it (a bar loads its anim and prop first).
local _cancelled = {}

-- The drawtext band's state, declared here because UI.Progress uses it too.
local _textOwner    = nil     -- who put the text up (see UI.ShowText)
local _textShown    = nil     -- { text, position, progress } of that text
local _barHoldsBand = false   -- a progress bar is using the band right now

-- ---- Stopped, not cancelled ----
-- When a bar or mode is stopped by something the player did not choose (killed, ragdolled), the hint capsule turns
-- red for INTERRUPT_MS with the why as its title. A bar: UI.Interrupt. A mode: UI.ShowInterrupted.

local INTERRUPT_MS = 2600

--- [id] = why: a bar UI.Interrupt ended, for UI.Progress to answer with.
local _interrupts = {}

--- The text ShowText had up before the failure, back once the failure has been seen, if nothing has taken the band since.
local function _restoreTextAfterFailure(shown)
    if not shown then return end
    SetTimeout(INTERRUPT_MS - 100, function()
        if _textShown ~= shown or _barHoldsBand or _activeBlockingId then return end
        SendNUIMessage({ action = 'uiShowText', text = shown.text, position = shown.position,
            progress = shown.progress, icon = shown.icon, tone = shown.tone })
    end)
end

--- Is a progress bar or dialog up? (Read by IsAnyUIOpen.)
---@return boolean
function UI.IsBusy()
    return _activeBlockingId ~= nil
end

--- Is the thing up a progress bar, as opposed to a dialog? The status HUD stays on for a bar.
---@return boolean
function UI.IsProgressActive()
    return _activeBlockingId ~= nil and _activeKind == 'progress'
end

--- Claim the one blocking slot for a component.
---@param kind string  'progress' | 'dialog'
---@param owner string|nil  the resource opening it
---@return number id
local function _claim(kind, owner)
    local id = _nextId()
    _promises[id] = promise.new()
    _activeBlockingId = id
    _activeKind       = kind
    _activeOwner      = owner or RESOURCE
    return id
end

--- Give the slot back. Every exit path of every component comes through here.
local function _release(id)
    _promises[id] = nil
    _cancelled[id] = nil
    if _activeBlockingId == id then
        _activeBlockingId = nil
        _activeKind       = nil
        _activeOwner      = nil
    end
end

--- Would this component open on top of somebody else's screen (declared with SetUIOpen)? Its owner may.
---@param owner string|nil
---@return boolean
local function _screenInTheWay(owner)
    return ExternalUIOpenForOthers ~= nil and ExternalUIOpenForOthers(owner) or false
end

--- Is one of whip's own focus-holding screens up (the composer, the radial wheel, the /whip panel)? Asked by the
--- dialogs, not by a bar. A dialog releases focus when it closes, which would leave the screen underneath dead.
--- The panel confirms inside itself (WP.confirm). The one list is FocusScreenUp in client/inventory.lua.
---@return boolean
local function _focusScreenUp()
    return FocusScreenUp ~= nil and FocusScreenUp('none') or false
end

--- Hold controls off while a progress bar runs, from the next frame until the flag drops.
--- The bar's choice: `disable = { move, combat, car }`. Default: no walking, no fighting, driving left alone.
--- `move = 'walk'`: walking allowed but no faster; trying to run cancels the bar.
--- Through BlockControls' one loop (client/controls.lua); the cancel key and walk mode are the block's per-frame hook.
local _lock = { walk = false, walkSettled = 0, cancel = false, exitVeh = nil }

--- The bar's every-frame part, run inside the control loop while the bar holds its block.
local function _barFrame()
    -- The cancel key is read as a game control (X is 73), so a bar takes no NUI focus. Disabled readers still hear a
    -- key another block holds off. 73 is A on a pad, and LB + A is talk: not a cancel while LB is held.
    if _lock.cancel and not WhipPadModHeld and IsDisabledControlJustPressed(0, 73) then UI.Cancel() end
    -- Getting out ends it (cancelOnExit): the exit press (75: F, or Y on a pad), or leaving the vehicle.
    local veh = _lock.exitVeh
    if veh then
        local ped = PlayerPedId()
        if veh == 0 or (not WhipPadModHeld and IsDisabledControlJustPressed(0, 75)) or GetVehiclePedIsIn(ped, false) ~= veh then
            _lock.exitVeh = nil   -- once: the bar is ending
            UI.Interrupt('You got out of the vehicle')
        end
    end
    if _lock.walk then
        local ped = PlayerPedId()
        SetPedMaxMoveBlendRatio(ped, 1.0)   -- a walk at most (2 is a jog, 3 a sprint); every frame, it does not stick
        -- Sprint is left live so it can be read: it ends the bar, as does running (after the first half second, so a
        -- jogger can slow to a walk). Not in a vehicle.
        if not IsPedInAnyVehicle(ped, false) then
            local sprinting = not WhipPadModHeld and IsDisabledControlPressed(0, 21) and GetEntitySpeed(ped) > 0.5
            local running = GetGameTimer() > _lock.walkSettled and (IsPedRunning(ped) or IsPedSprinting(ped))
            if sprinting or running then
                _lock.walk = false   -- once: the bar is ending
                UI.Interrupt('You started running')
            end
        end
    end
end

--- Hold off what the bar's `disable` says, from the next frame until _stopControlLock.
---@param disable table  { move = true|false|'walk', combat = bool, car = bool }
local function _startControlLock(disable)
    _lock.walk = disable.move == 'walk'
    _lock.walkSettled = GetGameTimer() + 500
    local groups, controls = {}, {}
    if disable.move ~= false and not _lock.walk then groups[#groups + 1] = 'move' end
    if _lock.walk then controls = { 22, 36, 44 } end   -- jump, duck, cover; sprint stays live (see _barFrame)
    if disable.combat ~= false then groups[#groups + 1] = 'combat' end
    if disable.car == true then groups[#groups + 1] = 'driving' end
    ControlBlocks.hold('progress', { groups = groups, controls = controls }, _barFrame)
end

local function _stopControlLock()
    ControlBlocks.release('progress')
end

-- ---- what a progress bar does to the player ----
-- Loads go through client/streaming.lua's LoadAnimDict / LoadModel, two seconds each.

--- Start the bar's animation (`{ dict, clip, flag }`, flag 49 by default: upper body, looping) and answer how to stop it.
--- Or a scenario (`{ scenario = 'WORLD_HUMAN_VEHICLE_MECHANIC' }`): a task with its own loop and props.
local function _startAnim(anim)
    if type(anim) ~= 'table' then return nil end
    if type(anim.scenario) == 'string' and anim.scenario ~= '' then
        TaskStartScenarioInPlace(PlayerPedId(), anim.scenario, 0, true)
        return function() ClearPedTasks(PlayerPedId()) end
    end
    if type(anim.dict) ~= 'string' or type(anim.clip) ~= 'string' then return nil end
    if not LoadAnimDict(anim.dict, 2000) then return nil end
    local ped = PlayerPedId()
    TaskPlayAnim(ped, anim.dict, anim.clip, 8.0, -8.0, -1, tonumber(anim.flag) or 49, 0, false, false, false)
    return function()
        StopAnimTask(PlayerPedId(), anim.dict, anim.clip, 1.0)
        RemoveAnimDict(anim.dict)
    end
end

-- The held props this game attached to its own player's hand: [netId] = { model, tag, bone, offset, rot }.
local ownHeld = {}

--- Tie a held prop to a ped's bone: the one way every held prop is tied (the server's place, or a pose).
local function tieHeld(obj, ped, bone, o, r)
    AttachEntityToEntity(obj, ped, GetPedBoneIndex(ped, tonumber(bone) or 18905),
        (tonumber(o[1]) or 0.0) + 0.0, (tonumber(o[2]) or 0.0) + 0.0, (tonumber(o[3]) or 0.0) + 0.0,
        (tonumber(r[1]) or 0.0) + 0.0, (tonumber(r[2]) or 0.0) + 0.0, (tonumber(r[3]) or 0.0) + 0.0,
        true, true, false, true, 1, true)
end

--- Held props are the server's (server/held_props.lua). Only the object's owner can attach, so the server sends it here.
RegisterNetEvent('whip_core:client:heldPropAttach', function(netId, holderNetId, bone, offset, rot, tag)
    if not NetworkDoesNetworkIdExist(netId) or not NetworkDoesNetworkIdExist(holderNetId) then return end
    local obj, ped = NetToObj(netId), NetToPed(holderNetId)
    -- Not ours (it changed hands on the way): the server asks the new owner next.
    if not DoesEntityExist(obj) or not DoesEntityExist(ped) or not NetworkHasControlOfEntity(obj) then return end
    local o, r = offset or {}, rot or {}
    SetEntityCollision(obj, false, false)
    tieHeld(obj, ped, bone, o, r)
    if ped == PlayerPedId() then
        ownHeld[netId] = { model = GetEntityModel(obj), tag = tag, bone = bone, offset = o, rot = r }
    end
    TriggerServerEvent('whip_core:server:heldPropAttached', netId)
end)

--- This player's own held prop of `tag`'s set and of `model` (a hash), in their hand on this game, or nil.
---@param model number
---@param tag string
---@return number|nil entity
function UI.ownHeldProp(model, tag)
    local want = (tonumber(model) or 0) % 0x100000000
    for netId, rec in pairs(ownHeld) do
        if rec.tag == tag and (rec.model % 0x100000000) == want and NetworkDoesNetworkIdExist(netId) then
            local obj = NetToObj(netId)
            if DoesEntityExist(obj) and GetEntityAttachedTo(obj) == PlayerPedId() then return obj end
        end
    end
    return nil
end

--- Sit this player's own held prop (`tag`, `model` hash) another way in the hand: `pose` = { bone, offset = {x,y,z},
--- rot = {x,y,z} } (bone defaults to the server's), or nil for the server's place. Only while this game holds it.
--- Answers whether it moved.
---@param model number
---@param tag string
---@param pose table|nil
---@return boolean
function UI.setOwnHeldPropPose(model, tag, pose)
    local want = (tonumber(model) or 0) % 0x100000000
    local ped = PlayerPedId()
    for netId, rec in pairs(ownHeld) do
        if rec.tag == tag and (rec.model % 0x100000000) == want and NetworkDoesNetworkIdExist(netId) then
            local obj = NetToObj(netId)
            if DoesEntityExist(obj) and NetworkHasControlOfEntity(obj) and GetEntityAttachedTo(obj) == ped then
                local p = type(pose) == 'table' and pose or rec
                tieHeld(obj, ped, p.bone or rec.bone, type(p.offset) == 'table' and p.offset or {},
                    type(p.rot) == 'table' and p.rot or {})
                return true
            end
        end
    end
    return false
end

--- A hand that let go (a throw) takes its own held prop away at once when this game holds it. The server is still told
--- (heldPropsDrop). Only props of `tag`'s set and `model` attached to this player's ped by this game, rechecked on
--- the object, so a reused id is never deleted.
---@param model number
---@param tag string  'give' | 'nozzle'
function UI.dropOwnHeldProp(model, tag)
    local want = (tonumber(model) or 0) % 0x100000000
    for netId, rec in pairs(ownHeld) do
        if not NetworkDoesNetworkIdExist(netId) then
            ownHeld[netId] = nil   -- gone (another game deleted it): forgotten here too
        elseif rec.tag == tag and (rec.model % 0x100000000) == want then
            ownHeld[netId] = nil
            local obj = NetToObj(netId)
            if DoesEntityExist(obj) and NetworkHasControlOfEntity(obj)
                and (GetEntityModel(obj) % 0x100000000) == want
                and GetEntityAttachedTo(obj) == PlayerPedId() then
                DetachEntity(obj, false, false)
                SetEntityAsMissionEntity(obj, true, true)
                DeleteEntity(obj)
            end
        end
    end
end

--- The owner deletes it when it leaves the hand (the server asks). The model must match, in case the id names
--- something else. Not ours any more: the server asks the new owner.
RegisterNetEvent('whip_core:client:heldPropDelete', function(netId, model)
    ownHeld[netId] = nil
    if not NetworkDoesNetworkIdExist(netId) then return end
    local obj = NetToObj(netId)
    if not DoesEntityExist(obj) or not NetworkHasControlOfEntity(obj) then return end
    -- Compared as unsigned: a hash can cross the network as either sign.
    if (GetEntityModel(obj) % 0x100000000) ~= ((tonumber(model) or 0) % 0x100000000) then return end
    DetachEntity(obj, false, false)
    SetEntityAsMissionEntity(obj, true, true)
    DeleteEntity(obj)
end)

--- A client-run bar's prop (`{ model, bone, offset, rot }`) asked of the server, which only makes models it has
--- vouched for. Answers how to take it away again.
local function _barProp(prop)
    if type(prop) ~= 'table' or type(prop.model) ~= 'string' then return nil end
    local function three(t)
        t = type(t) == 'table' and t or {}
        return { tonumber(t.x or t[1]) or 0.0, tonumber(t.y or t[2]) or 0.0, tonumber(t.z or t[3]) or 0.0 }
    end
    TriggerServerEvent('whip_core:server:barProp', prop.model, math.floor(tonumber(prop.bone) or 18905),
        three(prop.offset), three(prop.rot))
    return function() TriggerServerEvent('whip_core:server:heldPropsDrop', 'bar') end
end

--- Wait for a blocking component's answer, but not forever: after `timeoutMs` it is cancelled on screen and the
--- caller gets nil, as for Escape. Answers the result and whether it timed out.
---@param id number
---@param timeoutMs number
---@return any result
---@return boolean timedOut
local function _await(id, timeoutMs)
    local p = _promises[id]
    local timedOut = false
    SetTimeout(timeoutMs, function()
        if _promises[id] == p then
            timedOut = true
            SendNUIMessage({ action = 'uiCancel', id = id })
            p:resolve(nil)
        end
    end)
    local result = Citizen.Await(p)
    return result, timedOut
end

-- ---- why a component came back without an answer ----
-- Every component answers a second value when it has no answer ("the player said no" vs "another dialog was up").
local BUSY      = 'busy'        -- another bar or dialog was up, or another resource's screen
local CANCELLED = 'cancelled'   -- the player backed out (Escape, the Cancel button, the owner stopping)
local TIMEOUT   = 'timeout'     -- no answer from the page in time
local FAILED    = 'failed'      -- a skill check the player did not pass
local REFUSED   = 'refused'     -- a bar that never started: the player is in a state it refuses (notWhile)

--- The reason for an empty answer: the timeout, or else what the player did.
local function _why(timedOut, otherwise)
    if timedOut then return TIMEOUT end
    return otherwise or CANCELLED
end

local DIALOG_TIMEOUT_MS = 300000   -- five minutes: a person reading or typing, not a stuck page

-- Close the inventory (global, client/inventory.lua) before starting a blocking UI component.
local function _ensureInventoryClosed()
    if Inventory.close and Inventory.isOpen and Inventory.isOpen() then
        Inventory.close()
    end
end

-- ---- Universal NUI result callback ----

RegisterNUICallback('uiResult', function(data, cb)
    local id = data.id
    if id and _promises[id] then
        _promises[id]:resolve(data.result)
        _promises[id] = nil
    end
    -- Each UI.* function releases focus after Await returns; not here, or it races with the caller re-acquiring it.
    if _activeBlockingId == id then
        _release(id)
        _stopControlLock()
    end
    cb('ok')
end)

-- ---- Notifications (fire and forget) ----

--- Show a notification toast.
--- @param text string — message text
--- @param type? string — 'success', 'error', 'info', 'warning' (default: 'info')
--- @param duration? number — ms to show (default: 3000)
function UI.Notify(text, type, duration)
    SendNUIMessage({
        action   = 'uiNotify',
        text     = tostring(text or ''),
        type     = type or 'info',
        duration = duration or 3000,
    })
end

-- ---- Progress bar (blocking) ----

--- A bar's `item`, as the page takes it: { item, metadata, amount }, or nil for none (or a key that is not one).
local function barItem(v)
    if type(v) == 'string' then
        if v == '' or #v > 64 then return nil end
        return { item = v }
    end
    if type(v) ~= 'table' or type(v.item) ~= 'string' or v.item == '' or #v.item > 64 then return nil end
    return { item = v.item, metadata = type(v.metadata) == 'table' and v.metadata or nil, amount = tonumber(v.amount) }
end

--- Show a progress bar that fills over `duration` ms.
---
--- Two forms: Progress(label, duration, opts) or Progress({ label, duration, canCancel, ... }).
---
--- What the bar does to the player is part of the call:
---   anim          { dict, clip, flag }  played for the length of the bar (flag 49: upper body)
---   prop          { model, bone, offset, rot }  in the player's hand for the length of the bar
---   disable       { move, combat, car }  what is held off (default: move and combat, not driving);
---                 move = 'walk' lets them walk, and trying to run cancels the bar
---   cancelOnDeath dying ends the bar as cancelled (default true)
---   cancelOnExit  getting out of the vehicle the bar began in cancels it (default false); not in a vehicle: cancelled at once
---   notWhile      { 'swimming', 'underwater', 'falling' }: the bar is 'refused' in one, and cancelled if one begins.
---                 'swimming' covers under water too (shared/body_state.lua)
---   icon          a glyph's name (html/js/glyphs.js: 'eat', 'fuel'...) for the capsule's disc, which fills as the bar does
---   item          what the bar is done with: an item's key, or a slot's data { item, metadata }. The disc shows its
---                 picture instead of filling; an item with no picture shows the icon
--- @param label string|table — text above the bar, or every option in one table
--- @param duration? number — ms to fill (default 3000)
--- @param opts table|nil — { canCancel, anim, prop, disable, cancelOnDeath, cancelOnExit, notWhile, icon, item }
--- @param owner string|nil — the resource asking (the export fills it in)
--- @return boolean completed
--- @return string|nil why — 'busy' | 'cancelled' | 'timeout' | 'refused' when it did not complete
--- @return string|nil words — what stopped or refused it, as the capsule said ('You were knocked down')
function UI.Progress(label, duration, opts, owner)
    if type(label) == 'table' then
        opts = label
        label, duration = opts.label, opts.duration
    end
    owner = owner or RESOURCE

    -- Checked before the slot is taken: a bad duration must not throw after the controls are locked.
    if duration == nil then duration = 3000 end
    duration = tonumber(duration)
    if not duration or not (duration > 0) or duration == math.huge then
        return false, 'duration must be a positive number of milliseconds'
    end
    if opts ~= nil and type(opts) ~= 'table' then return false, 'opts must be a table' end
    local notWhile, notWhileErr = BodyState.readList(opts and opts.notWhile)
    if not notWhile then return false, notWhileErr end

    if _activeBlockingId or _screenInTheWay(owner) then return false, BUSY end
    -- Swimming, under water or falling with notWhile set: it never starts, and says why.
    local refused = BodyState.refuses(notWhile, BodyState.of(PlayerPedId()))
    if refused then
        UI.ShowInterrupted(refused, label)
        return false, REFUSED, refused
    end
    _ensureInventoryClosed()
    -- End any emote before the bar starts, so its props go with it.
    if Emotes ~= nil then Emotes.stop() end
    opts = opts or {}
    local id = _claim('progress', owner)

    local stopAnim, dropProp
    local cancelledEarly = false

    -- Everything after the claim, guarded: whatever throws, the cleanup below still runs.
    local ok, result, timedOut = pcall(function()
        _startControlLock(type(opts.disable) == 'table' and opts.disable or {})

        stopAnim = _startAnim(opts.anim)
        dropProp = _barProp(opts.prop)

        -- Cancelled while those loaded? Then it never shows (the page did not know this id yet).
        if _cancelled[id] then
            cancelledEarly = true
            return nil, false
        end

        -- Dying, being knocked down, a long fall, or a state the bar refuses (notWhile) ends it. Each says why (UI.Interrupt).
        local watchDeath = opts.cancelOnDeath ~= false
        if watchDeath or next(notWhile) then
            CreateThread(function()
                while _activeBlockingId == id do
                    local ped = PlayerPedId()
                    if watchDeath and (PlayerIsDead or IsEntityDead(ped)) then
                        UI.Interrupt('You went down')
                        break
                    end
                    if watchDeath and IsPedRagdoll(ped) then
                        UI.Interrupt(BodyState.ragdollWhy(ped))
                        break
                    end
                    local stopped = BodyState.refuses(notWhile, BodyState.of(ped))
                    if stopped then
                        UI.Interrupt(stopped)
                        break
                    end
                    Wait(200)
                end
            end)
        end
        -- No NUI focus: the game keeps its input, and X is read by the control lock (see above).
        _lock.cancel = opts.canCancel == true
        -- The vehicle it began in, for the lock's getting-out check (0: not in one, so it ends at once).
        if opts.cancelOnExit == true then _lock.exitVeh = GetVehiclePedIsIn(PlayerPedId(), false) end
        -- The bar is drawn on the drawtext band: it holds the band while it runs (see UI.ShowText).
        _barHoldsBand = true
        SendNUIMessage({
            action    = 'uiProgressBar',
            id        = id,
            label     = label or '',
            duration  = duration,
            canCancel = opts.canCancel or false,
            icon      = type(opts.icon) == 'string' and opts.icon or nil,
            item      = barItem(opts.item),
        })
        return _await(id, duration + 10000)
    end)

    local interrupted = _interrupts[id]
    _interrupts[id] = nil
    _release(id)
    _stopControlLock()
    _lock.cancel = false
    _lock.exitVeh = nil
    if stopAnim then pcall(stopAnim) end
    if dropProp then pcall(dropProp) end
    if _barHoldsBand then
        _barHoldsBand = false
        if interrupted then
            -- The page turned the bar red (UI.Interrupt); the text it held comes back once seen.
            _restoreTextAfterFailure(_textShown)
        elseif _textShown then
            SendNUIMessage({ action = 'uiShowText', text = _textShown.text,
                position = _textShown.position, progress = _textShown.progress,
                icon = _textShown.icon, tone = _textShown.tone })
        end
    end

    if not ok then
        print(('[whip_core:ui] progress bar failed: %s'):format(tostring(result)))
        return false, CANCELLED
    end
    if cancelledEarly then return false, CANCELLED, interrupted end
    if result == true then return true end
    return false, _why(timedOut), interrupted
end

-- ---- Input dialog (blocking, focus) ----

--- Show an input dialog with custom fields. Every blocking component closes the inventory first.
---
--- Two forms: Input(title, fields) or Input({ title, fields }).
--- @param title string|table
--- @param fields table — array of { label, type, placeholder, default, required, min, max, options }
--- @param owner string|nil — the resource asking (the export fills it in)
--- @return table|false values — { [1] = val, [2] = val, ... }, or false when there is no answer
--- @return string|nil why — 'busy' | 'cancelled' | 'timeout'
function UI.Input(title, fields, owner)
    if type(title) == 'table' then
        fields, title = title.fields, title.title
    end
    owner = owner or RESOURCE
    -- False, not nil, when there is no answer: an export's return list stops at its first nil, losing the reason.
    if _activeBlockingId or _screenInTheWay(owner) or _focusScreenUp() then return false, BUSY end
    _ensureInventoryClosed()
    local id = _claim('dialog', owner)
    Focus.take('dialog')
    SendNUIMessage({
        action = 'uiInput',
        id     = id,
        title  = title or 'Input',
        fields = fields or {},
    })
    local result, timedOut = _await(id, DIALOG_TIMEOUT_MS)
    _release(id)
    Focus.release('dialog')
    if type(result) == 'table' then return result end
    return false, _why(timedOut)
end

-- ---- Skill check (blocking) ----

--- The check's hands are read here, not by the page (it takes no NUI focus). While check `id` is up this reads both
--- hands through the game and posts them to the page:
---   mouse  the game's mouse look (1/2): distance moved this frame (uiSkillMouse). Only while no pad is the device.
---   pad    the frontend right stick (197/198) as uiSkillStick: every real move, and always the return to rest.
---          Stick-up arrives negative, which is up on the page.
--- The game is held still with every control off (the 'skillCheck' control block, all = true), read by the block's
--- per-frame hook with the disabled readers. Let go when the check ends.
---@param id number
local function _readHandsFor(id)
    local lastX, lastY = 0.0, 0.0
    ControlBlocks.hold('skillCheck', { all = true }, function()
        if _activeBlockingId ~= id then ControlBlocks.release('skillCheck') return end
        if WhipPadActive then
            local x = GetDisabledControlNormal(0, 197)
            local y = GetDisabledControlNormal(0, 198)
            -- Every real move, and always the return to rest, so the dot ends centred.
            local rest = x == 0 and y == 0 and (lastX ~= 0 or lastY ~= 0)
            if rest or math.abs(x - lastX) > 0.02 or math.abs(y - lastY) > 0.02 then
                lastX, lastY = x, y
                SendNUIMessage({ action = 'uiSkillStick', id = id, x = x, y = y })
            end
        else
            local mx = GetDisabledControlNormal(0, 1)
            local my = GetDisabledControlNormal(0, 2)
            if mx ~= 0 or my ~= 0 then
                SendNUIMessage({ action = 'uiSkillMouse', id = id, x = mx, y = my })
            end
        end
    end)
end

-- ---- Skill check games from other resources (server/skillcheck.lua) ----
-- The client half of a game: the owner's entry function (Whip.skillCheckGame). entry('start', { token, difficulty })
-- plays it in its own thread and answers with SkillCheckGameDone(token, passed, why); entry('cancel', { token })
-- calls it off. It holds the one blocking slot while it plays.

local _gameRun = nil      -- the game playing now: { token, game, owner, id, entry }
local _gameToken = 0

--- Call the game playing now off (the server gave up, UI.Cancel): its owner is told, and its caller hears `why`.
local function _endGame(why)
    local run = _gameRun
    if not run then return end
    _gameRun = nil
    pcall(run.entry, 'cancel', { token = run.token })
    local p = _promises[run.id]
    if p then p:resolve(why or CANCELLED) end
end

local _games = Registry.new('skillCheckGame', {
    label = 'skill check game',
    same = false,   -- a fresh entry function each time
    -- Its owner stopped mid-game: the check ends, cancelled.
    onRemove = function(key) if _gameRun and _gameRun.game == key then _endGame(CANCELLED) end end,
})

--- RegisterSkillCheckGame(id, entry) -> true | false, why: the client half of a game. Use Whip.skillCheckGame.
exports('RegisterSkillCheckGame', function(id, entry)
    local owner = GetInvokingResource() or RESOURCE
    if type(id) ~= 'string' or not id:match('^[a-z][a-z0-9_]*%.[a-z][a-z0-9_]*$') then
        return false, 'a skill check game id is "<yours>.<name>"'
    end
    if entry == nil or (type(entry) ~= 'function' and type(entry) ~= 'table') then
        return false, id .. ': its entry is missing (use Whip.skillCheckGame)'
    end
    return _games:add(owner, id, entry)
end)

exports('RemoveSkillCheckGame', function(id)
    return _games:remove(GetInvokingResource() or RESOURCE, id)
end)

--- SkillCheckGameDone(token, passed, why) -> true | false: the game's answer. Only from the game's owner, for
--- the game playing now.
local GAME_WHY = { failed = true, cancelled = true, timeout = true, busy = true }
exports('SkillCheckGameDone', function(token, passed, why)
    local by = GetInvokingResource() or RESOURCE
    local run = _gameRun
    if not run or run.token ~= token or run.owner ~= by then return false end
    _gameRun = nil
    local p = _promises[run.id]
    if p then p:resolve(passed == true or (GAME_WHY[why] and why) or FAILED) end
    return true
end)

--- Play another resource's game (the skill check's `game`). Answers as UI.SkillCheck does: 'unavailable' when no
--- running resource has that game, 'not started' when its client canStart says no (not a fail; they are told why).
---@param game string
---@param difficulty string|nil
---@param owner string  who asked
---@param serverAsked boolean|nil  the server's SkillCheck: its canStart was asked there
---@return boolean passed
---@return string|nil why
local function _playGame(game, difficulty, owner, serverAsked)
    local entry = _games:get(game)
    if not entry then return false, 'unavailable' end
    -- (An error from canStart means it may start.)
    local askOk, may = true, nil
    if not serverAsked then askOk, may = pcall(entry, 'canStart', {}) end
    if askOk and type(may) == 'table' and may.ok == false then
        if type(may.words) == 'string' and may.words ~= '' then UI.Notify(may.words, 'error') end
        return false, 'not started'
    end
    local gameOwner = _games:ownerOf(game)
    -- The game's own screen does not count as in the way.
    if _activeBlockingId or _screenInTheWay(gameOwner) or _focusScreenUp() then return false, BUSY end
    _ensureInventoryClosed()
    local id = _claim('dialog', owner)
    _gameToken = _gameToken + 1
    local run = { token = _gameToken, game = game, owner = gameOwner, id = id, entry = entry }
    _gameRun = run
    local ok, res = pcall(entry, 'start', { token = run.token, difficulty = type(difficulty) == 'string' and difficulty or 'medium' })
    if not ok or type(res) ~= 'table' or res.err then
        print(('[whip_core] skill check game %s could not start: %s'):format(game, tostring(ok and (type(res) == 'table' and res.err or 'no answer') or res)))
        if _gameRun == run then _gameRun = nil end
        _release(id)
        return false, 'unavailable'
    end
    -- The game keeps its own clock; this is the stuck-game backstop, past any game's server timeout.
    local result, timedOut = _await(id, 125000)
    if _gameRun == run then
        _gameRun = nil
        pcall(entry, 'cancel', { token = run.token })
    end
    _release(id)
    if result == true then return true end
    return false, _why(timedOut, type(result) == 'string' and result or CANCELLED)
end

--- Run a skill check: the ring. Part of a ring lights up; the player pushes the dot onto it and holds it until it
--- fills (holdMs), then again on a smaller part, one round per entry in the difficulty's `rounds`. Touching the ring
--- outside the lit part fails. The mouse or a pad's right stick moves the dot; no keyboard.
---
--- Forms: SkillCheck(difficulty), SkillCheck({ difficulty }), SkillCheck({ difficulty, game }) for another resource's
--- game, or SkillCheck({ level = { pieces, parts, widest, narrowest, msPerPart, holdMs?, mouseSpeed? } }) for the
--- caller's own numbers (shared/skillcheck.lua). This is the client's claim; rewards belong behind the server's SkillCheck.
--- @param difficulty string|table|nil — 'easy' | 'medium' | 'hard' (Config.SkillCheckDifficulty; default 'medium')
--- @param owner string|nil — the resource asking (the export fills it in)
--- @return boolean passed
--- @return string|nil why — 'failed' | 'busy' | 'cancelled' | 'timeout' when not passed ('unavailable': no such game;
--- 'not started': the game's canStart said they cannot play it, and they were told why: not a fail)
function UI.SkillCheck(difficulty, owner)
    owner = owner or RESOURCE
    if type(difficulty) == 'table' and difficulty.game ~= nil and difficulty.game ~= 'ring' then
        return _playGame(tostring(difficulty.game), difficulty.difficulty, owner)
    end
    if type(difficulty) == 'table' and difficulty.game ~= nil then difficulty = { difficulty = difficulty.difficulty, level = difficulty.level } end

    -- Checked before the slot is taken and refused with the reason: a bad difficulty must not read as 'failed'.
    local level, bad = SkillCheckLevel(difficulty)
    if not level then return false, bad end

    if _activeBlockingId or _screenInTheWay(owner) or _focusScreenUp() then return false, BUSY end
    _ensureInventoryClosed()
    local id = _claim('dialog', owner)
    -- No NUI focus: the hands are read through the game (_readHandsFor).
    SendNUIMessage({
        action = 'uiSkillCheck',
        id     = id,
        level  = level,
    })
    _readHandsFor(id)
    -- The ring has no clock; this is only the stuck-page backstop: 'timeout' after a minute.
    local result, timedOut = _await(id, 60000)
    _release(id)
    ControlBlocks.release('skillCheck')
    if result == true then return true end
    -- The page answers false for a miss and nothing for a cancelled check.
    return false, _why(timedOut, result == false and FAILED or CANCELLED)
end

-- ---- Alert dialog (blocking, focus) ----

--- Show an alert dialog (single OK button).
---
--- Two forms: Alert(title, message, btnText) or Alert({ title, message, button }).
--- @param title string|table
--- @param message string
--- @param btnText string|nil — default 'OK'
--- @param owner string|nil — the resource asking (the export fills it in)
--- @return boolean seen — true once the player pressed the button
--- @return string|nil why — 'busy' | 'cancelled' | 'timeout'
function UI.Alert(title, message, btnText, owner)
    if type(title) == 'table' then
        message, btnText, title = title.message, title.button, title.title
    end
    owner = owner or RESOURCE
    if _activeBlockingId or _screenInTheWay(owner) or _focusScreenUp() then return false, BUSY end
    _ensureInventoryClosed()
    local id = _claim('dialog', owner)
    Focus.take('dialog')
    SendNUIMessage({
        action  = 'uiAlert',
        id      = id,
        title   = title or 'Alert',
        message = message or '',
        btnText = btnText or 'OK',
    })
    local result, timedOut = _await(id, DIALOG_TIMEOUT_MS)
    _release(id)
    Focus.release('dialog')
    if result == true then return true end
    return false, _why(timedOut)
end

-- ---- Confirm dialog (blocking, focus) ----

--- Show a confirm dialog (Yes/No).
---
--- Two forms: Confirm(title, message, confirmText, cancelText) or
--- Confirm({ title, message, yes, no }).
--- @param title string|table
--- @param message string
--- @param confirmText string|nil — default 'Confirm'
--- @param cancelText string|nil — default 'Cancel'
--- @param owner string|nil — the resource asking (the export fills it in)
--- @return boolean yes
--- @return string|nil why — 'cancelled' (they said no) | 'busy' | 'timeout'
function UI.Confirm(title, message, confirmText, cancelText, owner)
    if type(title) == 'table' then
        message, confirmText, cancelText, title = title.message, title.yes, title.no, title.title
    end
    owner = owner or RESOURCE
    if _activeBlockingId or _screenInTheWay(owner) or _focusScreenUp() then return false, BUSY end
    _ensureInventoryClosed()
    local id = _claim('dialog', owner)
    Focus.take('dialog')
    SendNUIMessage({
        action      = 'uiConfirm',
        id          = id,
        title       = title or 'Confirm',
        message     = message or '',
        confirmText = confirmText or 'Confirm',
        cancelText  = cancelText or 'Cancel',
    })
    local result, timedOut = _await(id, DIALOG_TIMEOUT_MS)
    _release(id)
    Focus.release('dialog')
    if result == true then return true end
    return false, _why(timedOut)
end

-- ---- DrawText (non-blocking) ----

--- Who put the text up, or nil when none is showing. One slot with an owner: a HideText from someone else leaves it
--- alone, the owner stopping takes it down, and showing takes the slot from whoever had it.
--- A progress bar holds the band while it runs: text shown meanwhile appears when the bar ends, a HideText meanwhile
--- forgets it, and the text from before the bar comes back.

--- Show persistent instruction text: the hint capsule. Controls one part each: '[E] Place Burger  |  [Scroll] Rotate'.
--- The first part is the title, the rest a row under it; a short [Key] draws as a keycap, {pad:a} as a button picture.
---
--- Forms: ShowText(text, position, progress) or ShowText(text, { position, progress, icon, tone }):
---   icon  a glyph name in html/js/glyphs.js for the disc (what is being done); without one it shows the first key.
---   tone  'warn': the ring turns amber (it cannot be done here).
--- @param text string — e.g., '[E] Open Door'
--- @param position string|table|nil — 'bottom' (default) or 'top'; or every option in one table
--- @param progress number|nil — 0-100 progress bar percentage (nil = no bar)
--- @param owner string|nil — the resource asking (the export fills it in)
function UI.ShowText(text, position, progress, owner)
    local icon, tone
    if type(position) == 'table' then
        local o = position
        position, progress, icon, tone = o.position, o.progress, o.icon, o.tone
    end
    _textOwner = owner or RESOURCE
    _textShown = {
        text     = tostring(text or ''),
        position = position or 'bottom',
        progress = progress,
        icon     = type(icon) == 'string' and icon or nil,
        tone     = tone == 'warn' and 'warn' or nil,
    }
    if _barHoldsBand then return end   -- shown when the bar ends
    SendNUIMessage({
        action   = 'uiShowText',
        text     = _textShown.text,
        position = _textShown.position,
        progress = _textShown.progress,
        icon     = _textShown.icon,
        tone     = _textShown.tone,
    })
end

--- Hide the persistent instruction text, if it is the caller's (no owner means whip_core).
--- @param owner string|nil — the resource asking (default whip_core)
--- @return boolean hidden
function UI.HideText(owner)
    owner = owner or RESOURCE
    if _textOwner and owner ~= _textOwner then return false end
    _textOwner = nil
    _textShown = nil
    -- Not while a bar holds the band: forgotten instead, so it does not come back when the bar ends.
    if not _barHoldsBand then SendNUIMessage({ action = 'uiHideText' }) end
    return true
end

-- ---- Cancel active component (e.g. on resource stop) ----

function UI.Cancel()
    -- Another resource's game holds the slot: it is called off where it plays (the phone's: put away).
    if _gameRun and _gameRun.id == _activeBlockingId then return _endGame(CANCELLED) end
    if _activeBlockingId then
        -- Remembered as well as sent: a bar still loading has not reached the page and checks this.
        _cancelled[_activeBlockingId] = true
        SendNUIMessage({ action = 'uiCancel', id = _activeBlockingId, why = _interrupts[_activeBlockingId] })
    end
end

--- End the bar because something the player did not choose stopped it (see "Stopped, not cancelled"). The capsule
--- turns red and says `why`; its caller gets `false, 'cancelled', why`. Not a bar (a dialog): an ordinary cancel.
---@param why string  plain words: 'You were knocked down'
function UI.Interrupt(why)
    if not _activeBlockingId then return end
    if _activeKind == 'progress' and type(why) == 'string' and why ~= '' then
        _interrupts[_activeBlockingId] = why
    end
    UI.Cancel()
end

--- Interrupt the bar, only one `owner` started (whip_core may interrupt any).
---@param why string
---@param owner string|nil
---@return boolean interrupted  false when no bar is up, or it is someone else's
function UI.InterruptProgress(why, owner)
    owner = owner or RESOURCE
    if not UI.IsProgressActive() then return false end
    if owner ~= RESOURCE and owner ~= _activeOwner then return false end
    UI.Interrupt(why)
    return true
end

--- Show that something which is not a bar stopped (give mode, placing) on the hint capsule: red, `why` as title and
--- `what` under it, for a moment. Call it before taking the mode's own text down. Not while a bar holds the band.
---@param why string   plain words: 'You went down'
---@param what string|nil  what it stopped: 'Giving Burger'
---@return boolean shown
function UI.ShowInterrupted(why, what)
    if type(why) ~= 'string' or why == '' or _barHoldsBand then return false end
    SendNUIMessage({ action = 'uiInterrupted', why = why, what = type(what) == 'string' and what or nil, ms = INTERRUPT_MS })
    _restoreTextAfterFailure(_textShown)
    return true
end

--- Cancel the progress bar, only one `owner` started (whip_core may cancel any). The caller gets `false, 'cancelled'`.
---@param owner string|nil
---@return boolean cancelled  false when no bar is up, or it is someone else's
function UI.CancelProgress(owner)
    owner = owner or RESOURCE
    if not UI.IsProgressActive() then return false end
    if owner ~= RESOURCE and owner ~= _activeOwner then return false end
    UI.Cancel()
    return true
end

-- ---- Exports ----

-- The caller is read here at the boundary and handed in: GetInvokingResource is only right before anything yields.
local function caller() return GetInvokingResource() or RESOURCE end

exports('Notify', UI.Notify)
exports('Progress', function(label, duration, opts) return UI.Progress(label, duration, opts, caller()) end)
exports('Input', function(title, fields) return UI.Input(title, fields, caller()) end)
exports('SkillCheck', function(difficulty) return UI.SkillCheck(difficulty, caller()) end)
exports('Alert', function(title, message, btnText) return UI.Alert(title, message, btnText, caller()) end)
exports('Confirm', function(title, message, confirmText, cancelText)
    return UI.Confirm(title, message, confirmText, cancelText, caller())
end)
exports('ShowText', function(text, position, progress) return UI.ShowText(text, position, progress, caller()) end)
exports('HideText', function() return UI.HideText(caller()) end)

-- A resource's own held props (server: HoldProps, tags named '<resource>:<tag>') in this player's hand on this game:
-- found, let go of at once (the resource still tells its own server), or sat another way for a while.
local function heldHash(model) return type(model) == 'number' and model or GetHashKey(tostring(model)) end
exports('GetOwnHeldProp', function(model, tag)
    return UI.ownHeldProp(heldHash(model), caller() .. ':' .. tostring(tag or 'held'))
end)
exports('DropOwnHeldProp', function(model, tag)
    return UI.dropOwnHeldProp(heldHash(model), caller() .. ':' .. tostring(tag or 'held'))
end)
exports('SetOwnHeldPropPose', function(model, tag, pose)
    return UI.setOwnHeldPropPose(heldHash(model), caller() .. ':' .. tostring(tag or 'held'), pose)
end)

-- The band from the server (ShowPlayerText), under an owner of its own, so resource and server hides leave each other alone.
local SERVER_TEXT = 'server:' .. RESOURCE

-- A countdown (ShowPlayerText's `countdown`) is counted down here a second at a time. While another resource holds
-- the band the clock runs unseen; at 0:00 it stops and stays.
local _countdown = nil   -- { text, position, endsAt, total } while one runs

local function clockText(ms)
    local s = math.max(0, math.ceil(ms / 1000))
    local h, m = s // 3600, (s % 3600) // 60
    if h > 0 then return ('%d:%02d:%02d'):format(h, m, s % 60) end
    return ('%d:%02d'):format(m, s % 60)
end

--- Draw the countdown as it stands. Answers the ms left.
local function drawCountdown(c)
    local left = c.endsAt - GetGameTimer()
    local pct = c.total > 0 and math.max(0, math.min(100, left / c.total * 100)) or 0
    UI.ShowText(c.text .. ' · ' .. clockText(left), c.position, pct, SERVER_TEXT)
    return left
end

RegisterNetEvent('whip_core:client:playerText', function(text, position, progress, timer)
    _countdown = nil
    if type(text) ~= 'string' then
        UI.HideText(SERVER_TEXT)
        return
    end
    position = (position == 'top') and 'top' or 'bottom'
    local left = type(timer) == 'table' and tonumber(timer.left) or nil
    if not left then
        UI.ShowText(text, position, tonumber(progress), SERVER_TEXT)
        return
    end
    local c = { text = text, position = position, endsAt = GetGameTimer() + left, total = tonumber(timer.total) or left }
    _countdown = c
    if drawCountdown(c) <= 0 then return end
    CreateThread(function()
        while _countdown == c do
            -- To the next whole second shown, so it ticks evenly.
            local wait = (c.endsAt - GetGameTimer()) % 1000
            Wait((wait == 0 and 1000 or wait) + 10)
            if _countdown ~= c then break end
            if _textOwner == nil or _textOwner == SERVER_TEXT then
                if drawCountdown(c) <= 0 then break end
            elseif c.endsAt <= GetGameTimer() then
                break
            end
        end
    end)
end)

-- A job's objective, on a card at the top right: the server's (PlayerText.objective) or a resource's own on this client
-- (ShowObjective). Separate from the band. The page counts the clock down itself.

--- One card up, or changed. data: { text, name?, timer? = { left, total } (ms), icon? (a glyph's key), film? (stays up on a clean screen) }.
local function sendObjective(cardId, data)
    local timer = type(data.timer) == 'table' and data.timer or nil
    SendNUIMessage({
        action = 'uiObjective',
        id     = cardId,
        text   = tostring(data.text or ''),
        name   = type(data.name) == 'string' and data.name or nil,
        left   = timer and tonumber(timer.left) or nil,
        total  = timer and tonumber(timer.total) or nil,
        icon   = type(data.icon) == 'string' and data.icon or nil,
        film   = data.film == true or nil,
    })
end

RegisterNetEvent('whip_core:client:objective', function(cardId, data)
    if type(cardId) ~= 'string' then return end
    if type(data) ~= 'table' then
        SendNUIMessage({ action = 'uiObjective', id = cardId, hide = true })
        return
    end
    sendObjective(cardId, data)
end)

-- A resource's own card, on this client only (a filming tool's dummy objective, a client mission). Anything the server
-- runs uses the server's. Kept under 'client|<resource>|<id>', so one resource never touches another's.
local OBJECTIVE_TEXT_MAX, OBJECTIVE_COUNTDOWN_MAX = 200, 7 * 24 * 3600
-- [cardId] = true, owned by the resource that put it up (whip's registry, swept on its stop). Every show replaces.
local ownCards = Registry.new('objectiveCards', {
    label    = 'objective card',
    same     = false,
    onRemove = function(cardId) SendNUIMessage({ action = 'uiObjective', id = cardId, hide = true }) end,
})

local function ownCardId(owner, id) return 'client|' .. owner .. '|' .. id end

--- Put a card up, or change the one `id` names. opts: { name (line under it), countdown (seconds), countdownTotal
--- (seconds, for the disc), icon (a glyph's key; the flag when none), film (true: stays up on a clean screen) }.
--- Answers true, or false and why.
local function showObjective(owner, id, text, opts)
    opts = type(opts) == 'table' and opts or {}
    if type(id) ~= 'string' or id == '' or #id > 64 then return false, 'id is a name (64 letters at most)' end
    local clean = BubbleText.clean(text, OBJECTIVE_TEXT_MAX)
    if clean == '' then return false, 'text is empty' end
    local timer
    if opts.countdown ~= nil then
        local left = tonumber(opts.countdown)
        local total = opts.countdownTotal ~= nil and tonumber(opts.countdownTotal) or left
        if not left or left ~= left or left < 0 or left > OBJECTIVE_COUNTDOWN_MAX
            or not total or total ~= total or total < 0 or total > OBJECTIVE_COUNTDOWN_MAX then
            return false, ('countdown and countdownTotal are seconds, 0-%d'):format(OBJECTIVE_COUNTDOWN_MAX)
        end
        timer = { left = math.floor(left * 1000), total = math.floor(math.max(total, left) * 1000) }
    end
    local name = BubbleText.clean(opts.name, 60)
    local cardId = ownCardId(owner, id)
    local held, why = ownCards:add(owner, cardId, true)
    if not held then return false, why end
    sendObjective(cardId, {
        text = clean, name = name ~= '' and name or nil, timer = timer,
        icon = type(opts.icon) == 'string' and opts.icon:sub(1, 32) or nil, film = opts.film == true,
    })
    return true
end

local function hideObjective(owner, id)
    if type(id) ~= 'string' then return false, 'id is a name' end
    ownCards:remove(owner, ownCardId(owner, id))   -- (its onRemove takes the card down; none up is fine)
    return true
end

exports('ShowObjective', function(id, text, opts) return showObjective(caller(), id, text, opts) end)
exports('HideObjective', function(id) return hideObjective(caller(), id) end)
-- (A resource stopping takes its cards with it: the registry's sweep, through onRemove.)

-- Is a progress bar running? Any resource may ask; only the bar's owner may cancel it.
exports('IsProgressActive', UI.IsProgressActive)
exports('CancelProgress', function() return UI.CancelProgress(caller()) end)
-- Stopped by something the player did not choose: the bar turns red and says why. Only its owner.
exports('InterruptProgress', function(why) return UI.InterruptProgress(why, caller()) end)
-- The same for a resource's own mode (an aim, a placing): see UI.ShowInterrupted.
exports('ShowInterrupted', function(why, what) return UI.ShowInterrupted(why, what) end)

-- Not exported: UI.Cancel, which cancels whichever blocking component is up, whoever opened it (whip_core's cleanup
-- and own bars). A satellite gets CancelProgress, which cancels only a bar it started.

-- A logout closes whatever is up: it belongs to the character that started it. The server has ended its side.
RegisterNetEvent('whip_core:client:playerLogout', function()
    UI.Cancel()
end)

-- ---- Server-driven skill check ----

--- The server asked for a skill check and is waiting on the answer. The token is echoed back untouched as proof the
--- reply belongs to a challenge it issued (server/skillcheck.lua). If another blocking UI is open, it replies false at once.
---
--- The server check running on screen now, and whether the server has called it off.
local _serverCheckToken, _serverCheckCalledOff = nil, false

RegisterNetEvent('whip_core:client:serverSkillCheck', function(token, difficulty, game)
    -- Now, not on the next tick: a cancel right behind this request must find the token set.
    Citizen.CreateThreadNow(function()
        _serverCheckToken, _serverCheckCalledOff = token, false
        -- Another resource's game (server/skillcheck.lua), or the ring.
        local passed, why
        if type(game) == 'string' then
            passed, why = _playGame(game, difficulty, RESOURCE, true)
        else
            passed, why = UI.SkillCheck(difficulty)
        end
        local calledOff = _serverCheckToken == token and _serverCheckCalledOff
        if _serverCheckToken == token then _serverCheckToken, _serverCheckCalledOff = nil, false end
        -- The server has stopped waiting (it timed out): nothing to tell it.
        if calledOff then return end
        -- The why rides along so the server export answers the same `false, why`.
        TriggerServerEvent('whip_core:server:skillCheckResult', token, passed and true or false,
            (not passed and type(why) == 'string') and why or '')
    end)
end)

--- The server gave up waiting on a check (timeout or logout): take it off the screen. Only the check with this token.
RegisterNetEvent('whip_core:client:serverSkillCheckCancel', function(token)
    if token == nil or token ~= _serverCheckToken then return end
    _serverCheckCalledOff = true
    UI.Cancel()
end)

-- ---- Server-driven questions (server/ask.lua) ----

--- The server asked a Yes/No or a form and is waiting on the answer. The token goes back untouched. A Confirm's No
--- (or Escape) is an answer, false; a form backed out of is not. The server asks one at a time, but the last dialog
--- may still be closing here: the new one waits for it instead of answering 'busy', and a called-off question is known
--- by its token.
local _askShown, _askNext, _askCalledOff = nil, nil, {}

local function showAsk(token, kind, spec)
    -- Now, as the skill check above.
    Citizen.CreateThreadNow(function()
        _askShown = token
        spec = type(spec) == 'table' and spec or {}
        local answered, value, why = false, nil, nil
        if kind == 'confirm' then
            local yes, cwhy = UI.Confirm(spec.title, spec.message, spec.yes, spec.no)
            if yes then answered, value = true, true
            elseif cwhy == 'cancelled' then answered, value = true, false
            else why = cwhy end
        else
            local res, iwhy = UI.Input(spec.title, spec.fields)
            if type(res) == 'table' then answered, value = true, res else why = iwhy end
        end
        local calledOff = _askCalledOff[token]
        _askCalledOff[token] = nil
        _askShown = nil
        -- The server has stopped waiting (its timeout, the system switched off): nothing to tell it.
        if not calledOff then
            TriggerServerEvent('whip_core:server:askAnswer', token, answered,
                (not answered and type(why) == 'string') and why or '', value)
        end
        local nxt = _askNext
        _askNext = nil
        if nxt then showAsk(nxt.token, nxt.kind, nxt.spec) end
    end)
end

RegisterNetEvent('whip_core:client:serverAsk', function(token, kind, spec)
    if _askShown ~= nil then
        _askNext = { token = token, kind = kind, spec = spec }   -- shown once the last one has closed
        return
    end
    showAsk(token, kind, spec)
end)

--- The server gave up on a question: take it off the screen (or out of the wait). Only that one.
RegisterNetEvent('whip_core:client:serverAskCancel', function(token)
    if token == nil then return end
    -- And a local event for a resource that took the question on its own screen (RegisterAskChannel).
    WhipEmit('whip_core:ask:cancelled', { token = token })
    if _askNext and _askNext.token == token then _askNext = nil return end
    if token ~= _askShown then return end
    _askCalledOff[token] = true
    UI.Cancel()
end)

-- ---- Server-driven progress bar ----

--- The server asked for a bar and is waiting on the answer (server/timed_action.lua). The token goes back untouched;
--- the owner is the resource the server call came from, so their stopping ends it.
--- The server bar on screen now, and whether the server has called it off (the skill check's pair).
local _serverBarToken, _serverBarCalledOff = nil, false

RegisterNetEvent('whip_core:client:serverProgress', function(token, opts, owner)
    -- Now, as the skill check above: a cancel right behind the request finds the bar.
    Citizen.CreateThreadNow(function()
        _serverBarToken, _serverBarCalledOff = token, false
        local done, why = UI.Progress(opts or {}, nil, nil, owner)
        local calledOff = _serverBarToken == token and _serverBarCalledOff
        if _serverBarToken == token then _serverBarToken, _serverBarCalledOff = nil, false end
        -- The server has stopped waiting (its run ended): nothing to tell it.
        if calledOff then return end
        TriggerServerEvent('whip_core:server:progressResult', token, done and true or false, why or '')
    end)
end)

--- The server called a bar off (its run ended or was reset). Only the bar with this token.
RegisterNetEvent('whip_core:client:serverProgressCancel', function(token)
    if token == nil or token ~= _serverBarToken then return end
    _serverBarCalledOff = true
    UI.Interrupt('Called off')   -- not the player's doing: the run it belonged to ended
end)

-- ---- Cleanup ----

-- whip_core stopping takes everything down. Another resource stopping takes down what it put up: its dialog or bar is
-- cancelled (a Confirm would hold the mouse for its timeout), and its text comes off.
AddEventHandler('onResourceStop', function(res)
    if res == RESOURCE then
        UI.Cancel()
        UI.HideText()
        return
    end
    if _activeBlockingId and _activeOwner == res then UI.Cancel() end
    if _textOwner == res then UI.HideText(res) end
end)

-- A death cancels a dialog (a bar stops itself): it would hold the focus over the death screen. Its caller gets
-- false, 'cancelled', as for Escape.
AddEventHandler('whip_core:player:died', function()
    if _activeBlockingId and _activeKind == 'dialog' then UI.Cancel() end
end)
