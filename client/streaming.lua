-- ============================================
-- STREAMING — load a model, an animation or a texture, with a limit
-- ============================================
--
-- One way to wait for the game to load something, bounded, and exported for satellites:
--
--     local hash = exports.whip_core:LoadModel('prop_beer_bottle')     -- hash, or nil
--     if not hash then return end
--     local obj = CreateObject(hash, x, y, z, true, true, false)
--     SetModelAsNoLongerNeeded(hash)                                   -- yours to release
--
--     if exports.whip_core:LoadAnimDict('mp_player_intdrink') then ... end
--
-- They WAIT, so call them from a thread (a command, an event handler, a CreateThread), and they
-- never wait longer than the limit: a model that is not in the game answers at once, and anything
-- that does not arrive in time answers nil/false rather than holding the caller.

local DEFAULT_MS = 5000

--- Wait until `loaded()` or `ms` have passed. Answers `loaded()`.
---@param loaded fun(): boolean
---@param ms number
---@return boolean
local function waitFor(loaded, ms)
    local deadline = GetGameTimer() + ms
    while not loaded() and GetGameTimer() < deadline do
        Wait(10)
    end
    return loaded() and true or false
end

--- Models the game threw on when asked for (a native exception in RequestModel: seen with an add-on weapon's model,
--- which is only a weapon archetype, asked for as an item's prop). Said once in F8, by name; asked again each time,
--- so a model that fails once is never kept from every other caller. (An item's prop that fails stands as the
--- default box from then on: Inventory.loadItemProp.)
local saidThrew = {}

--- Load a model. Answers its hash once it is loaded, or nil and why: 'missing' (not a model the game has), 'timeout'
--- (not loaded within `timeoutMs`, default 5000) or 'error' (the game threw when asked for it). Release it with
--- SetModelAsNoLongerNeeded when done. The why is for whip_core's own callers: across the export it is cut at the
--- nil, so satellites see the hash or nil.
---@param model string|number  a name or a hash
---@param timeoutMs number|nil
---@return number|nil hash
---@return string|nil why  'missing' | 'timeout' | 'error'
function LoadModel(model, timeoutMs)
    local hash = type(model) == 'number' and model or GetHashKey(tostring(model))
    if not IsModelInCdimage(hash) then return nil, 'missing' end
    if HasModelLoaded(hash) then return hash end
    -- The game's request can throw rather than just never load. Answered, not thrown: thrown, it ended the caller's
    -- thread, and the ground items' streaming with it.
    local ok, err = pcall(RequestModel, hash)
    if not ok then
        if not saidThrew[hash] then
            saidThrew[hash] = true
            print(('^1[whip_core:streaming] the game threw loading model %s (%s): %s^7'):format(tostring(model),
                tostring(hash), tostring(err)))
        end
        return nil, 'error'
    end
    if waitFor(function() return HasModelLoaded(hash) end, tonumber(timeoutMs) or DEFAULT_MS) then
        return hash
    end
    return nil, 'timeout'
end

--- Load an animation dictionary. Answers true once it is loaded, false if it did not load within
--- `timeoutMs` (default 5000) — a name the game does not have never does.
---@param dict string
---@param timeoutMs number|nil
---@return boolean
function LoadAnimDict(dict, timeoutMs)
    if type(dict) ~= 'string' or dict == '' then return false end
    if HasAnimDictLoaded(dict) then return true end
    if DoesAnimDictExist and not DoesAnimDictExist(dict) then return false end
    RequestAnimDict(dict)
    return waitFor(function() return HasAnimDictLoaded(dict) end, tonumber(timeoutMs) or DEFAULT_MS)
end

--- Load a streamed texture dictionary (sprites for DrawSprite). Answers true once loaded, false if
--- not within `timeoutMs` (default 5000).
---@param dict string
---@param timeoutMs number|nil
---@return boolean
function LoadTextureDict(dict, timeoutMs)
    if type(dict) ~= 'string' or dict == '' then return false end
    if HasStreamedTextureDictLoaded(dict) then return true end
    RequestStreamedTextureDict(dict, false)
    return waitFor(function() return HasStreamedTextureDictLoaded(dict) end, tonumber(timeoutMs) or DEFAULT_MS)
end

--- Load a movement clip set (walk styles, SetPedMovementClipset). Answers true once loaded, false if
--- not within `timeoutMs` (default 5000).
---@param set string
---@param timeoutMs number|nil
---@return boolean
function LoadAnimSet(set, timeoutMs)
    if type(set) ~= 'string' or set == '' then return false end
    if HasAnimSetLoaded(set) then return true end
    RequestAnimSet(set)
    return waitFor(function() return HasAnimSetLoaded(set) end, tonumber(timeoutMs) or DEFAULT_MS)
end

--- Load a named particle asset (UseParticleFxAssetNextCall). Answers true once loaded, false if not
--- within `timeoutMs` (default 5000).
---@param asset string
---@param timeoutMs number|nil
---@return boolean
function LoadPtfxAsset(asset, timeoutMs)
    if type(asset) ~= 'string' or asset == '' then return false end
    if HasNamedPtfxAssetLoaded(asset) then return true end
    RequestNamedPtfxAsset(asset)
    return waitFor(function() return HasNamedPtfxAssetLoaded(asset) end, tonumber(timeoutMs) or DEFAULT_MS)
end

--- [weapon hash] = how many users hold its asset now (LoadWeaponAsset / ReleaseWeaponAsset)
local weaponUsers = {}

--- Load a weapon's asset (its model and projectile: for a shot or a throw made by script). Answers true once loaded,
--- false if not within `timeoutMs` (default 5000). COUNTED: every call, loaded or not, is one user, given back with
--- ReleaseWeaponAsset; the asset is let go only when the last user gives it back, so two bursts of one gun never
--- pull it from under each other.
---@param weapon string|number  a name or a hash
---@param timeoutMs number|nil
---@return boolean
function LoadWeaponAsset(weapon, timeoutMs)
    local hash = type(weapon) == 'number' and weapon or GetHashKey(tostring(weapon))
    weaponUsers[hash] = (weaponUsers[hash] or 0) + 1
    if HasWeaponAssetLoaded(hash) then return true end
    RequestWeaponAsset(hash, 31, 0)
    return waitFor(function() return HasWeaponAssetLoaded(hash) end, tonumber(timeoutMs) or DEFAULT_MS)
end

--- One user of a weapon's asset done with it (LoadWeaponAsset): the asset goes with the last.
---@param weapon string|number
function ReleaseWeaponAsset(weapon)
    local hash = type(weapon) == 'number' and weapon or GetHashKey(tostring(weapon))
    local n = (weaponUsers[hash] or 0) - 1
    if n > 0 then weaponUsers[hash] = n return end
    weaponUsers[hash] = nil
    RemoveWeaponAsset(hash)
end

-- A SATELLITE CALLS THESE THROUGH Whip.call('LoadModel', ...) from a thread: they wait, and Whip.call
-- answers `false, 'whip_core stopped'` if whip_core restarts mid-wait instead of leaving the caller
-- hanging (lib/satellite.lua). whip_core's own files call the globals.
exports('LoadModel', LoadModel)
exports('LoadAnimDict', LoadAnimDict)
exports('LoadTextureDict', LoadTextureDict)
exports('LoadAnimSet', LoadAnimSet)
exports('LoadPtfxAsset', LoadPtfxAsset)
