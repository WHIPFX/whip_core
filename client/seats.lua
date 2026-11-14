-- ============================================
-- SEATS — passengers stay in their seat, and the wheel's Seats page
-- ============================================
--
-- Two GTA habits, two fixes (Config.Seats.NoAutoShuffle):
--
--   1. A passenger slides into the driver's seat when it goes empty. Ped config flag 184
--      (PreventAutoShuffleToDriversSeat) stops it, as GTA Online uses it, and 360 does the same for a
--      gun turret seat. A flag lives on the PED, and a new ped (a model change, a respawn) starts
--      without it, so the vehicle tick asks every 200 ms and sets it when it is missing: one native,
--      on a wake that already runs. Reset flag 216 (a downed driver is shoved over to) clears every
--      frame, so it rides whip's one per-frame loop while seated, which also holds GTA's own shuffle
--      button off (104: H, D-pad right). Neither flag stops the slide in (2).
--
--   2. F at the passenger door of an empty car gets in there and slides across to drive. That slide
--      is part of GTA's get-in task. 'retask' (the default) watches the task start: heading for the
--      driver's seat from the side away from it, with the front passenger seat free, it is told
--      again to get into the passenger seat by that door, with no sliding (TaskEnterVehicle flag
--      1048576, BlockSeatShuffling). The walk to the door is the same, so it looks like nothing.
--      `/seatentry direct` tries config flag 170 (ForceDirectEntry) instead, `/seatentry off` neither,
--      to compare in game.
--
--   A backstop for anything that still slides: a shuffle heading for the driver's seat that whip did
--   not start is undone (the ped is put back in its seat). It shows, so it is only the net under the
--   two above.
--
-- The Seats page, inside the wheel. Seats on the F1 wheel does not close
-- it: the ring gives way to the vehicle's seats as slabs laid out like the car round the centre disc,
-- two to a row (one behind another on a bike), each Free, Occupied or You (client/radial.lua's
-- RadialPage; html/js/ui.js §5 draws it). /seats opens the wheel straight on it. GTA has no native
-- that says where a seat is, so the rows come from the seat count, as every seat menu does. Picking a
-- free seat closes the wheel and moves the player. The move is claimed on the server first
-- (server/seats.lua: two players picking one seat). Then, to a seat in the same row, the ped slides
-- across with GTA's own animation; to any other seat (front to back, a bus's seat 9) GTA has none,
-- and the ped is put there. A slide that lands somewhere else is remembered for that model and
-- pair, and that pair is a teleport from then on.
--
-- Moving at speed is allowed, and so is a locked car. Downed players have no wheel and the
-- server refuses them; the page closes the wheel when they go down or leave the vehicle.

Seats = {}

local cfg = Config.Seats or {}

local FLAG_NO_SHUFFLE_TO_DRIVER = 184   -- CPED_CONFIG_FLAG_PreventAutoShuffleToDriversSeat
local FLAG_NO_SHUFFLE_TO_TURRET = 360   -- CPED_CONFIG_FLAG_PreventAutoShuffleToTurretSeat
local FLAG_FORCE_DIRECT_ENTRY   = 170   -- CPED_CONFIG_FLAG_ForceDirectEntry (entryMode 'direct')
local RESET_NO_INJURED_SHUFFLE  = 216   -- PRF_DisableSeatShuffleDueToInjuredDriver (per frame)
local TASK_SEAT_SHUFFLE         = 165   -- CTaskInVehicleSeatShuffle
local CONTROL_VEH_SHUFFLE       = 104   -- INPUT_VEH_SHUFFLE: H, D-pad right
local ENTER_RESUME              = 1         -- TaskEnterVehicle: carry on if interrupted
local ENTER_NO_SLIDE            = 1048576   -- TaskEnterVehicle: BlockSeatShuffling, the seat's own door
local CONTROL_ENTER             = 23        -- INPUT_ENTER: F, Y
local CONTROL_MOVE_LR           = 30        -- INPUT_MOVE_LR: A/D, left stick across
local CONTROL_MOVE_UD           = 31        -- INPUT_MOVE_UD: W/S, left stick up and down (up is -1)
local CANCEL_PUSH               = 0.5       -- how hard the stick (or a key) must push to walk away
local CANCEL_WATCH_MS           = 10000     -- the get-in's own timeout: the watch ends with it
local NATIVE_SEAT_FREE          = 0x22AC59A870E6A669   -- IS_VEHICLE_SEAT_FREE(veh, seat, isTaskRunning)

