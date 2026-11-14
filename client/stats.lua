-- ============================================
-- Client Stats — Display layer for PlayerStats
-- Receives stat updates from server, applies to
-- ped (vitals) and local cache (needs/custom).
-- No authority — server owns all values.
-- ============================================

local ClientStats = {}
local ClientEffects = {}
local _changeListeners = {}  -- [name] = { ['<resource>:<id>'] = { fn, owner } } — keyed, see OnStatChange
-- Run a stat's change listeners. Defined further down, beside callListener; declared here because
-- the sync handlers above it call it.
local _fireListeners
-- Remember why the server took health, for the death report. Defined beside the damage tracker below.
local _noteScriptedLoss

-- What this client last applied to its OUTGOING damage (see Outgoing Damage Modifiers below).
local _outGun, _outMelee = 1.0, 1.0

--- Reset outgoing damage modifiers to default (called on death/revive/logout). Forced, and the
--- remembered values with them, so the loop below re-applies a target's modifier afterwards
--- instead of believing it is still in place.
function ResetDamageModifiers()
    SetPlayerWeaponDamageModifier(PlayerId(), 1.0)
    ---@diagnostic disable-next-line: redundant-parameter -- p2: one of the game's parameters the natives' typing leaves out
    SetPlayerMeleeWeaponDamageModifier(PlayerId(), 1.0, true)
    _outGun, _outMelee = 1.0, 1.0
end

-- ============================================
-- Server → Client Events
-- ============================================

--- Bulk sync (on login and periodic).
--- Updates local cache for HUD/exports but does NOT apply health/armour
--- to the ped. Combat damage owns the ped — we don't want periodic syncs
--- to "heal" the player by overwriting combat damage with cached values.
--- Has a bulk sync landed yet?
---
--- Read by the character load sequence so the screen does not come back up while the HUD still
--- shows defaults.
StatsSynced = false

RegisterNetEvent('whip_core:client:statsSync', function(stats, effects)
    StatsSynced = true
    if stats then
        for name, value in pairs(stats) do
            local old = ClientStats[name]
            ClientStats[name] = value
            -- Do NOT apply vitals to ped here — only statUpdate does that
            if old ~= value then
                _fireListeners(name, value, old)
            end
        end
    end
    if effects then
        ClientEffects = effects
    end
end)

--- Single stat update from a FRAMEWORK change (item use, respawn, effect).
--- This is the ONLY event that applies health/armour to the ped.
--- Combat damage flows the other direction: ped → reportVitals → server.
RegisterNetEvent('whip_core:client:statUpdate', function(name, value, delta, cause)
    local old = ClientStats[name]

    -- Apply vitals to ped ONLY from framework changes.
    --
    -- By the amount, when the server sent one: added to the ped's LIVE health or armour, not
    -- replaced with the server's figure (which trails the ped, and would undo damage taken since the
    -- last report). An amount never lifts a dead ped: a revive arrives as an absolute value.
    -- A loss comes with its `cause` (Starvation, an effect's name...), noted before the ped takes it.
    if delta ~= nil and (name == 'health' or name == 'armour') then
        local ped = PlayerPedId()
        if name == 'health' then
            if not (delta > 0 and IsEntityDead(ped)) then
                local max = GetEntityMaxHealth(ped)
                value = math.max(0, math.min(max > 0 and max or 200, GetEntityHealth(ped) + delta))
                if delta < 0 and not IsEntityDead(ped) then _noteScriptedLoss(cause) end
                SetEntityHealth(ped, math.floor(value))
            else
                value = GetEntityHealth(ped)
            end
        else
            value = math.max(0, math.min(100, GetPedArmour(ped) + delta))
            SetPedArmour(ped, math.floor(value))
        end
        ClientStats[name] = value
    else
        ClientStats[name] = value
        -- Not while the death screen owns the ped: a late death value (health 100) would knock it
        -- out of the death pose. The number still reaches the HUD; a revive or respawn sets the
        -- ped's health itself (client/death.lua).
        if not PlayerIsDead then
            if name == 'health' then
                local ped = PlayerPedId()
                if math.floor(value) < GetEntityHealth(ped) then _noteScriptedLoss(cause) end
                SetEntityHealth(ped, math.floor(value))
            elseif name == 'armour' then
                SetPedArmour(PlayerPedId(), math.floor(value))
            end
        end
    end

    if old ~= value then
        _fireListeners(name, value, old)
    end
end)

--- Effect applied
RegisterNetEvent('whip_core:client:effectApplied', function(name, data)
    ClientEffects[name] = data
end)

--- Effect removed
RegisterNetEvent('whip_core:client:effectRemoved', function(name)
    ClientEffects[name] = nil
end)

--- Logging out ends THIS character's numbers (stats, effects), so the next character starts clean.
--- StatsSynced goes false too, so the load sequence waits for the new character's sync.
RegisterNetEvent('whip_core:client:playerLogout', function()
    ClientStats   = {}
    ClientEffects = {}
    StatsSynced   = false
end)

-- ============================================
-- VOICE RANGE — client-owned
--
-- Not a Config.Stats entry: the player changes it locally and instantly, and a server-synced
-- stat would snap back on the next sync. The def is injected into the HUD list on arrival and the
-- value written straight into the update payload.
-- ============================================

local VOICE_LEVELS = { 20, 50, 100 }
local VOICE_NAMES  = { 'Whisper', 'Normal', 'Shout' }
local voiceIndex   = 2   -- start at Normal

