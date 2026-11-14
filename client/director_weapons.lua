-- ============================================
-- Director — Fixed Weapons, this game's half: where a gun points, and firing it
-- ============================================
--
-- A FIXED WEAPON is a prop of a run's set made as its gun's world model (client/prop_sets.lua, shared/
-- gta_weapon_models.lua). Its BARREL is read from the object itself: its muzzle (the model's gun_muzzle bone, or the
-- far end of its longest side), and the way it points along that side. The world builder's aim line
-- (client/furnish_builder.lua) and the shot both use it, so where the line runs is where the shot goes.
--
-- FIRE (the Fire Weapon card, server/director/nodes_weapons.lua): one game fires, so there is one rocket, not one per
-- player: a real shot from the muzzle (ShootSingleBulletBetweenCoordsIgnoreEntity), heard by everyone and hurting
-- whoever is in the way, to the placed thing it is fired at, or straight on along its barrel. AIM: every game that has
-- the gun turns its own copy to face what it is fired at first (one attached rides on its parent, and is not turned).

DirectorWeapons = {}

local RANGE = 250.0       -- "where it points": the shot goes this far along the barrel
local SWING_MS = 350
local AIM_LEAD_MS = 400   -- the gun turns to its target before the first shot

--- The gun's muzzle and the way its barrel points (a unit vector), from its object; and its barrel's side in the
--- model ('x' or 'y') and which way along it (1 or -1), for turning it.
function DirectorWeapons.barrel(obj)
    local origin = GetEntityCoords(obj)
    local mn, mx = GetModelDimensions(GetEntityModel(obj))
    local axis = (mx.x - mn.x) >= (mx.y - mn.y) and 'x' or 'y'
    local muzzle
    local b = GetEntityBoneIndexByName(obj, 'gun_muzzle')
    if b and b ~= -1 then muzzle = GetWorldPositionOfEntityBone(obj, b) end
    local sign = 1
    if muzzle then
        local l = GetOffsetFromEntityGivenWorldCoords(obj, muzzle.x, muzzle.y, muzzle.z)
        sign = ((axis == 'x' and l.x or l.y) < 0) and -1 or 1
    else
        muzzle = axis == 'x' and GetOffsetFromEntityInWorldCoords(obj, mx.x, 0.0, 0.0) or GetOffsetFromEntityInWorldCoords(obj, 0.0, mx.y, 0.0)
    end
    local ahead = axis == 'x' and GetOffsetFromEntityInWorldCoords(obj, sign * 1.0, 0.0, 0.0)
        or GetOffsetFromEntityInWorldCoords(obj, 0.0, sign * 1.0, 0.0)
    local d = ahead - origin
    local len = #d
    if len < 0.001 then return muzzle, GetEntityForwardVector(obj), axis, sign end
    return muzzle, d / len, axis, sign
end

--- Where the barrel's line first hits something, within `range` (the builder's aim line): the point, and whether it hit.
function DirectorWeapons.aimHit(obj, range)
    local m, d = DirectorWeapons.barrel(obj)
    local to = m + d * (range or RANGE)
    local ray = StartExpensiveSynchronousShapeTestLosProbe(m.x, m.y, m.z, to.x, to.y, to.z, -1, obj, 7)
    local _, hit, at = GetShapeTestResult(ray)
    if hit == 1 or hit == true then return m, at, true end
    return m, to, false
end

--- What it is fired at, now: a networked thing where it stands (a little above its feet), or a point.
local function targetOf(at)
    if type(at) ~= 'table' then return nil end
    local e = DirectorKit.entityOfNet(at.net)
    if e then
        local c = GetEntityCoords(e)
        return vector3(c.x, c.y, c.z + (IsEntityAPed(e) and 0.3 or 0.5))
    end
    if tonumber(at.x) and tonumber(at.y) and tonumber(at.z) then return vector3(at.x + 0.0, at.y + 0.0, at.z + 0.0) end
    return nil
end

local function headingOf(v) return math.deg(math.atan(-v.x, v.y)) end
local function pitchOf(v) return math.deg(math.atan(v.z, math.sqrt(v.x * v.x + v.y * v.y))) end
local function wrap(a) return (a + 180.0) % 360.0 - 180.0 end

