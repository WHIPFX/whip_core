-- ============================================
-- PED HOLDS — the player ped's invincible / frozen / hidden / no-collision
-- ============================================
--
-- THE ONE PLACE whip_core's client sets these four on the PLAYER's ped. Whatever wants one holds it
-- under its own id; the ped gets the union of every hold:
--
--     PedHold.set('freecam', { hidden = true, frozen = true, noCollision = true, invincible = true })
--     PedHold.release('freecam')
--     PedHold.set('death', { invincible = true })          -- a hold's flags can change (escort drop)
--
-- WHY. Ten-odd files set them on and off themselves, so one switching a flag off cancelled every other
-- reason it was on: freecam's exit thawed a downed player, a no-PvP zone's exit made a downed player
-- hurtable, death's revive showed an /w Invisible admin. Each owner guarded the others by hand
-- (`not PlayerIsDead` in emotes.lua, zones.lua's fall damage, the God Mode exit) and missed some.
--
-- INVINCIBLE is the entity's and the player's (SetEntityInvincible + SetPlayerInvincible), as death and
-- God Mode set them. HIDDEN is SetEntityVisible (networked: other players do not see the ped).
--
-- A NEW PED starts with none of them: after NetworkResurrectLocalPlayer or SetPlayerModel, call
-- PedHold.reapply(). Only what changes is written otherwise, so a file not moved here yet (emotes.lua's
-- placing freeze, the furnisher) is not stomped by a hold that never touched its flag.
--
-- AND WHAT EVERY PLAYER PED CARRIES (pedSettings below): put on each new ped at those same moments, since
-- this is where whip_core knows the player has one.

PedHold = {}

--- WHAT EVERY PLAYER PED CARRIES, whatever is held: written on each new ped (see apply), and the helmet again
--- when its setting changes.
---
--- A helmet on a bike: GTA puts one on a character as they get onto a motorbike — ped config
--- flag 35, PutOnMotorcycleHelmet — over whatever they wear on their head. Config.BikeAutoHelmet = false (the
--- default) turns that off, so they ride in what they have on; true gives GTA's helmet back.
---
--- And what a death took away: a death resurrects the player twice (client/death.lua: where they
--- fall, and again at the hospital), and each resurrect can hand back a NEW ped that has none of what was
--- set on the old one. These were set only at the first spawn or load, so they were gone from then on:
---   * flag 48, BlockWeaponSwitching — GTA's weapon wheel and scroll switching stay dead (whip draws
---     weapons from the inventory). Give mode turns it off for the ball and back on (client/inventory.lua):
---     left off while that runs.
---   * SetCanAttackFriendly — player-on-player damage (client/spawn.lua turns friendly fire on).
---   * GTA's health regen off: a resurrect gives it back (DoRespawn turned it off again; a revive did not).
local HELMET_FLAG      = 35
local WEAPON_LOCK_FLAG = 48
local function pedSettings(ped)
    SetPedConfigFlag(ped, HELMET_FLAG, Config.BikeAutoHelmet == true)
    if not (Inventory.isGiveModeActive and Inventory.isGiveModeActive()) then SetPedConfigFlag(ped, WEAPON_LOCK_FLAG, true) end
    SetCanAttackFriendly(ped, true, true)
    SetPlayerHealthRechargeMultiplier(PlayerId(), 0.0)
    SetPlayerHealthRechargeLimit(PlayerId(), 0.0)
end

local FLAGS = { 'invincible', 'frozen', 'hidden', 'noCollision' }

local holds   = {}    -- [id] = { invincible, frozen, hidden, noCollision }
local applied = { invincible = false, frozen = false, hidden = false, noCollision = false }
local appliedPed = 0

local function wanted()
    local w = { invincible = false, frozen = false, hidden = false, noCollision = false }
    for _, h in pairs(holds) do
        for i = 1, #FLAGS do
            local f = FLAGS[i]
            if h[f] then w[f] = true end
        end
    end
    return w
end