local moving    = false      -- whip is moving the ped between seats: the backstop and flag 184 stay out
local held      = false      -- the 'seats' control block is held
local entryMode = 'retask'   -- how the passenger door keeps from sliding across: 'retask' | 'direct' | 'off'
local retasked  = 0          -- the vehicle whose get-in was re-issued, so it is re-issued once

--- [model .. ':' .. from .. '>' .. to] = true: a slide there did not land where it was asked to.
local noSlide = {}

local function on() return cfg.NoAutoShuffle ~= false end

local function say(text, kind)
    if UI and UI.Notify then UI.Notify(text, kind or 'info') end
end

--- Is `seat` free, counting a seat someone is getting into or sliding into as taken? The third
--- argument is the "task" half, a parameter FiveM's own wrapper may not pass, so it goes by hash.
---@return boolean
local function seatFree(veh, seat)
    local r = Citizen.InvokeNative(NATIVE_SEAT_FREE, veh, seat, true, Citizen.ReturnResultAnyway())
    if r == nil then return IsVehicleSeatFree(veh, seat) end
    return r == true or r == 1
end

--- Which seat of `veh` this ped is in; nil when none.
---@return number|nil
local function seatOf(veh, ped)
    for s = -1, GetVehicleMaxNumberOfPassengers(veh) - 1 do
        if GetPedInVehicleSeat(veh, s) == ped then return s end
    end
    return nil
end

--- One seat behind another rather than two side by side: bikes, quads, jet skis. They have no
--- front passenger's seat bone, which every car has.
---@return boolean
local function isInline(veh)
    return GetVehicleMaxNumberOfPassengers(veh) <= 1
        and GetEntityBoneIndexByName(veh, 'seat_pside_f') == -1
end

--- The seat's row in the map: two to a row (driver and passenger first), or one on an inline vehicle.
local function rowOf(seat, inline)
    if inline then return seat + 1 end
    return math.floor((seat + 1) / 2)
end

-- ---- staying in the seat ----------------------------------------------------

--- The two flags on, when the setting is. When it is off they are left alone: something else may
--- want them, and the setting's change hook clears whip's own once.
local function assertFlags(ped)
    if moving or not on() then return end
    if not GetPedConfigFlag(ped, FLAG_NO_SHUFFLE_TO_DRIVER, true) then
        SetPedConfigFlag(ped, FLAG_NO_SHUFFLE_TO_DRIVER, true)
    end
    if not GetPedConfigFlag(ped, FLAG_NO_SHUFFLE_TO_TURRET, true) then
        SetPedConfigFlag(ped, FLAG_NO_SHUFFLE_TO_TURRET, true)
    end
    local direct = entryMode == 'direct'
    if GetPedConfigFlag(ped, FLAG_FORCE_DIRECT_ENTRY, true) ~= direct then
        SetPedConfigFlag(ped, FLAG_FORCE_DIRECT_ENTRY, direct)
    end
end

--- whip's flags off again: the setting turned off, or whip_core stopping.
local function clearFlags()
    local ped = PlayerPedId()
    if ped == 0 then return end
    SetPedConfigFlag(ped, FLAG_NO_SHUFFLE_TO_DRIVER, false)
    SetPedConfigFlag(ped, FLAG_NO_SHUFFLE_TO_TURRET, false)
    SetPedConfigFlag(ped, FLAG_FORCE_DIRECT_ENTRY, false)
end

--- Every frame while seated (the 'seats' block): GTA's push of a passenger over a downed driver off.
local function seatedFrame()
    if not held then return end   -- a hook let go earlier in this frame still runs once
    local ped = PlayerPedId()
    if ped ~= 0 then SetPedResetFlag(ped, RESET_NO_INJURED_SHUFFLE, true) end
end

local function hold(want)
    -- True or false: the vehicle tick hands IsPedInAnyVehicle's answer, which is 1 (a BOOL native), and 1 == true is
    -- false in Lua, so the block was held again on every pass (5 a second), a new spec and its tables each time.
    want = want and true or false
    if want == held then return end
    if want then
        held = ControlBlocks.hold('seats', { controls = { CONTROL_VEH_SHUFFLE } }, seatedFrame) == true
    else
        held = false
        ControlBlocks.release('seats')
    end
end