local VOICE_HUD_DEF = {
    name  = 'voice',
    type  = 'custom',
    max   = 100,
    color = '#a78bfa',   -- violet: distinct from health/armour/hunger/thirst
    -- Material "mic". Single path, which is what buildStatElement expects.
    icon  = 'M12 14c1.66 0 3-1.34 3-3V5c0-1.66-1.34-3-3-3S9 3.34 9 5v6c0 1.66 1.34 3 3 3zm5.3-3c0 '
         .. '3-2.54 5.1-5.3 5.1S6.7 14 6.7 11H5c0 3.41 2.72 6.23 6 6.72V21h2v-3.28c3.28-.49 6-3.31 '
         .. '6-6.72h-1.7z',
    -- A walkie-talkie, shown instead of the mic while talking ON THE RADIO (SetVoiceTalking(true,
    -- 'radio')). One path: antenna and body drawn clockwise, the screen and grille slots against
    -- it, so they are cut out.
    iconRadio = 'M8 6H16A2 2 0 0 1 18 8V21A2 2 0 0 1 16 23H8A2 2 0 0 1 6 21V8A2 2 0 0 1 8 6Z'
             .. 'M7 1.5H8.6V6H7Z'
             .. 'M8.5 8.5V12.5H15.5V8.5Z'
             .. 'M8.5 15V16.5H15.5V15Z'
             .. 'M8.5 18.5V20H15.5V18.5Z',
    order         = 0,   -- ahead of health, which is 1
    heartbeat     = false,
    hideWhenEmpty = false,
    -- A quiet voice is a choice, not a warning: whisper must never turn the icon red.
    noCritical    = true,
    showAboveZero = false,
}

--- The current voice level as a percentage, for the HUD payload.
function GetVoiceLevel()
    return VOICE_LEVELS[voiceIndex] or 50
end

--- The current level's name. Nothing displays it yet; proximity voice will want it.
function GetVoiceName()
    return VOICE_NAMES[voiceIndex] or 'Normal'
end

-- The HUD's voice-range bar. A voice resource (whip_voice) turns the level into metres and
-- tells its server; without one, nobody hears anyone by range and this is display only.
exports('GetVoiceLevel', GetVoiceLevel)
exports('GetVoiceName', GetVoiceName)

RegisterCommand('whip_cyclevoice', function()
    if not IsGameInputFree() then return end   -- Z typed into a search box is not a voice change
    voiceIndex = voiceIndex % #VOICE_LEVELS + 1
    -- For the voice resource: the range to use now. Local only (types/events.lua).
    WhipEmit('whip_core:voice:rangeChanged', { index = voiceIndex, name = GetVoiceName(), level = GetVoiceLevel() })
end, false)

-- The gauge lights blue while the player transmits (a voice resource says when); the page recolours
-- it (.talking, html/css/status-hud.css). Sent the moment it changes, not on the HUD's 200 ms poll.
--
-- Orange, with a radio for the mic, while talking on the radio (mode 'radio'). Switching between the
-- two while still talking is sent too.
--
-- Held by the resource that set it, and switched off if that resource stops.
local voiceTalking, voiceTalkingBy, voiceMode = false, nil, nil

local function setVoiceTalking(on, by, mode)
    on = on == true
    mode = (on and mode == 'radio') and 'radio' or nil
    voiceTalkingBy = on and by or nil
    if on == voiceTalking and mode == voiceMode then return end
    voiceTalking, voiceMode = on, mode
    SendNUIMessage({ action = 'setVoiceTalking', talking = on, mode = mode })
end

exports('SetVoiceTalking', function(talking, mode) setVoiceTalking(talking, GetInvokingResource(), mode) end)

AddEventHandler('onResourceStop', function(res)
    if voiceTalking and res == voiceTalkingBy then setVoiceTalking(false) end
end)

RegisterKeyMapping('whip_cyclevoice', 'Cycle Voice Range', 'keyboard', 'Z')

--- The values the HUD bridge last pushed to the NUI.
---
--- A persistent table, mutated in place (the bridge below runs five times a second).
local _lastHudSent = {}

--- How many keys _lastHudSent holds, so "did a stat appear or disappear" is an integer compare
--- rather than a second walk.
---
--- -1 means "nothing has been sent yet" and forces the next tick to send.
local _lastHudCount = -1

