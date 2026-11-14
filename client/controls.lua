-- Blocking controls: hold controls off while a screen or action is up.
--
--     exports.whip_core:BlockControls('shop', { groups = { 'move', 'combat', 'radio' } })   -- screen opens
--     exports.whip_core:UnblockControls('shop')                                              -- it closes
--
-- DisableControlAction lasts one frame, so one shared Wait(0) loop runs while anything is blocked (whip_core's
-- pause keys and action mode keep it running). The blocked set is worked out when a block changes.
-- Switches are whole functions GTA can turn off and leave off (shooting from a vehicle): off with the first
-- block, back on with the last. Blocks are keyed per resource ('<resource>:<id>', shared/registry.lua) and swept
-- when it stops; the same id replaces a block, and UnblockControls on an unheld id is fine. /whipcontrols prints
-- who blocks what.
-- A blocked control can still be read through the DISABLED readers (IsDisabledControlPressed, etc).

ControlBlocks = {}

local SELF = GetCurrentResourceName()

--- The groups: a word for a set of GTA controls. A new group goes here, never in a satellite.
local GROUPS = {
    -- On foot: walk, sprint, jump, duck, cover.
    move          = { 30, 31, 21, 22, 36, 44 },
    -- On foot: attack, aim, weapon select, the melee keys.
    combat        = { 24, 25, 37, 140, 141, 142, 257 },
    -- Every way to drive, and getting out: steer (keys and mouse), accelerate, brake, handbrake, exit.
    driving       = { 59, 60, 63, 64, 71, 72, 75, 76, 106 },
    -- In a vehicle: its attacks and aim, and a passenger's.
    vehicleCombat = { 68, 69, 70, 91, 92 },
    -- Looking around (mouse, right stick). A custom camera reads them disabled.
    look          = { 1, 2 },
    -- The radio: next / previous station and track, and the radio wheel.
    radio         = { 81, 82, 83, 84, 85 },
    -- The weapon wheel and weapon scrolling — the mouse wheel, on foot and in a vehicle.
    weaponWheel   = { 14, 15, 16, 17, 99, 100 },
}

--- The switches: functions GTA can turn off and leave off, named in `groups`. Called with false to turn off, true to restore.
local SWITCHES = {
    -- Shooting or aiming out of a vehicle (drive-by).
    driveBy = function(allowed) SetPlayerCanDoDriveBy(PlayerId(), allowed) end,
    -- The radio as a whole (wheel and station). Held by any 'radio' or everything block: control blocks alone
    -- do not stop the wheel on Enhanced.
    radioControls = function(allowed) SetUserRadioControlEnabled(allowed) end,
}