--- Turn this game's copy so its barrel points at `t`, over SWING_MS: its heading, and its tilt along the barrel's side.
local function swing(obj, t)
    local m, d, axis, sign = DirectorWeapons.barrel(obj)
    local want = t - m
    if #want < 0.1 then return end
    local dh = wrap(headingOf(want) - headingOf(d))
    local dp = pitchOf(want) - pitchOf(d)
    local from = GetEntityRotation(obj, 2)
    local to = vector3(from.x, from.y, from.z + dh)
    if axis == 'y' then to = vector3(from.x + dp * sign, from.y, to.z) else to = vector3(from.x, from.y - dp * sign, to.z) end
    CreateThread(function()
        local start = GetGameTimer()
        while DoesEntityExist(obj) do
            local f = math.min(1.0, (GetGameTimer() - start) / SWING_MS)
            local e = f * f * (3.0 - 2.0 * f)
            SetEntityRotation(obj, from.x + (to.x - from.x) * e, from.y + (to.y - from.y) * e, from.z + (to.z - from.z) * e, 2, false)
            if f >= 1.0 then break end
            Wait(0)
        end
    end)
end

RegisterNetEvent('whip_core:client:directorAim', function(a)
    if type(a) ~= 'table' then return end
    local obj, p = PropSets.pieceOf(a.wire, a.i)
    if not obj or (p and p.att) then return end
    local t = targetOf(a.at)
    if t then swing(obj, t) end
end)

--- The shots of a gun whose asset is loaded: answers true, or false and why.
local function shoot(f, obj, hash)
    local dmg = math.floor(tonumber(GetWeaponDamage(hash, 0)) or 0)
    if dmg <= 0 then dmg = 50 end
    if f.at then Wait(AIM_LEAD_MS) end
    local shots = math.max(1, math.min(20, math.tointeger(tonumber(f.shots)) or 1))
    local gap = math.max(50, math.min(5000, math.tointeger(tonumber(f.gapMs)) or 500))
    for n = 1, shots do
        if not DoesEntityExist(obj) then return false, 'the gun went' end
        local m, d = DirectorWeapons.barrel(obj)
        local t = targetOf(f.at) or (m + d * RANGE)
        ---@diagnostic disable-next-line: redundant-parameter -- p14, NativeDB's 15th: not in the natives' docs
        ShootSingleBulletBetweenCoordsIgnoreEntity(m.x, m.y, m.z, t.x, t.y, t.z, dmg, true, hash, 0, true, false, -1.0, obj, false)
        if n < shots then Wait(gap) end
    end
    return true
end

--- Its shots, from its muzzle: answers true, or false and why. The gun's asset is held for the burst, counted
--- (LoadWeaponAsset): another Fire Weapon of the same gun keeps it loaded till its own burst is over.
local function fire(f)
    local obj = PropSets.pieceOf(f.wire, f.i)
    if not obj then return false, 'the gun is not made on this game (out of range?)' end
    local hash = GetHashKey(f.weapon)
    local loaded = LoadWeaponAsset(hash, 4000)
    local ok, done, why = pcall(function()
        if not loaded then return false, ('%s would not load'):format(tostring(f.weapon)) end
        return shoot(f, obj, hash)
    end)
    ReleaseWeaponAsset(hash)
    if not ok then error(done, 0) end
    return done, why
end

--- Fire a gun this game has now, from here (Dungeon Mode's Fire: client/director_live.lua): `f` { wire, i, weapon,
--- shots, gapMs, at }. In a thread; `done(ok, why)` once it is over.
function DirectorWeapons.fireNow(f, done)
    CreateThread(function()
        local ok, fired, why = pcall(fire, f)
        if not ok then fired, why = false, tostring(fired) end
        if done then done(fired == true, why) end
    end)
end

RegisterNetEvent('whip_core:client:directorFire', function(f)
    if type(f) ~= 'table' or type(f.weapon) ~= 'string' then return end
    CreateThread(function()
        local ok, done, why = pcall(fire, f)
        if not ok then done, why = false, tostring(done) end
        TriggerServerEvent('whip_core:server:directorFired', tostring(f.token), done == true, why and DirectorKit.cut(tostring(why), 120) or '')
    end)
end)
