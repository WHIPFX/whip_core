-- ============================================
-- THE AIM DOT: whip's crosshair, for any weapon
-- ============================================
--
-- While the player aims, GTA's reticle gives way to a dot (Config.AimDot). It sits where the weapon points: the
-- middle of the screen, or, with the muzzle up against something the camera sees past, on that, in red. A melee
-- weapon and the petrol can get none; a thrown weapon (give mode's ball too) gets the middle, as it arcs.
--
-- Something aimed that is not a weapon in the hand holds the dot up while it aims (the AimDot export).

local NO_DOT = {
    [GetHashKey('GROUP_UNARMED') & 0xFFFFFFFF]   = true,
    [GetHashKey('GROUP_MELEE') & 0xFFFFFFFF]     = true,
    [GetHashKey('GROUP_PETROLCAN') & 0xFFFFFFFF] = true,
}
local MIDDLE = { [GetHashKey('GROUP_THROWN') & 0xFFFFFFFF] = true }

local RAY_FLAGS  = 1 + 2 + 8   -- the map, vehicles, objects
local RAY_LENGTH = 3.0         -- how far past the muzzle something counts
local NEAR_MUZZLE = 1.5        -- a hit closer than this is checked against what the camera sees
local RAY_EVERY  = 3           -- frames between rays; the dot holds still in between
local IDLE_MS    = 250         -- nothing that aims in the hand: looked at this often

local holds = {}               -- [resource] = true while it aims something with no weapon of its own
local shown = nil              -- what the page shows: { x, y, blocked }, nil when hidden
local gunEntity, muzzleBone = nil, -1
local frame = 0
local running = false

local function enabled() return Config.AimDot ~= false end

--- 'muzzle', 'middle', or nil for a weapon that gets no dot.
local function dotKind(ped)
    local group = GetWeapontypeGroup(GetSelectedPedWeapon(ped)) & 0xFFFFFFFF
    if NO_DOT[group] then return nil end
    return MIDDLE[group] and 'middle' or 'muzzle'
end

local function show(x, y, blocked)
    if shown and shown.x == x and shown.y == y and shown.blocked == blocked then return end
    shown = { x = x, y = y, blocked = blocked }
    SendNUIMessage({ action = 'aimDot', on = true, x = x, y = y, blocked = blocked })
end

local function hide()
    if not shown then return end
    shown = nil
    SendNUIMessage({ action = 'aimDot', on = false })
end

--- Where the gun points: the middle, or the spot on a wall right in front of the muzzle that the camera sees past.
local function muzzlePoint(ped)
    ---@diagnostic disable-next-line: redundant-parameter -- p1, NativeDB's 2nd: not in the natives' docs
    local gun = GetCurrentPedWeaponEntityIndex(ped, 0)
    if not gun or gun == 0 then return 0.5, 0.5, false end
    if gun ~= gunEntity then
        gunEntity = gun
        local bone = GetEntityBoneIndexByName(gun, 'gun_muzzle')
        muzzleBone = bone ~= -1 and bone or 7
    end

    local camPos, camRot = GetGameplayCamCoord(), GetGameplayCamRot(2)
    local rz, rx = math.rad(camRot.z), math.rad(camRot.x)
    local cx = math.abs(math.cos(rx))
    local dir = vector3(-math.sin(rz) * cx, math.cos(rz) * cx, math.sin(rx))

    local muzzle = GetWorldPositionOfEntityBone(gun, muzzleBone)
    local to = muzzle + dir * RAY_LENGTH
    local _, hit, at = GetShapeTestResult(StartShapeTestRay(muzzle.x, muzzle.y, muzzle.z, to.x, to.y, to.z, RAY_FLAGS, ped, 0))
    if hit ~= 1 then return 0.5, 0.5, false end
    local near = #(muzzle - at)
    if near >= NEAR_MUZZLE then return 0.5, 0.5, false end

    local camTo = camPos + dir * RAY_LENGTH
    local _, camHit, camAt = GetShapeTestResult(StartShapeTestRay(camPos.x, camPos.y, camPos.z, camTo.x, camTo.y, camTo.z, RAY_FLAGS, ped, 0))
    local camFar = camHit == 1 and #(camPos - camAt) or RAY_LENGTH
    if near >= camFar - 0.3 then return 0.5, 0.5, false end

    local onScreen, sx, sy = GetScreenCoordFromWorldCoord(at.x, at.y, at.z)
    if not onScreen then return 0.5, 0.5, true end
    return sx, sy, true
end

local function loop()
    if running then return end
    running = true
    CreateThread(function()
        local player = PlayerId()
        while enabled() do
            local ped = PlayerPedId()
            local kind = dotKind(ped)
            local held = next(holds) ~= nil
            local aiming = held or (kind ~= nil and IsPlayerFreeAiming(player))
            if not aiming then
                hide()
                frame = 0
                Wait(kind and 0 or IDLE_MS)
            else
                HideHudComponentThisFrame(14)   -- GTA's reticle
                if kind == 'muzzle' then
                    frame = frame + 1
                    if not shown or frame >= RAY_EVERY then
                        frame = 0
                        show(muzzlePoint(ped))
                    end
                else
                    show(0.5, 0.5, false)
                end
                Wait(0)
            end
        end
        hide()
        gunEntity = nil
        running = false
    end)
end

--- Hold the dot up while a resource aims something that is not a weapon in the hand; false lets go.
exports('AimDot', function(on)
    holds[GetInvokingResource() or GetCurrentResourceName()] = on == true or nil
    if next(holds) then loop() end
end)

AddEventHandler('onResourceStop', function(res) holds[res] = nil end)

Settings.onChange('AimDot', function() if enabled() then loop() end end)
loop()