--- Every name a block may use, for the refusal that says which exist.
local function knownNames()
    local names = {}
    for name in pairs(GROUPS) do names[#names + 1] = name end
    for name in pairs(SWITCHES) do names[#names + 1] = name end
    table.sort(names)
    return table.concat(names, ', ')
end

--- A spec field's control ids, checked: whole numbers, 0 to 400.
---@return table|nil ids, string|nil why
local function controlIds(list)
    local ids = {}
    for _, c in ipairs(type(list) == 'table' and list or {}) do
        local id = math.tointeger(tonumber(c))
        if not id or id < 0 or id > 400 then
            return nil, ('"%s" is not a control id (a whole number, 0 to 400)'):format(tostring(c))
        end
        ids[#ids + 1] = id
    end
    return ids
end

--- A block made into what the loop needs: one list of control ids and the switches (`names` is kept for
--- /whipcontrols). `all = true` holds off every control bar the `except` ones; an exception never gives back
--- a control another block holds.
---@param spec table  { groups = { name, ... }, controls = { id, ... } } or { all = true, except = { id, ... } }
---@param allowEmpty boolean|nil  whip_core's own blocks may be only a per-frame hook
---@return table|nil value, string|nil why
local function normalise(spec, allowEmpty)
    if type(spec) ~= 'table' then
        return nil, 'BlockControls needs { groups = { ... }, controls = { ... } }'
    end
    if spec.except ~= nil and spec.all ~= true then
        return nil, '`except` only goes with all = true'
    end
    local except = {}
    if spec.all == true then
        local ids, why = controlIds(spec.except)
        if not ids then return nil, why end
        table.sort(ids)
        except = ids
    end
    local controls, switches, names, seen = {}, {}, {}, {}
    local switched = {}
    local groups = type(spec.groups) == 'table' and spec.groups or {}
    for _, name in ipairs(groups) do
        if GROUPS[name] then
            for _, c in ipairs(GROUPS[name]) do
                if not seen[c] then seen[c] = true; controls[#controls + 1] = c end
            end
        elseif SWITCHES[name] then
            if not switched[name] then switched[name] = true; switches[#switches + 1] = name end
        else
            return nil, ('there is no control group "%s" (the groups are: %s)'):format(tostring(name), knownNames())
        end
        names[#names + 1] = name
    end
    -- The radio wheel: controls alone are not enough on Enhanced, so the radio goes off too (unless control 85 is an exception).
    local wantsRadio = false
    for _, name in ipairs(groups) do if name == 'radio' then wantsRadio = true end end
    if spec.all == true then
        wantsRadio = true
        for _, id in ipairs(except) do if id == 85 then wantsRadio = false end end
    end
    if wantsRadio and not switched.radioControls then
        switched.radioControls = true
        switches[#switches + 1] = 'radioControls'
    end
    local ids, why = controlIds(spec.controls)
    if not ids then return nil, why end
    for _, id in ipairs(ids) do
        if not seen[id] then seen[id] = true; controls[#controls + 1] = id end
        names[#names + 1] = tostring(id)
    end
    if spec.all == true then
        local kept = {}
        for _, id in ipairs(except) do kept[#kept + 1] = tostring(id) end
        names[#names + 1] = #kept > 0 and ('all except ' .. table.concat(kept, ' ')) or 'all'
    end
    -- Walk at most: a move-speed cap applied every frame in the loop below (SetPedMaxMoveBlendRatio does not
    -- stick), with sprint (21) held off.
    -- Jog at most: capped at a jog with the sprint key left on, since holding it is how a player goes from walk to
    -- jog; the cap turns the sprint into a jog.
    -- Both asked: the walk (the slower) wins.
    local speed = (spec.walk == true and 1.0) or (spec.jog == true and 2.0) or nil
    if speed then
        if speed == 1.0 and not seen[21] then seen[21] = true; controls[#controls + 1] = 21 end
        names[#names + 1] = speed == 1.0 and 'walk' or 'jog'
    end
    -- A mode of your own (placing, aiming a tool, a minigame): whip's world keys (E prompts, hotbar, wheels) stand
    -- down (IsGameInputFree answers false). The HUD stays (SetScreenOpen hides it).
    local mode = spec.mode == true
    if mode then names[#names + 1] = 'mode' end
    -- ...but the hotbar's number keys still use their slots (the camera item).
    local hotbar = mode and spec.hotbar == true
    if hotbar then names[#names + 1] = 'hotbar' end
    if #controls == 0 and #switches == 0 and spec.all ~= true and not mode and not allowEmpty then
        return nil, 'nothing to block: name some groups or controls'
    end
    table.sort(controls)
    table.sort(switches)
    return { controls = controls, switches = switches, names = names, all = spec.all == true, except = except,
             speed = speed, mode = mode, hotbar = hotbar }
end

-- ---- the one loop ------------------------------------------------------------

local _blocks     = {}   -- the registry's store: [key] = { controls, switches, names, all, except, speed, frame? }
local _active     = {}   -- every control held off, one list, no repeats (rebuilt on change)
local _all        = false -- some block holds off everything
local _speedCap   = nil  -- the slowest any block allows: 1.0 a walk (spec.walk), 2.0 a jog (spec.jog), nil any
local _modeHeld   = false -- some resource's block is a mode of its own (spec.mode): whip's world keys stand down
local _modeShutsHotbar = false -- ...and one of those modes does not let the hotbar through (spec.hotbar)
local _enable     = {}   -- with _all: the exceptions EVERY all-block allows and no block holds
local _frames     = {}   -- whip_core's own per-frame hooks (the progress bar: its cancel key, walk mode)
local _frameNames = {}   -- beside _frames: each hook's profiler scope ('whip:frame:<block>')
local _costNames  = {}   -- beside _frames: each hook's line in /whipcost's table ('controls: <block>')
local _profileHooks = false   -- each hook in a profiler scope of its own; off (no cost at all), true here turns it on
local _switchHeld = {}   -- [switch] = how many blocks hold it off
local _loopTurn   = 0    -- bumped to end the loop; a new loop carries the new turn
local _running    = false

--- One frame's holding: everything bar the exceptions when a block says all, then every block's list.
local function applyFrame()
    if _all then
        DisableAllControlActions(0)
        local enable = _enable
        for i = 1, #enable do EnableControlAction(0, enable[i], true) end
    end
    local list = _active
    for i = 1, #list do DisableControlAction(0, list[i], true) end
    if _speedCap then SetPedMaxMoveBlendRatio(PlayerPedId(), _speedCap) end   -- 1 a walk, 2 a jog (3 a sprint)
end

--- Is this hook still held? Asked only when the lists changed during the frame.
local function stillHeld(f)
    for j = 1, #_frames do
        if _frames[j] == f then return true end
    end
    return false
end

--- One frame of the loop while /whipcost times whip (lib/cost.lua): the held controls and each hook timed separately, plus the whole frame.
local function timedFrame(frames, names)
    local all = WhipCost.start()
    local c = WhipCost.start()
    applyFrame()
    WhipCost.stop('controls: (held controls)', c)
    for i = 1, #frames do
        if _frames == frames or stillHeld(frames[i]) then   -- (loop, below: a hook let go this frame skips)
            c = WhipCost.start()
            local ok, err = pcall(frames[i])
            WhipCost.stop(names[i], c)
            if not ok then print(('[whip_core] a control block hook failed: %s'):format(tostring(err))) end
        end
    end
    WhipCost.stop('controls: every job together', all)
end

--- Every frame while anything is blocked. A block added or removed mid-loop takes effect next frame; a hook
--- let go earlier in the frame does not run again (it could re-hold what was just released).
local function loop(turn)
    while turn == _loopTurn do
        local frames, names, profile = _frames, _frameNames, _profileHooks
        if WhipCost.on then
            timedFrame(frames, _costNames)
        else
            -- The held controls get their own scope too.
            if profile then ProfilerEnterScope('whip:frame:(held controls)') end
            applyFrame()
            if profile then ProfilerExitScope() end
            for i = 1, #frames do
                if _frames == frames or stillHeld(frames[i]) then
                    if profile then ProfilerEnterScope(names[i]) end
                    local ok, err = pcall(frames[i])
                    if profile then ProfilerExitScope() end
                    if not ok then print(('[whip_core] a control block hook failed: %s'):format(tostring(err))) end
                end
            end
        end
        Wait(0)
    end
end

--- Work out the lists again, and start or end the loop to match.
local function rebuild()
    local seen, list, frames, names, costNames = {}, {}, {}, {}, {}
    local all, allowed = false, nil   -- allowed: [id] = true for an exception every all-block shares
    local speedCap, modeHeld, shutsHotbar = nil, false, false
    for key, b in pairs(_blocks) do
        for _, c in ipairs(b.controls) do
            if not seen[c] then seen[c] = true; list[#list + 1] = c end
        end
        if b.speed and (not speedCap or b.speed < speedCap) then speedCap = b.speed end
        if b.mode then modeHeld = true end
        if b.mode and not b.hotbar then shutsHotbar = true end
        if b.all then
            local mine = {}
            for _, id in ipairs(b.except) do mine[id] = true end
            if allowed then
                for id in pairs(allowed) do if not mine[id] then allowed[id] = nil end end
            else
                allowed = mine
            end
            all = true
        end
        if b.frame then
            frames[#frames + 1] = b.frame
            names[#names + 1] = 'whip:frame:' .. tostring(key)
            costNames[#costNames + 1] = 'controls: ' .. tostring(key):gsub('^whip_core:', '')
        end
    end
    local enable = {}
    for id in pairs(allowed or {}) do
        if not seen[id] then enable[#enable + 1] = id end
    end
    table.sort(enable)
    _active, _frames, _frameNames, _costNames, _all, _enable = list, frames, names, costNames, all, enable
    _speedCap, _modeHeld, _modeShutsHotbar = speedCap, modeHeld, shutsHotbar

    -- Held from this frame: Alt and a click in the same frame must not shoot.
    applyFrame()

    if #list == 0 and #frames == 0 and not all then
        if _running then
            _running = false
            _loopTurn = _loopTurn + 1   -- the running loop sees a new turn and ends
        end
    elseif not _running then
        _running = true
        _loopTurn = _loopTurn + 1
        local turn = _loopTurn
        CreateThread(function() loop(turn) end)
    end
end

--- [control] = the frame a block naming it last went. A mode that exits on Esc lets go in the frame Esc was pressed.
local _goneFrame = {}

local function noteGone(value)
    local frame = GetFrameCount()
    for _, c in ipairs(value.controls) do _goneFrame[c] = frame end
end

--- One more (+1) or fewer (-1) block holding a switch off; off with the first, back with the last.
local function holdSwitch(name, delta)
    local was = _switchHeld[name] or 0
    local now = math.max(was + delta, 0)
    _switchHeld[name] = now > 0 and now or nil
    if was == 0 and now > 0 then SWITCHES[name](false)
    elseif was > 0 and now == 0 then SWITCHES[name](true) end
end

local registry = Registry.new('controlBlocks', {
    label  = 'control block',
    store  = _blocks,
    scoped = true,
    -- A replaced block holds its new switches before releasing its old ones, so a shared switch never flickers on.
    onAdd = function(_, value, _, old)
        for _, s in ipairs(value.switches) do holdSwitch(s, 1) end
        if old then
            for _, s in ipairs(old.switches) do holdSwitch(s, -1) end
            noteGone(old)
        end
        rebuild()
    end,
    onRemove = function(_, value)
        for _, s in ipairs(value.switches) do holdSwitch(s, -1) end
        noteGone(value)
        rebuild()
    end,
})

-- ---- for satellites ------------------------------------------------------------

--- Hold controls off until UnblockControls(id), or until your resource stops.
---@param id string|number  your block's id; the same id replaces it
---@param spec table  { groups = { 'move', 'combat', ... }, controls = { 81, ... }, walk = true (walk at most) | jog = true (jog at most), mode = true (a mode of your own: whip's world keys stand down), hotbar = true (with mode: the hotbar's number keys still work) }
---@return boolean ok
---@return string|nil why
exports('BlockControls', function(id, spec)
    local owner = Registry.caller()
    local value, why = normalise(spec)
    if not value then return false, why end
    local ok, reason = registry:add(owner, id, value)
    if not ok then return false, reason --[[@as string]] end
    return true
end)

--- Let go of one of your blocks. Fine to call when it is not held (answers true).
---@param id string|number
---@return boolean ok
---@return string|nil why
exports('UnblockControls', function(id)
    local owner = Registry.caller()
    if (type(id) ~= 'string' and type(id) ~= 'number') or registry:get(registry:keyOf(owner, id)) == nil then
        return true
    end
    return registry:remove(owner, id)
end)

-- ---- for whip_core's own files ----------------------------------------------------

--- whip_core's own block, which may also run `frame` every frame inside the same loop. Not on the export:
--- a function handed across an export is not safe to call every frame.
---@param id string
---@param spec table  as BlockControls; may be empty when `frame` does the work
---@param frame function|nil
---@return boolean ok, string|number|nil why  why not; when held, the block's key (Reg:add's answer)
function ControlBlocks.hold(id, spec, frame)
    local value, why = normalise(spec, frame ~= nil)
    if not value then return false, why end
    value.frame = frame
    return registry:add(SELF, id, value)
end

--- Let go of one of whip_core's own blocks. Fine when it is not held.
---@param id string
function ControlBlocks.release(id)
    if registry:get(registry:keyOf(SELF, id)) == nil then return true end
    return registry:remove(SELF, id)
end

--- The fastest any block lets the player go: 'walk' (spec.walk), 'jog' (spec.jog) or nil. The pad's jog and sprint ask.
---@return 'walk'|'jog'|nil
function ControlBlocks.speedCap()
    if _speedCap == 1.0 then return 'walk' end
    if _speedCap == 2.0 then return 'jog' end
    return nil
end

--- Does some block hold a mode of its own (spec.mode)? IsGameInputFree asks. `forHotbar`: the hotbar's number
--- keys asking, which only a mode without spec.hotbar stops.
---@param forHotbar boolean|nil
---@return boolean
function ControlBlocks.modeHeld(forHotbar)
    if forHotbar then return _modeShutsHotbar end
    return _modeHeld
end

--- Does a block other than whip_core's `exceptId` name this control, now or in this or the last frame?
--- A block that names a key owns it: the pause keys ask before opening. `all = true` alone does not count.
---@param control integer
---@param exceptId string
---@return boolean
function ControlBlocks.heldByOthers(control, exceptId)
    if (_goneFrame[control] or -2) >= GetFrameCount() - 1 then return true end
    local skip = registry:keyOf(SELF, exceptId)
    for key, b in pairs(_blocks) do
        if key ~= skip then
            for _, c in ipairs(b.controls) do
                if c == control then return true end
            end
        end
    end
    return false
end

-- whip_core stopping takes this loop with it, but a switch stays as it was left: give each back.
AddEventHandler('onResourceStop', function(res)
    if res ~= SELF then return end
    for name in pairs(_switchHeld) do SWITCHES[name](true) end
    _switchHeld = {}
end)

--- Who is blocking what, right now: one line per block. Also /paddebug's opening dump.
---@return string[]
function ControlBlocks.describe()
    local keys, lines = {}, {}
    for key in pairs(_blocks) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local b = _blocks[key]
        lines[#lines + 1] = ('%s: %s (%d controls%s)'):format(key, table.concat(b.names, ', '),
            #b.controls, b.frame and ', and a per-frame hook' or '')
    end
    return lines
end

-- /whipcost (tools/whipcost.lua) times the loop with the rest of whip, each hook separately (timedFrame).