--- Walking away cancels the get-in, as in GTA. The get-in below is whip's, a SCRIPT task, which GTA's
--- player input never interrupts. GTA's own get-in stops when the stick pushes away from the car, so
--- while whip's runs, this does the same: pushing away from the car, or F / Y again, stops it — until the
--- ped starts onto the seat (IsPedInAnyVehicle with atGetIn: true from the moment the door is open and
--- it climbs in), from where GTA's own carries on too. Every frame, only while that get-in runs, and
--- never past its own 10 s. `grace`: ms a get-in just asked for (Seats.enter) has to begin.
local function watchCancel(ped, veh, grace)
    CreateThread(function()
        local start = GetGameTimer()
        local deadline = start + CANCEL_WATCH_MS
        while GetGameTimer() < deadline do
            Wait(0)
            if not DoesEntityExist(veh) then return end
            if GetVehiclePedIsTryingToEnter(ped) ~= veh then
                if GetGameTimer() - start > (grace or 0) then return end
                goto continue
            end
            if IsPedInAnyVehicle(ped, true) then return end   -- climbing in: committed, as GTA's is
            local stop = IsControlJustPressed(0, CONTROL_ENTER) or IsDisabledControlJustPressed(0, CONTROL_ENTER)
            if not stop then
                local lr, ud = GetControlNormal(0, CONTROL_MOVE_LR), GetControlNormal(0, CONTROL_MOVE_UD)
                if lr * lr + ud * ud >= CANCEL_PUSH * CANCEL_PUSH then
                    -- The push in the world: the camera's right times across, its forward times up.
                    local h = math.rad(GetGameplayCamRot(2).z)
                    local wx = math.cos(h) * lr + math.sin(h) * ud
                    local wy = math.sin(h) * lr - math.cos(h) * ud
                    local p, v = GetEntityCoords(ped), GetEntityCoords(veh)
                    stop = wx * (v.x - p.x) + wy * (v.y - p.y) < 0   -- away from the car
                end
            end
            if stop then
                -- The next tick sees no get-in and forgets `retasked`, so F again is handled afresh.
                ClearPedTasks(ped)
                return
            end
            ::continue::
        end
    end)
end

--- Into `seat` of `veh`, walking there the way F does, for a prompt that offers it (client/vehicle_prompts.lua's
--- Get On and Board). A script task like the get-in above, so it comes with the same cancel:
--- pushing away from the vehicle, or F / Y, stops it.
---@param veh number
---@param seat number  -1 the driver's
function Seats.enter(veh, seat)
    local ped = PlayerPedId()
    if ped == 0 or not DoesEntityExist(veh) then return end
    local speed = (IsPedRunning(ped) or IsPedSprinting(ped)) and 2.0 or 1.0
    TaskEnterVehicle(ped, veh, CANCEL_WATCH_MS, seat, speed, ENTER_RESUME, 0)
    watchCancel(ped, veh, 500)
end

--- F at the passenger door of an empty car: into the passenger seat by that door, no slide.
local function checkEntry(ped)
    local veh = GetVehiclePedIsTryingToEnter(ped)
    if veh == 0 then retasked = 0 return end
    if veh == retasked or GetSeatPedIsTryingToEnter(ped) ~= -1 then return end
    -- Somebody driving it is GTA's to settle (getting in beside them, or pulling them out).
    if not IsVehicleSeatFree(veh, -1) then return end
    if GetVehicleMaxNumberOfPassengers(veh) < 1 or not seatFree(veh, 0) then return end
    -- Only a car with a door of its own on each side: a bus's one door IS the driver's way in, and a
    -- boat or an aircraft has no such doors at all. Those are GTA's to settle.
    local class = GetVehicleClass(veh)
    if class == 14 or class == 15 or class == 16 then return end   -- boats, helicopters, planes
    if GetEntityBoneIndexByName(veh, 'door_dside_f') == -1 or GetEntityBoneIndexByName(veh, 'door_pside_f') == -1 then
        return
    end
    local bone = GetEntityBoneIndexByName(veh, 'seat_dside_f')
    if bone == -1 then return end   -- no driver's side to come round from (a bike)
    local seatAt, pedAt = GetWorldPositionOfEntityBone(veh, bone), GetEntityCoords(ped)
    local driverX = GetOffsetFromEntityGivenWorldCoords(veh, seatAt.x, seatAt.y, seatAt.z).x
    local pedX = GetOffsetFromEntityGivenWorldCoords(veh, pedAt.x, pedAt.y, pedAt.z).x
    if driverX * pedX >= 0 then return end   -- at the driver's side: GTA's own door, no slide
    retasked = veh
    local speed = (IsPedRunning(ped) or IsPedSprinting(ped)) and 2.0 or 1.0
    TaskEnterVehicle(ped, veh, CANCEL_WATCH_MS, 0, speed, ENTER_RESUME | ENTER_NO_SLIDE, 0)
    watchCancel(ped, veh)
