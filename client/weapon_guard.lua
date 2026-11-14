-- Weapon guard: no GTA gun that whip did not hand out (a dead NPC's gun, a police car's shotgun). Three layers,
-- none per frame:
--   1. Pickups: every weapon's pickup type is uncollectable for this player at each spawn.
--   2. Drops: the player's ped never drops its gun on death (config flag 14).
--   3. Sweep: anything on the ped that no whip system gave is taken away, when a weapon can arrive (vehicle
--      entered, pickup collected, spawn) and on a slow clock (Config.WeaponGuard.SweepMs).
-- A system giving a native weapon says so first: WeaponGuard.permit, or the PermitNativeWeapon export from a
-- satellite. Config.WeaponGuard.Allow names the rest.

WeaponGuard = {}

--- Every weapon a ped can carry (those with a world model, plus the parachute); damage causes and vehicle guns
--- are left out. A weapon missing here is never swept.
local WEAPON_NAMES = {
    -- digiscanner, fire extinguisher, hacking device, metal detector, briefcases
    'WEAPON_DIGISCANNER', 'WEAPON_FIREEXTINGUISHER', 'WEAPON_HACKINGDEVICE', 'WEAPON_METALDETECTOR',
    'WEAPON_BRIEFCASE', 'WEAPON_BRIEFCASE_02', 'WEAPON_BRIEFCASE_03',
    -- heavy
    'WEAPON_AIRSTRIKE_ROCKET', 'WEAPON_COMPACTLAUNCHER', 'WEAPON_EMPLAUNCHER', 'WEAPON_FIREWORK',
    'WEAPON_GRENADELAUNCHER', 'WEAPON_GRENADELAUNCHER_SMOKE', 'WEAPON_HOMINGLAUNCHER',
    'WEAPON_MINIGUN', 'WEAPON_PASSENGER_ROCKET', 'WEAPON_RAILGUN', 'WEAPON_RAILGUNXM3',
    'WEAPON_RAYMINIGUN', 'WEAPON_RPG', 'WEAPON_SNOWLAUNCHER', 'WEAPON_STINGER',
    'WEAPON_VEHICLE_ROCKET',
    -- melee
    'WEAPON_BAT', 'WEAPON_BATTLEAXE', 'WEAPON_BOTTLE', 'WEAPON_CANDYCANE', 'WEAPON_CROWBAR',
    'WEAPON_DAGGER', 'WEAPON_FLASHLIGHT', 'WEAPON_GOLFCLUB', 'WEAPON_HAMMER', 'WEAPON_HATCHET',
    'WEAPON_KNIFE', 'WEAPON_MACHETE', 'WEAPON_NIGHTSTICK', 'WEAPON_POOLCUE', 'WEAPON_STONE_HATCHET',
    'WEAPON_STUNROD', 'WEAPON_SWITCHBLADE', 'WEAPON_WRENCH', 'WEAPON_KNUCKLE',
    -- mg
    'WEAPON_COMBATMG', 'WEAPON_COMBATMG_MK2', 'WEAPON_GUSENBERG', 'WEAPON_MG', 'WEAPON_RAYCARBINE',
    -- parachute, cans
    'GADGET_PARACHUTE', 'WEAPON_FERTILIZERCAN', 'WEAPON_HAZARDCAN', 'WEAPON_PETROLCAN',
    -- pistol
    'WEAPON_APPISTOL', 'WEAPON_CERAMICPISTOL', 'WEAPON_COMBATPISTOL', 'WEAPON_DOUBLEACTION',
    'WEAPON_FLAREGUN', 'WEAPON_GADGETPISTOL', 'WEAPON_HEAVYPISTOL', 'WEAPON_MARKSMANPISTOL',
    'WEAPON_NAVYREVOLVER', 'WEAPON_PISTOL', 'WEAPON_PISTOL50', 'WEAPON_PISTOLXM3', 'WEAPON_PISTOL_MK2',
    'WEAPON_RAYPISTOL', 'WEAPON_REVOLVER', 'WEAPON_REVOLVER_MK2', 'WEAPON_SNSPISTOL',
    'WEAPON_SNSPISTOL_MK2', 'WEAPON_VINTAGEPISTOL',
    -- rifle
    'WEAPON_ADVANCEDRIFLE', 'WEAPON_ASSAULTRIFLE', 'WEAPON_ASSAULTRIFLE_MK2', 'WEAPON_BATTLERIFLE',
    'WEAPON_BULLPUPRIFLE', 'WEAPON_BULLPUPRIFLE_MK2', 'WEAPON_CARBINERIFLE', 'WEAPON_CARBINERIFLE_MK2',
    'WEAPON_COMPACTRIFLE', 'WEAPON_HEAVYRIFLE', 'WEAPON_MILITARYRIFLE', 'WEAPON_SPECIALCARBINE',
    'WEAPON_SPECIALCARBINE_MK2', 'WEAPON_STRICKLER', 'WEAPON_TACTICALRIFLE',
    -- shotgun
    'WEAPON_ASSAULTSHOTGUN', 'WEAPON_AUTOSHOTGUN', 'WEAPON_BULLPUPSHOTGUN', 'WEAPON_COMBATSHOTGUN',
    'WEAPON_DBSHOTGUN', 'WEAPON_HEAVYSHOTGUN', 'WEAPON_PUMPSHOTGUN', 'WEAPON_PUMPSHOTGUN_MK2',
    'WEAPON_SAWNOFFSHOTGUN',
    -- smg
    'WEAPON_ASSAULTSMG', 'WEAPON_COMBATPDW', 'WEAPON_MACHINEPISTOL', 'WEAPON_MICROSMG',
    'WEAPON_MINISMG', 'WEAPON_SMG', 'WEAPON_SMG_MK2', 'WEAPON_TECPISTOL',
    -- sniper
    'WEAPON_HEAVYSNIPER', 'WEAPON_HEAVYSNIPER_MK2', 'WEAPON_MARKSMANRIFLE', 'WEAPON_MARKSMANRIFLE_MK2',
    'WEAPON_MUSKET', 'WEAPON_PRECISIONRIFLE', 'WEAPON_SNIPERRIFLE',
    -- stun guns, tranquilizer
    'WEAPON_STUNGUN', 'WEAPON_STUNGUN_MP', 'WEAPON_TRANQUILIZER',
    -- thrown
    'WEAPON_ACIDPACKAGE', 'WEAPON_BALL', 'WEAPON_BIRD_CRAP', 'WEAPON_BZGAS', 'WEAPON_FLARE',
    'WEAPON_GRENADE', 'WEAPON_MOLOTOV', 'WEAPON_NEWSPAPER', 'WEAPON_PIPEBOMB', 'WEAPON_PROXMINE',
    'WEAPON_SMOKEGRENADE', 'WEAPON_SNOWBALL', 'WEAPON_STICKYBOMB',
}

