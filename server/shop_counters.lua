-- ============================================
-- Shop counters — the shopkeeper, and the prompt at each shop
-- ============================================
--
-- A shop's keeper is one of whip's NPCs (server/npcs.lua,
-- the NPC Creator the Director's quest givers are), made here on the server, and a prompt rides it (a
-- runtime point, server/runtime_points.lua):
--
--   Browse          the shop's name: everyone
--   Manage Stock    a stocked shop's job managers only (its job's canManage): nobody else's game is
--                   even offered it, and the press is checked again here
--
-- A shop with a prop instead of a keeper keeps its prop (each game makes that: client/shops.lua) and
-- gets the same prompt over it. A shop with neither has no counter, and no prompt.
--
-- Pressing runs on the server: the point has checked the reach and the option's require, and
-- Shops.openFor / Shops.openStockFor (server/events_misc.lua) check again.
--
-- Each counter is filed under a tag of its own (shop:<id>:<n>): releasing it takes the keeper and the
-- prompt together. A shop changed where it stands or who keeps it gets a new counter; changed only in
-- name, mode or job, its prompt is changed in place (no keeper popping out and back).

local CORE = GetCurrentResourceName()
local SCENARIO = 'WORLD_HUMAN_STAND_IMPATIENT'   -- what the keeper does behind the counter
local PROP_LIFT = 1.0                             -- a prop shop's prompt, this far above its spot
local counters = {}   -- [shopId] = { tag, sig, npcId, netId, pointId }
local serial = 0

--- What a counter is made from: change any of it and a new one is made.
local function sigOf(def)
    return ('%s|%s|%.2f|%.2f|%.2f|%.1f'):format(tostring(def.npcModel), tostring(def.prop),
        tonumber(def.x) or 0, tonumber(def.y) or 0, tonumber(def.z) or 0, tonumber(def.heading) or 0)
end

--- The prompt's options: Browse, and Manage Stock for a stocked shop whose job is known. Browse is the
--- dollar sign (the holdall is the inventory's).
local function optionsOf(def)
    local list = { { id = 'browse', label = def.name or 'Browse', icon = 'dollar' } }
    if def.mode == 'stocked' and def.jobId then
        local job = Jobs.get(def.jobId)
        if job and job.key then
            list[#list + 1] = { id = 'stock', label = 'Manage Stock', icon = 'store',
                                require = { job = job.key, jobPermission = 'canManage' } }
        end
    end
    return list
end

--- A press of the prompt: the shop, or its stock.
local function useFor(shopId)
    return function(source, use)
        local player = Players[source]
        if not player then return false, 'Not loaded' end
        if use.option == 'stock' then return Shops.openStockFor(source, player, shopId) end
        return Shops.openFor(source, player, shopId)
    end
end

--- Take a shop's counter away: its keeper and its prompt.
---@param shopId number
function Shops.closeCounter(shopId)
    local c = counters[shopId]
    if not c then return end
    counters[shopId] = nil
    Registry.releaseTag(CORE, c.tag)
end

--- Make (or bring up to date) a shop's counter. Never waits.
---@param def table  the shop's definition (Shops.getDef)
function Shops.openCounter(def)
    if type(def) ~= 'table' or not def.shopId then return end
    local shopId = def.shopId
    if def.settings and def.settings.virtual then
        Shops.closeCounter(shopId)
        return
    end
    -- Nothing to stand behind, or nowhere to stand: no counter.
    if not (def.npcModel or def.prop) or not (def.x and def.y and def.z) then
        Shops.closeCounter(shopId)
        return
    end
    local sig = sigOf(def)
    local c = counters[shopId]
    if c and c.sig == sig then
        local ok, why = RuntimePoints.update(CORE, c.pointId, { label = def.name or 'Shop', options = optionsOf(def) })
        if not ok then print(('[whip_core:shops] shop #%d: its prompt could not be changed: %s'):format(shopId, tostring(why))) end
        return
    end
    Shops.closeCounter(shopId)

    serial = serial + 1
    c = { tag = ('shop:%d:%d'):format(shopId, serial), sig = sig }
    counters[shopId] = c

    local at
    if def.npcModel then
        local npcId, netId = Npcs.spawn(CORE, {
            model = def.npcModel,
            coords = { x = def.x, y = def.y, z = def.z, heading = def.heading or 0.0 },
            behaviour = 'stand',
            conditions = { invincible = true, canMove = false, reacts = false, flees = false },
        }, { tag = c.tag, fightBack = false })
        if npcId then
            c.npcId, c.netId = npcId, netId
            Npcs.setState(CORE, npcId, { anim = { scenario = SCENARIO } })
            at = { netId = netId, offset = vector3(0.0, 0.0, 0.3) }
        else
            -- No keeper (a model this game does not have): the prompt still stands where they would.
            print(('[whip_core:shops] shop #%d: its keeper (%s) could not be made: %s'):format(shopId, tostring(def.npcModel), tostring(netId)))
        end
    end
    at = at or { coords = vector3(def.x + 0.0, def.y + 0.0, def.z + PROP_LIFT) }

    local pointId, why = RuntimePoints.add(CORE, {
        at = at, label = def.name or 'Shop', icon = 'dollar', options = optionsOf(def),
        reach = Config.ShopInteractRange or 2.5, tag = c.tag, onUse = useFor(shopId),
    })
    if not pointId then
        print(('[whip_core:shops] shop #%d: its prompt could not be made: %s'):format(shopId, tostring(why)))
        return
    end
    c.pointId = pointId
end

--- A shop's keeper, as Bubbles.show takes a ped: its network id, or nil (a prop shop, a shop with
--- no counter, a keeper that could not be made). For the keeper's answers (server/shop_talk.lua).
---@param shopId number
---@return number|nil netId
function Shops.keeperOf(shopId)
    local c = counters[shopId]
    return c and c.netId or nil
end

--- Every shop's counter, at start-up (player_lifecycle.lua, after the shops load).
function Shops.openCounters()
    for _, def in ipairs(Shops.getAll()) do Shops.openCounter(def) end
end

-- The interaction reach changed in /whip Config: every prompt takes the new one.
Settings.onChange('ShopInteractRange', function()
    for _, c in pairs(counters) do
        if c.pointId then RuntimePoints.update(CORE, c.pointId, { reach = Config.ShopInteractRange or 2.5 }) end
    end
end)