end

--- A slide to the driver's seat whip did not start: put the ped back where it sits.
local function backstop(ped)
    if moving or not GetIsTaskActive(ped, TASK_SEAT_SHUFFLE) then return end
    if GetSeatPedIsTryingToEnter(ped) ~= -1 then return end
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 then return end
    local seat = seatOf(veh, ped)
    if seat and seat ~= -1 then SetPedIntoVehicle(ped, veh, seat) end
end

--- Called by client/vehicles.lua's 200 ms vehicle tick (on foot too), so this costs no wake of its own.
---@param ped number
---@param inVehicle boolean  sitting in one (not just getting in)
function Seats.tick(ped, inVehicle)
    if not on() then return end
    assertFlags(ped)
    hold(inVehicle)
    if inVehicle then
        backstop(ped)
    elseif entryMode == 'retask' then
        checkEntry(ped)
    end
end

-- Changed in /whip → Settings (in place, so `cfg` sees it). Off: whip lets go of everything at once;
-- on: the next tick puts it back.
Settings.onChange('Seats.NoAutoShuffle', function(value)
    if value == false then
        hold(false)
        clearFlags()
    end
end)

-- ---- moving seat --------------------------------------------------------------

--- GTA's slide across to the seat beside, waited out. True when the ped landed in `to`.
local function slide(ped, veh, to)
    local lift = to == -1 and on()   -- flag 184 may stop a slide into the driver's seat, even ours
    if lift then SetPedConfigFlag(ped, FLAG_NO_SHUFFLE_TO_DRIVER, false) end
    TaskShuffleToNextVehicleSeat(ped, veh)
    local started = false
    local deadline = GetGameTimer() + 600
    repeat
        Wait(50)
        if GetIsTaskActive(ped, TASK_SEAT_SHUFFLE) then started = true end
    until started or GetGameTimer() >= deadline
    if started then
        local done = GetGameTimer() + 4500
        while GetIsTaskActive(ped, TASK_SEAT_SHUFFLE) and GetGameTimer() < done do Wait(100) end
    end
    if lift then SetPedConfigFlag(ped, FLAG_NO_SHUFFLE_TO_DRIVER, true) end
    return GetVehiclePedIsIn(ped, false) == veh and seatOf(veh, ped) == to
end

--- The move itself, once the server has said yes.
local function move(ped, veh, from, to)
    local inline = isInline(veh)
    local key = ('%d:%d>%d'):format(GetEntityModel(veh), from, to)
    if not inline and rowOf(from, false) == rowOf(to, false) and not noSlide[key]
       and not IsTurretSeat(veh, from) and not IsTurretSeat(veh, to) then
        if slide(ped, veh, to) then return end
        noSlide[key] = true   -- GTA's slide from here goes elsewhere, or nowhere: teleport next time
    end
    if GetVehiclePedIsIn(ped, false) == veh and seatOf(veh, ped) ~= to and seatFree(veh, to) then
        WeaponLock.beforeSeat(ped, veh, to)   -- a turret seat's gun comes only with the lock already off
        SetPedIntoVehicle(ped, veh, to)
    end
end