--- HUD stat definitions (icons, colors, order)
RegisterNetEvent('whip_core:client:hudDefs', function(defs)
    -- Prepended rather than appended: the server sends these pre-sorted by order and the
    -- renderer lays them out in array order, so position IS the sort here. Rebuilt on every
    -- hudDefs broadcast, so a stat registered at runtime cannot drop the microphone.
    local withVoice = { VOICE_HUD_DEF }
    for _, def in ipairs(defs or {}) do
        withVoice[#withVoice + 1] = def
    end

    SendNUIMessage({ action = 'registerHudStats', stats = withVoice })

    -- A rebuilt HUD starts empty and must be repainted even if no value moved. The count is what
    -- carries that now — see _lastHudCount.
    _lastHudCount = -1
end)

-- ============================================
-- Change Listeners
-- ============================================

-- A listener that throws is said once per listener and error, filed under its resource (ErrorTap.caught), never
-- swallowed. Once: a stat changes every few seconds.
local _saidListenerError = {}

--- One listener, positional or one table as it registered (the `table` option, as on the server).
local function callListener(reg, wildcard, name, value, old)
    local ok, err
    if reg.asTable then
        ok, err = pcall(reg.fn, { key = name, value = value, old = old })
    elseif wildcard then
        ok, err = pcall(reg.fn, name, value, old)
    else
        ok, err = pcall(reg.fn, value, old)
    end
    if not ok then
        local key = ('%s|%s|%s'):format(tostring(reg.owner), tostring(name), tostring(err))
        if not _saidListenerError[key] then
            _saidListenerError[key] = true
            ErrorTap.caught(('[whip_core:stats] ERROR in %s\'s OnStatChange("%s"): %s')
                :format(tostring(reg.owner), tostring(name), tostring(err)), reg.owner)
        end
    end
end

function _fireListeners(name, value, old)   -- assigns the local declared at the top of this file
    local listeners = _changeListeners[name]
    if listeners then
        for _, reg in pairs(listeners) do
            callListener(reg, false, name, value, old)
        end
    end
    -- Also fire wildcard listeners
    local wildcards = _changeListeners['*']
    if wildcards then
        for _, reg in pairs(wildcards) do
            callListener(reg, true, name, value, old)
        end
    end
end

-- ============================================
-- Client Exports
-- ============================================

exports('GetStat', function(name)
    return ClientStats[name]
end)

--- The same read for whip_core's own client files (GetPlayerData in client/player.lua), without a
--- trip through the export.
---@param name string
---@return number|nil
function ClientStatValue(name)
    return ClientStats[name]
end

--- A copy of every stat. Global: whip_core's own /mystatus reads it without the export.
function GetAllStats()
    local copy = {}
    for k, v in pairs(ClientStats) do
        copy[k] = v
    end
    return copy
end
exports('GetAllStats', GetAllStats)

exports('HasEffect', function(name)
    return ClientEffects[name] ~= nil
end)

exports('GetEffects', function()
    local copy = {}
    for k, v in pairs(ClientEffects) do
        copy[k] = v
    end
    return copy
end)

--- Be told when one of your stats changes: callback(value, old), or for '*' callback(name, value, old).
---
--- Keyed, not appended: `<your resource>:<id>`, where `id` defaults to the stat name, so a second
--- call with the same id REPLACES the first (registering from onReady is safe). Pass a distinct `id`
--- to hold two listeners on one stat. Cleared when your resource stops. The same shape as
--- OnVehicleStatChange (client/vehicle_stats.lua).
---
--- Options, the same as the server's OnStatChange and OnVehicleStatChange, third or fourth after an
--- `id`:
---   * `table = true` — one table instead: { key, value, old }.
---   * `now = true`   — also called once straight away with the current value (old = nil).
--- Answers `true`, or `false, reason`.
---@param name string          stat name, or '*' for every stat
---@param callback function
---@param id string|nil
---@param opts table|nil       { table?: boolean, now?: boolean }
---@return boolean registered
---@return string|nil err
exports('OnStatChange', function(name, callback, id, opts)
    local owner = GetInvokingResource() or GetCurrentResourceName()
    if type(name) ~= 'string' or name == '' then return false, "name is required (a stat name, or '*')" end
    -- `callback ~= nil`, not a type test: a callback that crossed the export is not type 'function'.
    if callback == nil then return false, 'callback is required' end
    if type(id) == 'table' and opts == nil then id, opts = nil, id end
    opts = type(opts) == 'table' and opts or {}
    local key = owner .. ':' .. tostring(id or name)

    if not _changeListeners[name] then _changeListeners[name] = {} end
    local reg = { fn = callback, owner = owner, asTable = opts.table == true }
    _changeListeners[name][key] = reg

    -- `now`: off the registration path, so the caller has its `true` first.
    if opts.now then
        CreateThread(function()
            if name == '*' then
                for statName, value in pairs(ClientStats) do callListener(reg, true, statName, value, nil) end
            elseif ClientStats[name] ~= nil then
                callListener(reg, false, name, ClientStats[name], nil)
            end
        end)
    end
    return true
end)

AddEventHandler('onResourceStop', function(res)
    for name, listeners in pairs(_changeListeners) do
        for key, reg in pairs(listeners) do
            if reg.owner == res then listeners[key] = nil end
        end
        if next(listeners) == nil then _changeListeners[name] = nil end
    end
end)

-- In GetRegistrations with the registries (Registry.addLister).
Registry.addLister('statListener', function()
    local out = {}
    for name, listeners in pairs(_changeListeners) do
        for key, reg in pairs(listeners) do out[#out + 1] = { key = name .. ' ' .. tostring(key), owner = reg.owner } end
    end
    return out
end)

-- ============================================
-- Combat Damage Source Tracking
-- Listens to CEventNetworkEntityDamage to identify
-- what caused damage (weapon, vehicle, explosion, etc.)
-- and who the attacker was. Consumed by reportVitals.
-- ============================================

-- Weapon hash → readable name lookup
-- Environmental damage + all standard weapons. Uses GetHashKey at load time.
--
-- Many of these names come from txAdmin's death reasons (resource/cl_logger.lua, github.com/tabarra/txAdmin, by André
-- Tabarra), under the MIT licence:
--
--   Copyright (c) 2019-2025 Take-Two Interactive Software, Inc.
--
--   Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
--   documentation files (the "Software"), to deal in the Software without restriction, including without limitation
--   the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and
--   to permit persons to whom the Software is furnished to do so, subject to the following conditions:
--
--   The above copyright notice and this permission notice shall be included in all copies or substantial portions of
--   the Software.
--
--   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
--   THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
--   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
--   CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
--   IN THE SOFTWARE.
local WEAPON_NAMES = {
    -- Environmental / special
    [GetHashKey('WEAPON_DROWNING')]              = 'Drowning',
    [GetHashKey('WEAPON_DROWNING_IN_VEHICLE')]   = 'Drowning (Vehicle)',
    [GetHashKey('WEAPON_FALL')]                  = 'Fall',
    [GetHashKey('WEAPON_RUN_OVER_BY_CAR')]       = 'Vehicle Hit',
    [GetHashKey('WEAPON_EXPLOSION')]             = 'Explosion',
    [GetHashKey('WEAPON_FIRE')]                  = 'Fire',
    [GetHashKey('WEAPON_BLEEDING')]              = 'Bleeding',
    [GetHashKey('WEAPON_ELECTRIC_FENCE')]        = 'Electric Fence',
    [GetHashKey('WEAPON_BARBED_WIRE')]           = 'Barbed Wire',
    [GetHashKey('WEAPON_EXHAUSTION')]            = 'Exhaustion',
    [GetHashKey('WEAPON_HIT_BY_WATER_CANNON')]   = 'Water Cannon',
    [GetHashKey('WEAPON_VEHICLE_ROCKET')]        = 'Vehicle Rocket',
    [133987706]                                  = 'Vehicle Crash',  -- 0x7FC7D7A — vehicle collision damage
    -- Melee
    [GetHashKey('WEAPON_UNARMED')]               = 'Fist',
    [GetHashKey('WEAPON_KNIFE')]                 = 'Knife',
    [GetHashKey('WEAPON_NIGHTSTICK')]            = 'Nightstick',
    [GetHashKey('WEAPON_HAMMER')]                = 'Hammer',
    [GetHashKey('WEAPON_BAT')]                   = 'Bat',
    [GetHashKey('WEAPON_CROWBAR')]               = 'Crowbar',
    [GetHashKey('WEAPON_GOLFCLUB')]              = 'Golf Club',
    [GetHashKey('WEAPON_BOTTLE')]                = 'Bottle',
    [GetHashKey('WEAPON_DAGGER')]                = 'Dagger',
    [GetHashKey('WEAPON_HATCHET')]               = 'Hatchet',
    [GetHashKey('WEAPON_KNUCKLE')]               = 'Knuckle Duster',
    [GetHashKey('WEAPON_MACHETE')]               = 'Machete',
    [GetHashKey('WEAPON_FLASHLIGHT')]            = 'Flashlight',
    [GetHashKey('WEAPON_SWITCHBLADE')]           = 'Switchblade',
    [GetHashKey('WEAPON_POOLCUE')]               = 'Pool Cue',
    [GetHashKey('WEAPON_WRENCH')]                = 'Wrench',
    [GetHashKey('WEAPON_BATTLEAXE')]             = 'Battle Axe',
    [GetHashKey('WEAPON_STONE_HATCHET')]         = 'Stone Hatchet',
    -- Pistols
    [GetHashKey('WEAPON_PISTOL')]                = 'Pistol',
    [GetHashKey('WEAPON_PISTOL_MK2')]            = 'Pistol Mk2',
    [GetHashKey('WEAPON_COMBATPISTOL')]          = 'Combat Pistol',
    [GetHashKey('WEAPON_APPISTOL')]              = 'AP Pistol',
    [GetHashKey('WEAPON_PISTOL50')]              = 'Pistol .50',
    [GetHashKey('WEAPON_SNSPISTOL')]             = 'SNS Pistol',
    [GetHashKey('WEAPON_SNSPISTOL_MK2')]         = 'SNS Pistol Mk2',
    [GetHashKey('WEAPON_HEAVYPISTOL')]           = 'Heavy Pistol',
    [GetHashKey('WEAPON_VINTAGEPISTOL')]         = 'Vintage Pistol',
    [GetHashKey('WEAPON_MARKSMANPISTOL')]        = 'Marksman Pistol',
    [GetHashKey('WEAPON_REVOLVER')]              = 'Heavy Revolver',
    [GetHashKey('WEAPON_REVOLVER_MK2')]          = 'Heavy Revolver Mk2',
    [GetHashKey('WEAPON_DOUBLEACTION')]           = 'Double Action Revolver',
    [GetHashKey('WEAPON_CERAMICPISTOL')]         = 'Ceramic Pistol',
    [GetHashKey('WEAPON_NAVYREVOLVER')]          = 'Navy Revolver',
    [GetHashKey('WEAPON_GADGETPISTOL')]          = 'Perico Pistol',
    [GetHashKey('WEAPON_STUNGUN')]               = 'Stun Gun',
    [GetHashKey('WEAPON_FLAREGUN')]              = 'Flare Gun',
    [GetHashKey('WEAPON_RAYPISTOL')]             = 'Up-n-Atomizer',
    -- SMGs
    [GetHashKey('WEAPON_MICROSMG')]              = 'Micro SMG',
    [GetHashKey('WEAPON_SMG')]                   = 'SMG',
    [GetHashKey('WEAPON_SMG_MK2')]               = 'SMG Mk2',
    [GetHashKey('WEAPON_ASSAULTSMG')]            = 'Assault SMG',
    [GetHashKey('WEAPON_COMBATPDW')]             = 'Combat PDW',
    [GetHashKey('WEAPON_MACHINEPISTOL')]         = 'Machine Pistol',
    [GetHashKey('WEAPON_MINISMG')]               = 'Mini SMG',
    [GetHashKey('WEAPON_RAYCARBINE')]            = 'Unholy Hellbringer',
    -- Shotguns
    [GetHashKey('WEAPON_PUMPSHOTGUN')]           = 'Pump Shotgun',
    [GetHashKey('WEAPON_PUMPSHOTGUN_MK2')]       = 'Pump Shotgun Mk2',
    [GetHashKey('WEAPON_SAWNOFFSHOTGUN')]        = 'Sawed-Off Shotgun',
    [GetHashKey('WEAPON_ASSAULTSHOTGUN')]        = 'Assault Shotgun',
    [GetHashKey('WEAPON_BULLPUPSHOTGUN')]        = 'Bullpup Shotgun',
    [GetHashKey('WEAPON_MUSKET')]                = 'Musket',
    [GetHashKey('WEAPON_HEAVYSHOTGUN')]          = 'Heavy Shotgun',
    [GetHashKey('WEAPON_DBSHOTGUN')]             = 'Double Barrel Shotgun',
    [GetHashKey('WEAPON_AUTOSHOTGUN')]           = 'Sweeper Shotgun',
    [GetHashKey('WEAPON_COMBATSHOTGUN')]         = 'Combat Shotgun',
    -- Rifles
    [GetHashKey('WEAPON_ASSAULTRIFLE')]          = 'Assault Rifle',
    [GetHashKey('WEAPON_ASSAULTRIFLE_MK2')]      = 'Assault Rifle Mk2',
    [GetHashKey('WEAPON_CARBINERIFLE')]          = 'Carbine Rifle',
    [GetHashKey('WEAPON_CARBINERIFLE_MK2')]      = 'Carbine Rifle Mk2',
    [GetHashKey('WEAPON_ADVANCEDRIFLE')]         = 'Advanced Rifle',
    [GetHashKey('WEAPON_SPECIALCARBINE')]        = 'Special Carbine',
    [GetHashKey('WEAPON_SPECIALCARBINE_MK2')]    = 'Special Carbine Mk2',
    [GetHashKey('WEAPON_BULLPUPRIFLE')]          = 'Bullpup Rifle',
    [GetHashKey('WEAPON_BULLPUPRIFLE_MK2')]      = 'Bullpup Rifle Mk2',
    [GetHashKey('WEAPON_COMPACTRIFLE')]          = 'Compact Rifle',
    [GetHashKey('WEAPON_MILITARYRIFLE')]         = 'Military Rifle',
    [GetHashKey('WEAPON_HEAVYRIFLE')]            = 'Heavy Rifle',
    [GetHashKey('WEAPON_TACTICALRIFLE')]         = 'Tactical Rifle',
    -- LMGs
    [GetHashKey('WEAPON_MG')]                    = 'MG',
    [GetHashKey('WEAPON_COMBATMG')]              = 'Combat MG',
    [GetHashKey('WEAPON_COMBATMG_MK2')]          = 'Combat MG Mk2',
    [GetHashKey('WEAPON_GUSENBERG')]             = 'Gusenberg Sweeper',
    -- Snipers
    [GetHashKey('WEAPON_SNIPERRIFLE')]           = 'Sniper Rifle',
    [GetHashKey('WEAPON_HEAVYSNIPER')]           = 'Heavy Sniper',
    [GetHashKey('WEAPON_HEAVYSNIPER_MK2')]       = 'Heavy Sniper Mk2',
    [GetHashKey('WEAPON_MARKSMANRIFLE')]         = 'Marksman Rifle',
    [GetHashKey('WEAPON_MARKSMANRIFLE_MK2')]     = 'Marksman Rifle Mk2',
    [GetHashKey('WEAPON_PRECISIONRIFLE')]        = 'Precision Rifle',
    -- Heavy
    [GetHashKey('WEAPON_RPG')]                   = 'RPG',
    [GetHashKey('WEAPON_GRENADELAUNCHER')]       = 'Grenade Launcher',
    [GetHashKey('WEAPON_MINIGUN')]               = 'Minigun',
    [GetHashKey('WEAPON_FIREWORK')]              = 'Firework Launcher',
    [GetHashKey('WEAPON_RAILGUN')]               = 'Railgun',
    [GetHashKey('WEAPON_HOMINGLAUNCHER')]        = 'Homing Launcher',
    [GetHashKey('WEAPON_COMPACTLAUNCHER')]       = 'Compact Grenade Launcher',
    [GetHashKey('WEAPON_RAYMINIGUN')]            = 'Widowmaker',
    -- Throwables
    [GetHashKey('WEAPON_GRENADE')]               = 'Grenade',
    [GetHashKey('WEAPON_BZGAS')]                 = 'BZ Gas',
    [GetHashKey('WEAPON_MOLOTOV')]               = 'Molotov',
    [GetHashKey('WEAPON_STICKYBOMB')]            = 'Sticky Bomb',
    [GetHashKey('WEAPON_PROXMINE')]              = 'Proximity Mine',
    [GetHashKey('WEAPON_SNOWBALL')]              = 'Snowball',
    [GetHashKey('WEAPON_PIPEBOMB')]              = 'Pipe Bomb',
    [GetHashKey('WEAPON_SMOKEGRENADE')]          = 'Tear Gas',
    [GetHashKey('WEAPON_FLARE')]                 = 'Flare',
    [GetHashKey('WEAPON_PETROLCAN')]             = 'Jerry Can',
}

-- The weapons other resources add (Whip.weapons: whip_gunny's own guns), by hash: built again when the catalog changes.
local addedNames, addedAt = {}, -1
local function addedWeaponLabel(hash)
    if addedAt ~= WeaponCatalog.version then
        addedNames, addedAt = {}, WeaponCatalog.version
        for _, w in ipairs(WeaponCatalog.list()) do
            if w.from then addedNames[GetHashKey(w.name)] = w.label end
        end
    end
    return addedNames[hash]
end

--- Resolve a weapon hash to a readable name.
---@param hash number
---@return string
local function GetWeaponLabel(hash)
    if not hash or hash == 0 then return 'unknown' end
    return WEAPON_NAMES[hash] or addedWeaponLabel(hash) or ('0x%X'):format(hash)
end

-- Last damage context — written by gameEventTriggered, consumed by reportVitals
local _lastDamageSource = nil  -- string: e.g. "Pistol by John Smith (#3)" or "explosion" or "vehicle hit"
local _lastDamageTime   = 0    -- GetGameTimer when last damage was recorded

--- Global accessor for death.lua to read the last damage source (killing blow)
---@return string|nil source
---@return number timestamp
function GetLastDamageSource()
    return _lastDamageSource, _lastDamageTime
end

-- Health the server took (a need at empty, an effect, a script: statUpdate above), and when. GTA reports a script's
-- SetEntityHealth as a fall with no attacker, so for SCRIPTED_LOSS_MS such a "fall" is read as this cause instead:
-- a player who starves dies of Starvation, not Fall.
local _scriptedLoss, _scriptedLossAt = nil, 0
local SCRIPTED_LOSS_MS = 500
local WEAPON_FALL = GetHashKey('WEAPON_FALL')

---@param cause string|nil
_noteScriptedLoss = function(cause)
    if type(cause) ~= 'string' or cause == '' then return end
    _scriptedLoss, _scriptedLossAt = cause, GetGameTimer()
    _lastDamageSource, _lastDamageTime = cause, _scriptedLossAt
end

AddEventHandler('gameEventTriggered', function(eventName, args)
    if eventName ~= 'CEventNetworkEntityDamage' then return end

    -- Only care about damage to our ped
    local myPed = PlayerPedId()
    if args[1] ~= myPed then return end

    local attacker   = args[2]
    local weaponHash = args[7]

    -- The server's loss landing (_noteScriptedLoss): keep its cause.
    local byOther = attacker and attacker ~= 0 and attacker ~= myPed and DoesEntityExist(attacker)
    if weaponHash == WEAPON_FALL and not byOther and _scriptedLoss
        and GetGameTimer() - _scriptedLossAt < SCRIPTED_LOSS_MS then
        _lastDamageSource, _lastDamageTime = _scriptedLoss, GetGameTimer()
        return
    end

    -- ---- Damage Source Tracking (for debug overlay / death log) ----
    local weaponLabel = GetWeaponLabel(weaponHash)
    local dmgSource = weaponLabel

    if byOther then
        local entityType = GetEntityType(attacker)

        if entityType == 1 then
            local attackerPlayer = NetworkGetPlayerIndexFromPed(attacker)
            if attackerPlayer ~= -1 then
                local attackerServerId = GetPlayerServerId(attackerPlayer)
                local attackerName = GetPlayerName(attackerPlayer) or 'Unknown'
                dmgSource = ('%s by %s (#%d)'):format(weaponLabel, attackerName, attackerServerId)
            else
                dmgSource = weaponLabel .. ' (NPC)'
            end
        elseif entityType == 2 then
            local driver = GetPedInVehicleSeat(attacker, -1)
            if driver and driver ~= 0 then
                local driverPlayer = NetworkGetPlayerIndexFromPed(driver)
                if driverPlayer ~= -1 then
                    local driverServerId = GetPlayerServerId(driverPlayer)
                    local driverName = GetPlayerName(driverPlayer) or 'Unknown'
                    dmgSource = ('vehicle hit by %s (#%d)'):format(driverName, driverServerId)
                else
                    dmgSource = 'vehicle hit (NPC)'
                end
            else
                dmgSource = 'vehicle hit'
            end
        end
    end

    _lastDamageSource = dmgSource
    _lastDamageTime = GetGameTimer()
end)

-- ============================================
-- Outgoing Damage Modifiers (attacker-side prediction fix)
-- Reads the target player's damageModifier / meleeModifier statebag and
-- scales this client's outgoing damage to match, so the attacker's
-- client predicts the hit correctly (prevents false death ragdoll).
-- The target is whoever this player aims at — free aim OR lock-on — and,
-- with fists or a melee weapon, whoever they are fighting.
-- ============================================

--- The modifier a player's bag asks for, held to the configured range, or 1.0 for anything else
--- (not a ped, not a player, no modifier).
---
--- A number, or nothing (the bag is client-writable; a string or NaN would throw and end the loop).
--- The clamp is the range the server holds modifiers to (Stats' clampModifier), bounding a spoof
--- until the Sentinel's correction replicates.
---@param ped number|nil
---@param key string
---@return number
local function bagModifier(ped, key)
    if not ped or ped == 0 or not DoesEntityExist(ped) or not IsEntityAPed(ped) then return 1.0 end
    local idx = NetworkGetPlayerIndexFromPed(ped)
    if idx == -1 then return 1.0 end
    local v = tonumber(Player(GetPlayerServerId(idx)).state[key])
    if not v or v ~= v then return 1.0 end
    local c = Config.Sentinel and Config.Sentinel.damageModifierClamp or { min = 0.05, max = 4.0 }
    return math.min(c.max, math.max(c.min, v))
end

--- The ped behind something aimed at: itself, or a vehicle's driver.
local function pedOf(entity)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return nil end
    if GetEntityType(entity) == 2 then return GetPedInVehicleSeat(entity, -1) end
    return entity
end

local function applyOutgoing(gun, melee)
    if gun ~= _outGun then
        SetPlayerWeaponDamageModifier(PlayerId(), gun)
        _outGun = gun
    end
    if melee ~= _outMelee then
        ---@diagnostic disable-next-line: redundant-parameter -- p2: one of the game's parameters the natives' typing leaves out
        SetPlayerMeleeWeaponDamageModifier(PlayerId(), melee, true)
        _outMelee = melee
    end
end

CreateThread(function()
    local unarmedHash = GetHashKey('WEAPON_UNARMED')
    local meleeGroup = GetHashKey('GROUP_MELEE')

    while true do
        if not PlayerLoaded or PlayerIsDead then
            Wait(500)
            goto continue
        end

        local cost = WhipCost.start()
        local pid, ped = PlayerId(), PlayerPedId()
        local _, weapon = GetCurrentPedWeapon(ped, false)
        local melee = weapon == unarmedHash or weapon == 0 or GetWeapontypeGroup(weapon) == meleeGroup

        -- Who this player is going for: free aim (mouse) and lock-on (a controller, assisted aim, a
        -- fist fight's right-click) are different natives. With no aim, a melee swing still has a
        -- target; hip fire has none, and stays at 1.0.
        local target, busy = nil, false
        if IsPlayerFreeAiming(pid) then
            local _, e = GetEntityPlayerIsFreeAimingAt(pid)
            target, busy = pedOf(e), true
        elseif IsPlayerTargettingAnything(pid) then
            local _, e = GetPlayerTargetEntity(pid)
            target, busy = pedOf(e), true
        end
        if melee then
            if not target then
                local m = GetMeleeTargetForPed(ped)
                if m and m ~= 0 then target = m end
            end
            busy = busy or IsPedInMeleeCombat(ped)
            -- meleeModifier, for fists and melee weapons.
            applyOutgoing(1.0, bagModifier(target, PLAYER_MELEEMOD_KEY))
        else
            applyOutgoing(bagModifier(target, PLAYER_DMGMOD_KEY), 1.0)
        end

        -- 50ms while aiming or fighting, not per-frame (several entity natives and a statebag read a
        -- pass). Slow poll otherwise.
        WhipCost.stop('player stats: damage modifiers (aim and melee)', cost)
        Wait(busy and 50 or 150)

        ::continue::
    end
end)

-- ============================================
-- HUD Bridge + Combat Damage Reporting
-- Polls ped every 200ms. Updates HUD. Reports
-- health/armour changes to server so Stats cache
-- stays current (server natives are unreliable).
-- ============================================

-- ============================================
-- OXYGEN — the breath under water (server/stats.lua's builtInStats says why it is a stat)
-- ============================================
--
-- The server's number, like hunger: the server's tick drains it under water and brings it back above
-- (server/stats.lua, tickOxygen); this game says only WHETHER the player is under water (BodyState.underwater,
-- client/body_state.lua, sent with the vitals report on a change), and draws the gauge from the number the server sends.
--
-- And this game drowns the player when whip says the breath is gone: whip gives the ped the game's longest breath
-- (BREATH_GAME, 50 s; the setting is held under it on the server) while whip's lasts, and none once whip's is 0,
-- so GTA drowns the ped as it always does and a death under water still reads as drowning. In a seat whip drowns
-- them itself (drownInCar): GTA's own drowning in a sunk car cannot be counted on.
--
-- A float, always, to SetPedMaxTimeUnderwater: an integer passed to a float parameter is read as its bits (10
-- arrives as about 1e-44 seconds). Hence the literals.
local BREATH_GAME, BREATH_NONE = 50.0, 0.0
local breathPed, breathGiven = 0, nil
local emptySince = nil   -- when whip's breath was first seen at 0, for the grace (Config.OxygenGraceSeconds)

--- The game's breath for this ped, from whip's: its longest while whip's lasts, none once whip's is gone. Given
--- again to every new ped (a death, a revive and a model change each make one).
---@param ped number
local function giveBreath(ped)
    -- A grace at empty: the game's breath goes only once whip's has been 0 for Config.OxygenGraceSeconds. Any breath
    -- back starts the grace again next time.
    local empty = (tonumber(ClientStats.oxygen) or 100) <= 0
    local now = GetGameTimer()
    if not empty then emptySince = nil elseif not emptySince then emptySince = now end
    local grace = math.max(0.0, math.min(10.0, tonumber(Config.OxygenGraceSeconds) or 1.0)) * 1000.0
    local want = (empty and now - emptySince >= grace) and BREATH_NONE or BREATH_GAME
    if ped == breathPed and want == breathGiven then return end
    breathPed, breathGiven = ped, want
    SetPedMaxTimeUnderwater(ped, want)
end

local DROWN_STEP = 4   -- health each look (200 ms) takes in a sunk car: from full to drowned in about 5 s
local DROWNED_IN_CAR = GetHashKey('WEAPON_DROWNING_IN_VEHICLE')

--- Whip's breath gone (past the grace) in a sunk car: the seat drowns them, as the water does. GTA's own drowning
--- in a seat did not (Josh, 29 Oct: the car pushed in during the login's arrival, while it held him invincible, and
--- he sat on the bottom for good). Read as GTA's 'Drowning (Vehicle)', and never while something holds them
--- invincible (God Mode, a no-PvP zone, a scene).
---@param ped number
---@param under boolean  BodyState.underwater's answer this look
local function drownInCar(ped, under)
    if not under or breathGiven ~= BREATH_NONE or not IsPedInAnyVehicle(ped, false) then return end
    if IsEntityDead(ped) or PedHold.wants('invincible') then return end
    local health = GetEntityHealth(ped) - DROWN_STEP
    _lastDamageSource, _lastDamageTime = GetWeaponLabel(DROWNED_IN_CAR), GetGameTimer()
    SetEntityHealth(ped, health > 100 and health or 0)   -- 100 and under is dead for a player: straight to 0
end

CreateThread(function()
    while not PlayerLoaded do Wait(500) end

    local lastReportedHealth = -1
    local lastReportedArmour = -1
    local lastReportedUnder = nil
    local DAMAGE_CONTEXT_WINDOW = 1000 -- ms: how recent damage context must be to include it

    --- The payload, allocated ONCE and refilled every tick. `action` is set here because it never
    --- changes and the wipe below deliberately leaves it alone.
    local hudData = { action = 'updateStatusHud' }

    while true do
        Wait(200)
        if not PlayerLoaded or PlayerIsDead then
            Wait(500)
            goto continue
        end

        local cost = WhipCost.start()
        local ped = PlayerPedId()
        local health = GetEntityHealth(ped)
        local armour = GetPedArmour(ped)

        -- The breath (OXYGEN above): the game's from whip's, and whether the player is under water, for the server.
        giveBreath(ped)
        local under = BodyState.underwater(ped)
        drownInCar(ped, under)

        -- Report combat damage to server (server can't read ped reliably)
        if health ~= lastReportedHealth or armour ~= lastReportedArmour or under ~= lastReportedUnder then
            local context = nil
            local now = GetGameTimer()
            if _lastDamageSource and (now - _lastDamageTime) < DAMAGE_CONTEXT_WINDOW then
                context = _lastDamageSource
            end

            lastReportedHealth = health
            lastReportedArmour = armour
            lastReportedUnder = under
            TriggerServerEvent('whip_core:server:reportVitals', health, armour, context, under)
        end

        -- Update HUD — vitals from ped natives, everything else from ClientStats.
        --
        -- Refilled, not rebuilt: hudData is allocated once and wiped here (SendNUIMessage
        -- serialises the table before it returns).
        for k in pairs(hudData) do
            if k ~= 'action' then hudData[k] = nil end
        end

        hudData.health = health
        hudData.armour = armour

        for name, value in pairs(ClientStats) do
            if name ~= 'health' and name ~= 'armour' then
                hudData[name] = value
            end
        end

        -- After the ClientStats copy: voice range is client-owned, so a server 'voice' key must
        -- not win.
        hudData.voice = GetVoiceLevel()

        -- Only on change. One walk: counting the keys while comparing them also catches a stat
        -- that appeared or vanished (the count changes).
        local changed, n = false, 0
        for k, v in pairs(hudData) do
            if k ~= 'action' then
                n = n + 1
                if _lastHudSent[k] ~= v then changed = true end
            end
        end
        if n ~= _lastHudCount then changed = true end

        if changed then
            SendNUIMessage(hudData)

            -- Copied in place. Clearing first is what makes a removed stat actually leave —
            -- assigning over the top would keep its last value forever.
            for k in pairs(_lastHudSent) do _lastHudSent[k] = nil end
            for k, v in pairs(hudData) do
                if k ~= 'action' then _lastHudSent[k] = v end
            end
            _lastHudCount = n
        end

        WhipCost.stop('player stats: health, armour and the HUD (5 a second)', cost)

        ::continue::
    end
end)

-- ============================================
-- Debug Overlay (NUI)
-- ============================================

local debugActive = false

RegisterNetEvent('whip_core:client:statsDebug', function(data)
    if not debugActive then return end
    SendNUIMessage({ action = 'statsDebug', data = data })
end)

-- ---- The cards over the players near you (tools/debug_cards.lua) ----

local STAT_NAMES = { health = 'Health', armour = 'Armour', hunger = 'Hunger', thirst = 'Thirst', developer = 'Developer',
                     oxygen = 'Oxygen' }

--- One player's card: their name, charId, and each stat as a bar (health counted from 100, GTA's dead,
--- as the HUD does).
---@param e table  { s, n, c, stats = { { n, v, m, t, c } } } from server/stats.lua
local function playerCard(e)
    local rows = {}
    for i, s in ipairs(e.stats or {}) do
        local v, m = tonumber(s.v) or 0, tonumber(s.m) or 100
        local pct = (s.t == 'vital' and m == 200) and (v - 100) or (m > 0 and v / m * 100 or 0)
        local name = STAT_NAMES[s.n] or (tostring(s.n):sub(1, 1):upper() .. tostring(s.n):sub(2))
        rows[i] = { n = name, p = math.floor(pct + 0.5), v = ('%d / %s'):format(math.floor(v + 0.5), tostring(s.m)), c = s.c }
    end
    return { title = tostring(e.n or '?'), sub = '#' .. tostring(e.c or '?'), rows = rows }
end

RegisterNetEvent('whip_core:client:statsDebugNearby', function(list)
    if not debugActive or type(list) ~= 'table' or not DebugCards then return end
    local keep = {}
    for _, e in ipairs(list) do
        local idx = type(e) == 'table' and GamePlatform.playerIndex(e.s) or nil
        local ped = idx and GetPlayerPed(idx) or 0
        -- Only a player this game can see: the card hangs on their ped.
        if ped ~= 0 and DoesEntityExist(ped) then
            local key = 'p:' .. tostring(e.s)
            keep[key] = true
            DebugCards.set(key, ped, playerCard(e))
        end
    end
    DebugCards.keep('p:', keep)
end)

--- Toggle debug overlay (called from dev tools). `want` (true/false) sets it instead of flipping: /w
--- turning it off after the chat command already did must not turn it back on.
---@param want boolean|nil
function ToggleStatsDebug(want)
    if want ~= nil and (want == true) == debugActive then return debugActive end
    debugActive = not debugActive
    if debugActive then
        TriggerServerEvent('whip_core:server:statsDebugOn')
        SendNUIMessage({ action = 'statsDebugShow' })
    else
        TriggerServerEvent('whip_core:server:statsDebugOff')
        SendNUIMessage({ action = 'statsDebugHide' })
        if DebugCards then DebugCards.keep('p:', {}) end   -- the cards over other players go too
    end
    return debugActive
end