--- A weapon hash as one number however it arrives (GetHashKey answers signed; other sources can be unsigned).
---@param h number|string
---@return integer|nil
local function norm(h)
    if type(h) == 'string' then h = GetHashKey(h) end
    local n = math.tointeger(h)
    if not n then return nil end
    if n < 0 then n = n + 4294967296 end
    return n
end

local WEAPONS, NAME = {}, {}
for _, name in ipairs(WEAPON_NAMES) do
    local h = norm(name) --[[@as integer]]   -- a name always hashes
    WEAPONS[#WEAPONS + 1] = h
    NAME[h] = name
end

local cfg = Config.WeaponGuard or {}
local allowed = {}          -- [hash] = true: Config.WeaponGuard.Allow, read once
for _, name in ipairs(cfg.Allow or {}) do
    local h = norm(name)
    if h then allowed[h] = true end
end

--- [hash] = true while a whip system has handed this player that weapon. Uses shared/registry.lua: several
--- resources may permit one weapon, and it goes when the last lets go or stops.
local permits = {}
local permitReg = Registry.new('weaponPermits', { label = 'weapon permit', store = permits, shared = true })

--- Say this player may hold `weapon` (on = true), or no longer (on = false). Call before giving the weapon and
--- after taking it away. `owner` is the resource; its permits go when it stops.
---@param owner string
---@param weapon number|string
---@param on boolean
function WeaponGuard.permit(owner, weapon, on)
    local h = norm(weapon)
    if not h then return false end
    if on then return (permitReg:add(owner, h, true)) end
    if permits[h] ~= nil then permitReg:remove(owner, h) end   -- not this owner's: nothing to take back
    return true
end

exports('PermitNativeWeapon', function(weapon, on)
    return WeaponGuard.permit(Registry.caller(), weapon, on == true)
end)

--- Take away every weapon on the ped that nothing permits. `why` is for the F8 line.
---@param why string
function WeaponGuard.sweep(why)
    if cfg.Enabled == false then return end
    local ped = PlayerPedId()
    if ped == 0 or not DoesEntityExist(ped) then return end
    local taken
    for i = 1, #WEAPONS do
        local h = WEAPONS[i]
        if not allowed[h] and not permits[h] and HasPedGotWeapon(ped, h, false) then
            RemoveWeaponFromPed(ped, h)
            taken = taken or {}
            taken[#taken + 1] = NAME[h]
        end
    end
    if taken then
        print(('[whip_core:weapons] took %s (%s): not handed out by whip'):format(table.concat(taken, ', '), why))
    end
end

--- Layers 1 and 2, for the current ped. Set once each spawn.
local function settle()
    if cfg.Enabled == false then return end
    local player, ped = PlayerId(), PlayerPedId()
    for i = 1, #WEAPONS do
        local pickup = GetPickupHashFromWeapon(WEAPONS[i])
        if pickup and pickup ~= 0 then ToggleUsePickupsForPlayer(player, pickup, false) end
    end
    if ped ~= 0 then SetPedConfigFlag(ped, 14, true) end   -- CPED_CONFIG_FLAG_DoesntDropWeaponsWhenDead
    WeaponGuard.sweep('spawn')
end

AddEventHandler('whip_core:player:spawned', settle)
AddEventHandler('whip_core:player:revived', settle)
AddEventHandler('whip_core:appearance:modelChanged', settle)

-- Changed in /whip Settings (fields change in place, so `cfg` sees them; SweepMs is read at each wait).
-- The allowed list is re-read, and anything no longer allowed is taken at once.
Settings.onChange('WeaponGuard.Allow', function()
    for h in pairs(allowed) do allowed[h] = nil end
    for _, name in ipairs(cfg.Allow or {}) do
        local h = norm(name)
        if h then allowed[h] = true end
    end
    WeaponGuard.sweep('settings')
end)

-- Turned on: pickups blocked and the ped set, as at a spawn. Turned off: both undone.
Settings.onChange('WeaponGuard.Enabled', function(on)
    if on ~= false then
        settle()
        return
    end
    local player, ped = PlayerId(), PlayerPedId()
    for i = 1, #WEAPONS do
        local pickup = GetPickupHashFromWeapon(WEAPONS[i])
        if pickup and pickup ~= 0 then ToggleUsePickupsForPlayer(player, pickup, true) end
    end
    if ped ~= 0 then SetPedConfigFlag(ped, 14, false) end
end)

-- A vehicle's reward (police shotgun, aircraft parachute) lands as you sit: checked then, and twice more in case
-- GTA hands it over later.
AddEventHandler('whip_core:vehicle:entered', function()
    WeaponGuard.sweep('vehicle')
    SetTimeout(1000, function() WeaponGuard.sweep('vehicle') end)
    SetTimeout(3000, function() WeaponGuard.sweep('vehicle') end)
end)

-- A pickup collected anyway: taken back straight away.
AddEventHandler('gameEventTriggered', function(name)
    if name == 'CEventNetworkPlayerCollectedPickup' or name == 'CEventNetworkPlayerCollectedAmbientPickup' then
        WeaponGuard.sweep('pickup')
    end
end)

-- The backstop, on a slow clock: whatever no event above caught.
CreateThread(function()
    settle()
    while true do
        Wait(math.max(1000, tonumber(cfg.SweepMs) or 5000))
        WeaponGuard.sweep('check')
    end
end)