local WRITE = {
    invincible  = function(ped, on) SetEntityInvincible(ped, on); SetPlayerInvincible(PlayerId(), on) end,
    frozen      = function(ped, on) FreezeEntityPosition(ped, on) end,
    hidden      = function(ped, on) SetEntityVisible(ped, not on, false) end,
    noCollision = function(ped, on) SetEntityCollision(ped, not on, not on) end,
}

--- Write what changed — everything that is held, on a new ped (`force`).
local function apply(force)
    local ped = PlayerPedId()
    if ped == 0 then return end
    local w = wanted()
    local newPed = ped ~= appliedPed
    for i = 1, #FLAGS do
        local f = FLAGS[i]
        if w[f] ~= applied[f] or ((force or newPed) and w[f]) then WRITE[f](ped, w[f]) end
    end
    if force or newPed then pedSettings(ped) end
    applied, appliedPed = w, ped
end

--- Hold flags under `id`, or change the ones it holds. `flags = nil` lets go.
---@param id string
---@param flags table|nil  { invincible?, frozen?, hidden?, noCollision? }
function PedHold.set(id, flags)
    if flags == nil then
        if holds[id] == nil then return end
        holds[id] = nil
    else
        local h = {}
        for i = 1, #FLAGS do h[FLAGS[i]] = flags[FLAGS[i]] == true end
        holds[id] = h
    end
    apply(false)
end

---@param id string
function PedHold.release(id)
    PedHold.set(id, nil)
end

---@param id string
---@return boolean
function PedHold.held(id)
    return holds[id] ~= nil
end

--- Does any hold want this flag?
---@param flag 'invincible'|'frozen'|'hidden'|'noCollision'
---@return boolean
function PedHold.wants(flag)
    return wanted()[flag] == true
end

--- The player has a NEW PED (NetworkResurrectLocalPlayer, SetPlayerModel): everything held goes on it.
function PedHold.reapply()
    apply(true)
end

-- ---- for satellites (whip_rope's hanging) ----------------------------------------------------------
-- The same holds for another resource, keyed '<resource>:<id>' and let go when it stops — so a satellite
-- that hides the player never shows an /w Invisible admin, or thaws a downed one, on its way out.
local satHolds = Registry.new('pedHolds', {
    label  = 'ped hold',
    scoped = true,
    onAdd    = function(key, value) PedHold.set('sat:' .. key, value) end,
    onRemove = function(key) PedHold.release('sat:' .. key) end,
})

--- Hold the player's own ped invincible / frozen / hidden / without collision until ReleasePlayerPed(id),
--- or until your resource stops. The same id again changes what it holds.
---@param id string|number
---@param flags { invincible?: boolean, frozen?: boolean, hidden?: boolean, noCollision?: boolean }
---@return boolean ok
---@return string|nil why
exports('HoldPlayerPed', function(id, flags)
    local owner = Registry.caller()
    if type(flags) ~= 'table' then return false, 'flags is a table: { invincible, frozen, hidden, noCollision }' end
    local h = {}
    for i = 1, #FLAGS do h[FLAGS[i]] = flags[FLAGS[i]] == true end
    local ok, why = satHolds:add(owner, id, h)
    if not ok then return false, why --[[@as string]] end   -- a refusal's reason
    return true
end)

--- Let go of one of your holds. Answers true when it was not held, too.
---@param id string|number
---@return boolean ok
---@return string|nil why
exports('ReleasePlayerPed', function(id)
    local owner = Registry.caller()
    if (type(id) ~= 'string' and type(id) ~= 'number') or satHolds:get(satHolds:keyOf(owner, id)) == nil then
        return true
    end
    return satHolds:remove(owner, id)
end)

-- The ped the player already has when whip_core starts (a restart mid-session: no new ped comes), and the
-- setting changed in /whip → Settings: written now, not at the next spawn.
CreateThread(function() pedSettings(PlayerPedId()) end)
Settings.onChange('BikeAutoHelmet', function()
    local ped = PlayerPedId()
    if ped ~= 0 then pedSettings(ped) end
end)

-- whip_core going away: nothing it held may outlive it.
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    holds = {}
    apply(false)
end)