--- Move this player to `to` in the vehicle they are in. Runs in a thread (it waits for the server).
---@param veh number
---@param to number|nil  -1 is the driver's seat
---@return boolean ok, string|nil why
function Seats.moveTo(veh, to)
    if moving then return false, 'Already changing seat' end
    local ped = PlayerPedId()
    if veh == 0 or GetVehiclePedIsIn(ped, false) ~= veh then return false, 'You need to be in that vehicle' end
    to = math.tointeger(tonumber(to))
    if not to or to < -1 or to > GetVehicleMaxNumberOfPassengers(veh) - 1 then return false, 'No such seat' end
    local from = seatOf(veh, ped)
    if not from then return false, 'You are not in a seat yet' end
    if from == to then return true end
    if not seatFree(veh, to) then return false, 'That seat is occupied' end

    -- A car only this game has (a showroom's preview) is nobody else's to race for.
    if NetworkGetEntityIsNetworked(veh) then
        local ok, why = Callback('whip_core:seats:claim', NetworkGetNetworkIdFromEntity(veh), to)
        if not ok then return false, why or 'You cannot move there' end
    end

    -- The round trip took a moment: the same car and seat, and the new one still free?
    ped = PlayerPedId()
    if GetVehiclePedIsIn(ped, false) ~= veh or seatOf(veh, ped) ~= from then return false, nil end
    if not seatFree(veh, to) then return false, 'That seat is occupied' end

    moving = true
    local ok, err = pcall(move, ped, veh, from, to)
    moving = false
    if not ok then
        print(('[whip_core:seats] moving to seat %d failed: %s'):format(to, tostring(err)))
        return false, 'You could not move there'
    end
    return true
end

-- ---- the Seats page of the F1 wheel -----------------------------------------------

--- Bumped by each page shown and by its close, so a page's live loop ends with it.
local pageTurn = 0

--- What the page shows, as it is now.
local function buildSeats(veh, ped)
    local count  = GetVehicleMaxNumberOfPassengers(veh) + 1
    local inline = isInline(veh)
    local class  = GetVehicleClass(veh)
    local bike   = class == 8 or class == 13
    local mine   = seatOf(veh, ped)
    local seats  = {}
    for s = -1, count - 2 do
        local label
        if s == -1 then label = bike and 'Rider' or 'Driver'
        elseif s == 0 then label = (inline and bike) and 'Pillion' or 'Passenger'
        elseif count == 4 then label = s == 1 and 'Rear left' or 'Rear right'
        else label = 'Seat ' .. (s + 2) end
        seats[#seats + 1] = {
            seat   = s,
            label  = label,
            row    = rowOf(s, inline),
            col    = inline and 0 or (s + 1) % 2,
            state  = (s == mine) and 'you' or (seatFree(veh, s) and 'free' or 'occupied'),
            turret = IsTurretSeat(veh, s) and true or false,   -- a BOOL native: 1, never true
        }
    end
    local model = GetEntityModel(veh)
    local name = GetDisplayNameFromVehicleModel(model)
    local text = GetLabelText(name)
    if not text or text == 'NULL' then text = name end
    return { title = text, inline = inline, seats = seats }
end

local function signature(data)
    local parts = {}
    for i, s in ipairs(data.seats) do parts[i] = s.state end
    return table.concat(parts, ',')
end

--- Show the Seats page on the open wheel: Seats' callback (it keeps the wheel up), or /seats.
---@return boolean shown
function Seats.openPage()
    if not PlayerLoaded or PlayerIsDead then return false end
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 then say('You need to be in a vehicle', 'error') return false end

    pageTurn = pageTurn + 1
    local turn = pageTurn
    local data = buildSeats(veh, ped)
    local sig = signature(data)
    local shown = RadialPage.show({
        id     = 'seats',
        data   = data,
        -- The wheel has closed by now; the move waits for the server, so it gets a thread.
        onPick = function(value)
            CreateThread(function()
                local ok, why = Seats.moveTo(veh, value)
                if not ok and why then say(why, 'error') end
            end)
        end,
        -- Only this page's own close ends its loop: a newer page has a newer turn.
        onClose = function() if pageTurn == turn then pageTurn = pageTurn + 1 end end,
    })
    if not shown then
        pageTurn = pageTurn + 1
        return false
    end

    -- Live while up, born with the page: someone getting in or out changes what is free. Twice a
    -- second, sent only when a seat's state changed. Out of the vehicle, or down, the wheel closes.
    CreateThread(function()
        while pageTurn == turn do
            Wait(500)
            if pageTurn ~= turn then return end
            local p = PlayerPedId()
            if PlayerIsDead or not DoesEntityExist(veh) or GetVehiclePedIsIn(p, false) ~= veh then
                RadialPage.close()
                return
            end
            local d = buildSeats(veh, p)
            local now = signature(d)
            if now ~= sig then
                sig = now
                RadialPage.update('seats', d)
            end
        end
    end)
    return true
end

-- Straight to the Seats page: the wheel opens (with all of F1's refusals) on it.
RegisterCommand('seats', function()
    if not RadialPage.open() then return end
    if not Seats.openPage() then RadialPage.close() end
end, false)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if on() then clearFlags() end   -- GTA's own way while whip_core is down
end)
