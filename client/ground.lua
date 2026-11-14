-- ============================================
-- GROUND ITEMS — Client Module
-- 3D prop streaming + NUI callbacks for ground ops
-- ============================================

local groundItemsData = {}   -- [id] = { id, item, amount, metadata, x, y, z, heading }
local groundItemProps = {}   -- [id] = entity handle (spawned prop)

-- ============================================
-- Client Spatial Grid (mirrors server grid for items we know about)
-- ============================================

local clientGrid      = {}   -- [cellKey] = { [id] = true }
local clientItemCells = {}   -- [id] = cellKey
local CLIENT_CELL_SIZE = nil

local function getClientCellSize()
    if not CLIENT_CELL_SIZE then CLIENT_CELL_SIZE = Config.GroundItemCellSize or 50 end
    return CLIENT_CELL_SIZE
end

local function clientCellKey(x, y)
    local cs = getClientCellSize()
    return math.floor(x / cs) .. '_' .. math.floor(y / cs)
end

local function clientGridInsert(id, x, y)
    local key = clientCellKey(x, y)
    if not clientGrid[key] then clientGrid[key] = {} end
    clientGrid[key][id] = true
    clientItemCells[id] = key
end

local function clientGridRemove(id)
    local key = clientItemCells[id]
    if key and clientGrid[key] then
        clientGrid[key][id] = nil
        if not next(clientGrid[key]) then clientGrid[key] = nil end
    end
    clientItemCells[id] = nil
end

local function clientGetNearbyCellKeys(x, y, range)
    local cs = getClientCellSize()
    local radius = math.ceil(range / cs)
    local cx = math.floor(x / cs)
    local cy = math.floor(y / cs)
    local keys = {}
    for dx = -radius, radius do
        for dy = -radius, radius do
            keys[(cx + dx) .. '_' .. (cy + dy)] = true
        end
    end
    return keys
end

-- ============================================
-- The grab (Josh, 2 Nov): Rockstar's generic grab, as a pile is picked up
-- ============================================
--
-- Picking a pile up from its prompt plays Rockstar's own grab (the Drug Wars pack's gen_grab, in every game build
-- from 2802), not the hand press. Like the press it plays WHERE THE PLAYER STANDS (no walk, no turn: a pile further
-- off is grabbed at the air, as Rockstar's own pick ups are) and the pick up is not held for it: the server is asked
-- on E. The pile's prop stays on the ground until the hand closes on it (each clip's grab moment, below), then goes
-- (`grabbing`, DespawnGroundProp).
--
-- WHICH ONE (3D Clanker measured them, 2 Nov): its height by the pile's height above the player's feet (low below
-- 0.65 m, high above 1.6 m, else med); the right hand, or the left when the pile is more than 30 degrees to the
-- left; both hands when the item says so (its `grab` setting, '2h', on its /whip Items page; one hand by default).
-- high and med are upper body with the player in control; low bends the knees, so it is full body: it plays until the
-- hand has closed on the pile, even for a player who is moving or pushing the stick (Josh: a pick up on the move was
-- cut before it showed), and from then on moving lets them go. Women play the @heeled@ set (the only female one; 9 cm higher at the hips: in
-- flat shoes her feet may float during it).

local GRAB_DICT = {
    male   = 'anim@scripted@player@freemode@gen_grab@male@',
    heeled = 'anim@scripted@player@freemode@gen_grab@heeled@',
}
local GRAB_MS = 2000
local FEET_BELOW = 1.0                         -- a ped's feet below GetEntityCoords
local GRAB_LOW_BELOW, GRAB_HIGH_ABOVE = 0.65, 1.6
local GRAB_LEFT = -math.rad(30)
-- When the hand closes on it (each clip's own grab tag, which plays Rockstar's grab sound by itself), ms.
local GRAB_CLOSE = {
    high_rh = 612, high_lh = 654, high_2h = 522,
    med_rh  = 516, med_lh  = 594, med_2h  = 740,
    low_rh  = 694, low_lh  = 454, low_2h  = 720,
}
-- When it may end early (low: the hips back up; med_rh: the arm back at the side); the rest run their 2 s.
local GRAB_DONE = { low_rh = 1133, low_lh = 1100, low_2h = 1233, med_rh = 1066 }
local GRAB_STICK = 0.35

--- [id] = the game time the hand closes on that pile: its prop stays until then (DespawnGroundProp).
local grabbing = {}

-- The player's own set kept loaded (88 KB): a grab must start on the frame E is pressed, or the pile would leave before
-- the hand reaches it. Only theirs: another player's grab reaches this game as their own task. Looked at again every
-- few seconds, for a new character or model.
CreateThread(function()
    while true do
        local want = GetEntityModel(PlayerPedId()) == `mp_f_freemode_01` and GRAB_DICT.heeled or GRAB_DICT.male
        for _, dict in pairs(GRAB_DICT) do
            if dict == want then
                if not HasAnimDictLoaded(dict) then RequestAnimDict(dict) end
            elseif HasAnimDictLoaded(dict) then
                RemoveAnimDict(dict)
            end
        end
        Wait(5000)
    end
end)

-- ---- Behind low cover (Josh, 3 Nov; 3D Clanker's whip@interact@grab_lowcover) ----
--
-- Crouched behind low cover, gen_grab's poses stand the body up, so those pickups have their own set. Each clip starts
-- and ends on Rockstar's own low cover pose for its state (facing left or right, unarmed or with a one- or two-handed
-- weapon), and only the upper body plays it (48), so the player stays in cover. The spine leans towards the item, the
-- hand lands palm down on it, and it comes back. Unarmed, either hand; with a weapon, the left hand only (the gun
-- stays where the cover pose holds it). data/interact_grab_lowcover.json says where each palm goes, in the ped's
-- frame (+x right, +y ahead, z up, from GetEntityCoords):
--
--   { "dict": "whip@interact@grab_lowcover", "fps": 30,
--     "clips": [ { "clip": "unarmed_l_floor_l_m090", "weapon": "unarmed" | "1h" | "2h", "facing": "left" | "right",
--                  "band": "floor" | "raised", "arm": "left", "grab": [x, y, z], "shoulder": [x, y, z], "effort": 0.5,
--                  "grab_ms": 567, "back_ms": 867, "duration_ms": 1233, "reach_path": [[x, y, z], ...] }, ... ] }
--
-- The band goes by the item's height (Clanker, 3 Nov): under LOWCOVER_FLOOR_BELOW above the feet, floor clips only;
-- higher, raised clips only (a raised clip would close its hand 25-45 cm above a floor item). Among that band's rows
-- the clip is picked by the press's own rules (InteractPress.choose, with no surface): the aim at the clip's shoulder
-- plus its effort, judged at the grab itself, where the hand really lands. None within LOWCOVER_MAX_ERR degrees (a
-- rifle's left hand reaching right across the body, or a floor item far behind): no animation, and the item is still
-- picked up. The hand closes at grab_ms and is back on the cover pose by back_ms, where the clip stops. Leaving cover
-- or aiming stops it at once.

-- OFF for now (Josh, 3 Nov): crouched behind low cover, gen_grab's med or high plays again, as before this set.
-- true turns this set back on.
local LOWCOVER_GRABS = false
local LOWCOVER_FILE = 'data/interact_grab_lowcover.json'
local LOWCOVER_MAX_ERR = 40.0
local LOWCOVER_FLOOR_BELOW = 0.30   -- m above the feet: lower = a floor item
local LOWCOVER_ARMS = { left = true, right = true }
local LOWCOVER_WEAPON = { [0] = 'unarmed', [1] = '1h', [2] = '2h' }   -- by InteractPress.hands
local lowCoverSet = nil   -- the list, read once; false once found missing or unreadable

local function xyz(t)
    if type(t) ~= 'table' then return nil end
    local x, y, z = tonumber(t[1]), tonumber(t[2]), tonumber(t[3])
    return x and y and z and { x, y, z } or nil
end

--- The low-cover set: { dict, states = { ['unarmed/left/floor'] = { rows }, ... } }, or nil when not installed.
local function lowCover()
    if lowCoverSet ~= nil then return lowCoverSet or nil end
    lowCoverSet = false
    local raw = LoadResourceFile(GetCurrentResourceName(), LOWCOVER_FILE)
    if not raw or raw == '' then return nil end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= 'table' or type(data.dict) ~= 'string' or type(data.clips) ~= 'table' then
        print(('[whip_core:ground] %s could not be read: no grabs behind low cover'):format(LOWCOVER_FILE))
        return nil
    end
    local states, n = {}, 0
    for i, c in ipairs(data.clips) do
        local path = type(c) == 'table' and type(c.reach_path) == 'table' and #c.reach_path > 2 and {} or nil
        for _, p in ipairs(path and c.reach_path or {}) do
            local v = xyz(p)
            if not v then path = nil break end
            path[#path + 1] = v
        end
        local sh = path and xyz(c.shoulder)
        local grabMs, durationMs = path and tonumber(c.grab_ms), path and tonumber(c.duration_ms)
        if sh and grabMs and durationMs and type(c.clip) == 'string' and type(c.weapon) == 'string'
            and (c.facing == 'left' or c.facing == 'right') and (c.band == 'floor' or c.band == 'raised') then
            local key = c.weapon .. '/' .. c.facing .. '/' .. c.band
            states[key] = states[key] or {}
            states[key][#states[key] + 1] = {
                clip = c.clip, arm = c.arm == 'left' and 'left' or 'right', path = path, shoulder = sh,
                effort = tonumber(c.effort) or 0.0,
                grabMs = grabMs, backMs = tonumber(c.back_ms) or durationMs, durationMs = durationMs,
            }
            n = n + 1
        else
            print(('[whip_core:ground] %s: clip %d is missing a field: left out'):format(LOWCOVER_FILE, i))
        end
    end
    if n == 0 then return nil end
    lowCoverSet = { dict = data.dict, states = states }
    return lowCoverSet
end

-- Kept loaded only while the player is in cover (130 KB), so a grab starts on the frame E is pressed.
CreateThread(function()
    if not LOWCOVER_GRABS then return end
    while true do
        local s = lowCover()
        if not s then return end
        local inCover = IsPedInCover(PlayerPedId(), false)
        if inCover and not HasAnimDictLoaded(s.dict) then
            RequestAnimDict(s.dict)
        elseif not inCover and HasAnimDictLoaded(s.dict) then
            RemoveAnimDict(s.dict)
        end
        Wait(500)
    end
end)

--- The grab towards T crouched behind low cover: the ms until the hand closes and until it is done, or nil (none).
---@param ped number
---@param T vector3
---@return number|nil closeMs
---@return number|nil doneMs
local function PlayLowCoverGrab(ped, T)
    local s = lowCover()
    if not s or not DoesAnimDictExist(s.dict) then return nil end
    local o = GetOffsetFromEntityGivenWorldCoords(ped, T.x, T.y, T.z)
    local band = o.z + FEET_BELOW < LOWCOVER_FLOOR_BELOW and 'floor' or 'raised'
    local key = LOWCOVER_WEAPON[InteractPress.hands(ped)] .. '/' .. (IsPedInCoverFacingLeft(ped) and 'left' or 'right')
        .. '/' .. band
    local rows = s.states[key]
    if not rows then return nil end
    local c = InteractPress.choose(rows, { o.x, o.y, o.z }, nil, LOWCOVER_ARMS, LOWCOVER_MAX_ERR, true)
    if not c then return nil end
    local dict = s.dict
    CreateThread(function()
        if not HasAnimDictLoaded(dict) and not LoadAnimDict(dict, 500) then return end
        TaskPlayAnim(ped, dict, c.clip, 8.0, 4.0, c.durationMs, 48, 0.0, false, false, false)
        local t0 = GetGameTimer()
        Wait(0)
        while IsEntityPlayingAnim(ped, dict, c.clip, 3) and GetGameTimer() - t0 < c.backMs do
            if not IsPedInCover(ped, false) or InteractPress.aiming(ped) then break end
            Wait(0)
        end
        if IsEntityPlayingAnim(ped, dict, c.clip, 3) then StopAnimTask(ped, dict, c.clip, 4.0) end
    end)
    return c.grabMs, c.grabMs + 100
end

local function grabWantsToMove()
    return math.abs(GetControlNormal(0, 30)) > GRAB_STICK or math.abs(GetControlNormal(0, 31)) > GRAB_STICK
        or IsControlPressed(0, 22) or IsControlPressed(0, 24) or IsControlPressed(0, 25)
end

--- Grab towards T (a pile) from where the player stands. Answers at once (it plays in its own thread) with the ms
--- until the hand closes and the ms until the grab is done with the body (the hips back up, or the hand closed for a
--- standing one: what follows may take the upper body then), or nil when none plays (seated, falling, dead, aiming:
--- InteractPress.aiming, Josh: no grab while aiming, it is just picked up).
---
--- IN COVER (Josh, 2 Nov): one hand, the upper body only (48, a secondary task): a full-body one, or any task that is
--- not a secondary one, takes the player out of cover. Standing behind high cover: low, med or high by the height, as
--- out of it. Crouched behind low cover: med or high only (crouched, the med reaches what is low), unless
--- LOWCOVER_GRABS turns on its own set (PlayLowCoverGrab, above).
---@param T vector3
---@param item string|nil
---@return number|nil closeMs
---@return number|nil doneMs
local function PlayGrab(T, item)
    local ped = PlayerPedId()
    if IsEntityDead(ped) or IsPedInAnyVehicle(ped, true) or IsPedRagdoll(ped) or IsPedFalling(ped)
        or IsPedSwimming(ped) or InteractPress.aiming(ped) then return nil end
    local inCover = IsPedInCover(ped, false)
    if LOWCOVER_GRABS and inCover and not IsPedInHighCover(ped) then return PlayLowCoverGrab(ped, T) end
    local P = GetEntityCoords(ped)
    local up = T.z - (P.z - FEET_BELOW)
    local band = up < GRAB_LOW_BELOW and 'low' or (up > GRAB_HIGH_ABOVE and 'high' or 'med')
    if inCover and band == 'low' and not IsPedInHighCover(ped) then band = 'med' end
    local def = item and Config.Items[item]
    local hand = 'rh'
    if def and def.grab == '2h' and not inCover then
        hand = '2h'
    else
        local r = math.rad(GetEntityHeading(ped))
        local dx, dy = T.x - P.x, T.y - P.y
        local lx, ly = dx * math.cos(r) + dy * math.sin(r), -dx * math.sin(r) + dy * math.cos(r)
        if math.atan(lx, ly) < GRAB_LEFT then hand = 'lh' end
    end
    local clip = band .. '_' .. hand
    local dict = GetEntityModel(ped) == `mp_f_freemode_01` and GRAB_DICT.heeled or GRAB_DICT.male
    -- Full body (the knees bend) only out of cover; in cover even a low grab is the upper body's.
    local low = band == 'low' and not inCover

    CreateThread(function()
        if not HasAnimDictLoaded(dict) and not LoadAnimDict(dict, 500) then return end
        TaskPlayAnim(ped, dict, clip, 8.0, 4.0, GRAB_MS, low and 0 or 48, 0.0, false, false, false)
        local t0 = GetGameTimer()
        local doneAt = GRAB_DONE[clip] or GRAB_MS
        local closedAt = GRAB_CLOSE[clip] or 0   -- a low grab is not let go before the hand has the pile
        Wait(0)
        while IsEntityPlayingAnim(ped, dict, clip, 3) and GetGameTimer() - t0 < doneAt do
            if low and GetGameTimer() - t0 >= closedAt and grabWantsToMove() then
                StopAnimTask(ped, dict, clip, 4.0)
                return
            end
            Wait(0)
        end
        if GRAB_DONE[clip] and IsEntityPlayingAnim(ped, dict, clip, 3) then StopAnimTask(ped, dict, clip, 4.0) end
    end)
    local closeMs = GRAB_CLOSE[clip]
    return closeMs, low and GRAB_DONE[clip] or (closeMs + 100)
end

-- ============================================
-- 3D Prop Spawning / Despawning
-- (defined first so event handlers below can reference them)
-- ============================================

-- Inventory.itemPropModel (client/inventory.lua) answers which prop an item uses, for the ground and
-- the hand alike.

-- ---- In sight ----
--
-- A pile is yours to take only if you can see it (not through a cell wall). Only a client can ask the
-- world (the server has no raycasts), so the panel, the prompt and the drag pickup ask here: a ray
-- from head height and one from knee height to
-- just above the pile. Either reaching it — or stopping within 0.3 m of it, on the floor or table it
-- lies on — is in sight. Walls, doors and glass stop both; cars do not (a pile beside a car is not
-- behind a wall). Ground props have no collision, so a pile never hides another.

local SIGHT_FLAGS = 1 | 16   -- the map (interiors included) and objects (doors); not vehicles or peds
local SIGHT_OPTIONS = 4      -- ignore no-collision only: glass blocks

local function rayReaches(fx, fy, fz, tx, ty, tz, ped)
    local ray = StartExpensiveSynchronousShapeTestLosProbe(fx, fy, fz, tx, ty, tz, SIGHT_FLAGS, ped, SIGHT_OPTIONS)
    local _, hit, at = GetShapeTestResult(ray)
    if hit ~= 1 then return true end
    local dx, dy, dz = at.x - tx, at.y - ty, at.z - tz
    return dx * dx + dy * dy + dz * dz <= 0.09
end

--- Can the player see a pile lying at x, y, z?
---@return boolean
local function inSight(x, y, z)
    local ped = PlayerPedId()
    if ped == 0 then return false end
    local p = GetEntityCoords(ped)   -- the pelvis, about 1 m up
    local tz = z + 0.2
    return rayReaches(p.x, p.y, p.z + 0.6, x, y, tz, ped) or rayReaches(p.x, p.y, p.z - 0.5, x, y, tz, ped)
end

--- [id] = { untilAt, yes }: an answer lasts 200 ms, so a prompt asking every frame casts at most
--- five pairs of rays a second.
local sightCache = {}

--- Is this known pile in sight? Where its prop (or flying object) is, rather than its stored z, which
--- can be half a metre up for an older drop. Unknown piles are not.
---@param id number
---@return boolean
local function pileInSight(id)
    local now = GetGameTimer()
    local c = sightCache[id]
    if c and now < c.untilAt then return c.yes end
    local data = groundItemsData[id]
    if not data then return false end
    local x, y, z = data.x, data.y, data.z
    local obj = groundItemProps[id]
    if (not obj or obj == 0) and data.flight and NetworkDoesNetworkIdExist(data.flight) then obj = NetToObj(data.flight) end
    if obj and obj ~= 0 and DoesEntityExist(obj) then
        local at = GetEntityCoords(obj)
        x, y, z = at.x, at.y, at.z
    end
    local yes = inSight(x, y, z)
    sightCache[id] = { untilAt = now + 200, yes = yes }
    return yes
end

--- The Nearby panel's slots, only the piles in sight, numbered again from 1. For the list the server
--- builds when the inventory opens (client/inventory.lua); its rows carry where each pile lies, for a
--- pile this client has not been sent yet.
---@param slots table  [ '1' ] = { item, amount, metadata, groundId, x, y, z }
---@return table
function GroundSlotsInSight(slots)
    local kept, n = {}, 0   -- a counter: # of a table keyed by strings is always 0
    for i = 1, 1000 do
        local s = slots[tostring(i)]
        if not s then break end
        local known = s.groundId and groundItemsData[s.groundId]
        local yes
        if known then yes = pileInSight(s.groundId)
        elseif s.x and s.y and s.z then yes = inSight(s.x, s.y, s.z)
        else yes = false end
        if yes then n = n + 1; kept[tostring(n)] = s end
    end
    return kept
end

--- The prompt a ground pile shows: what it is and how many, not what to do with it.
---
--- One copy, because a pile's count can change under its prompt (a split on the ground).
---@param data table  the ground row
---@return string
local function GroundPromptLabel(data)
    local def = Config.Items[data.item]
    local label = def and def.name or data.item
    if (data.amount or 1) > 1 then
        label = label .. ' x' .. data.amount
    end
    return label
end

--- [id] = true while the server is asked whether a pick up of that pile goes ahead (groundPickupRoom).
local askingRoom = {}

--- Pick a pile up from its prompt (Pick up, or a ground option's `action` after it), with the grab (PlayGrab).
---
--- The server is asked first: no grab for a pick up that takes nothing (pockets full, too heavy), only
--- the reason. It answers how many it takes, of how many: as many as fit, so a pile too big for the pockets is taken
--- in part and stays on the ground with the rest.
---
--- The pile's prop leaves the ground as the hand closes on it when the whole pile goes: kept till then when the server
--- is quicker, hidden then when it is not (and shown again if the pile is still there a few seconds on: the pick up
--- was refused after all). A pile taken in part keeps its prop.
---
--- Pick up asks the server at once. A ground option (Equip...) asks as the hand closes on it (Josh, 2 Nov: "straight to
--- equipped as soon as it's picked up"): the server runs it straight after the pick up, told it came from the ground
--- (Inventory.runContextAction's `how`), so gunny puts the gun in the hand with no draw animation of its own, which
--- would otherwise cut in over the grab.
---
--- Not the inventory screen's pick up (pickupGroundItem below): that is a screen.
---@param id number
---@param action string|nil
local function pickUpPile(id, action)
    -- Already asking, or already reaching for it: a second E is not a second pick up.
    if grabbing[id] or askingRoom[id] then return end
    askingRoom[id] = true
    CreateThread(function()
        local take, total = Callback('whip_core:server:groundPickupRoom', id, action or '')
        askingRoom[id] = nil
        if not take then
            UI.Notify(total or "Couldn't pick that up", 'error')
            return
        end

        local reg = Interactions.getAll()['ground_' .. id]   -- where it is now (a flying pile's is followed)
        local data = groundItemsData[id]
        local closeMs, doneMs
        if reg and reg.x then closeMs, doneMs = PlayGrab(vector3(reg.x, reg.y, reg.z), data and data.item) end
        local function ask() TriggerServerEvent('whip_core:server:quickPickupGroundItem', id, action) end
        if not closeMs then ask() return end

        grabbing[id] = GetGameTimer() + closeMs
        SetTimeout(math.max(closeMs, doneMs) + 250, function() grabbing[id] = nil end)
        if take >= total then
            SetTimeout(closeMs, function()
                local obj = groundItemProps[id]
                if not obj or not DoesEntityExist(obj) then return end
                SetEntityVisible(obj, false, false)
                SetTimeout(4000, function()
                    if groundItemProps[id] == obj and DoesEntityExist(obj) then SetEntityVisible(obj, true, false) end
                end)
            end)
        end
        if action then SetTimeout(closeMs, ask) else ask() end
    end)
end

--- The pile's ground options after Pick up (its item's groundOptions: server/item_options.lua, "GROUND OPTIONS"), as
--- the prompt's options, or nil when it has none. Pick up first, with the prompt's own label and arrow (so the label's
--- updates still reach it); each extra says what it does to what ("Equip Pump Shotgun"). Chosen, the server picks it
--- up as Pick up does and runs that option once it is in the pockets.
---@param data table  the ground row
---@return table|nil
local function groundPromptOptions(data)
    local def = Config.Items[data.item]
    local extras = def and def.groundOptions
    if type(extras) ~= 'table' or #extras == 0 then return nil end
    local opts = { { id = 'pickup' } }
    for _, g in ipairs(extras) do
        if type(g) == 'table' and type(g.action) == 'string' and type(g.label) == 'string' then
            local action = g.action
            opts[#opts + 1] = {
                id       = 'ground:' .. action,
                label    = ('%s %s'):format(g.label, def.name or data.item),
                icon     = type(g.icon) == 'string' and g.icon or 'pickup',
                callback = function() pickUpPile(data.id, action) end,
            }
        end
    end
    return #opts > 1 and opts or nil
end

--- The pile's E prompt: on its prop, or following its flying object (`follow`).
---@param data table
---@param follow function|nil
local function RegisterGroundPrompt(data, follow)
    if not Interactions then return end
    Interactions.register({
        id       = 'ground_' .. data.id,
        x        = data.x,
        y        = data.y,
        z        = data.z,
        follow   = follow,
        label    = GroundPromptLabel(data),
        -- An arrow off the ground, not the letter E: the picture says what happens; the label
        -- says what it is.
        icon     = 'pickup',
        group    = 'ground_items',
        -- Pick up, then what the item adds (Equip on a gun): scroll to choose, E does it. None: Pick up alone.
        options  = groundPromptOptions(data),
        -- Not through a wall (pileInSight).
        condition = function() return pileInSight(data.id) end,
        callback = function() pickUpPile(data.id) end,
    })
end

--- [id] = true while a prop's model loads: the streaming pass and groundItemSettled can both ask for
--- the same pile in that time, and two props would be made with only one remembered.
local spawning = {}

--- A flying pile's object here, or nil (not streamed in, or gone).
---@param netId number
---@return number|nil
local function flyingObject(netId)
    if not netId or not NetworkDoesNetworkIdExist(netId) then return nil end
    local obj = NetToObj(netId)
    if obj == 0 or not DoesEntityExist(obj) then return nil end
    return obj
end

-- The prompt keeps up with the throw: the interaction engine calls `follow` only once a prompt's
-- registered position is in range, so, as AddAction does for moving entities (client/actions.lua),
-- the registered position is kept fresh here, ten times a second, only while something is flying.
local flyingPrompts = {}   -- [id] = netId
local flyingRunning = false
local function keepFlyingPromptsFresh()
    if flyingRunning then return end
    flyingRunning = true
    CreateThread(function()
        while next(flyingPrompts) do
            for id, netId in pairs(flyingPrompts) do
                local obj = flyingObject(netId)
                if obj and Interactions then
                    local c = GetEntityCoords(obj)
                    Interactions.updatePosition('ground_' .. id, c.x, c.y, c.z)
                end
            end
            Wait(100)
        end
        flyingRunning = false
    end)
end

local function SpawnGroundProp(data)
    if groundItemProps[data.id] or spawning[data.id] then return end  -- already spawned, or on its way

    -- Still flying (a throw): the pile is the thrower's networked object for now, so no
    -- prop of our own — only its prompt, following that object so anyone in reach can grab it out of
    -- the air. 0 marks it shown for the streaming pass; groundItemSettled puts the real prop in place.
    if data.flight then
        groundItemProps[data.id] = 0
        local netId = data.flight
        RegisterGroundPrompt(data, function()
            local obj = flyingObject(netId)
            if not obj then return nil end
            local c = GetEntityCoords(obj)
            return c.x, c.y, c.z
        end)
        flyingPrompts[data.id] = netId
        keepFlyingPromptsFresh()
        return
    end

    local modelName = Inventory.itemPropModel(data.item)
    spawning[data.id] = true
    local model = LoadModel(modelName)
    spawning[data.id] = nil
    if not model then
        print(('[whip_core:ground] WARNING: Failed to load model %s for item #%d'):format(modelName, data.id))
        return
    end
    -- Gone or replaced while the model loaded (picked up, or settled from a newer copy).
    if groundItemsData[data.id] ~= data or groundItemProps[data.id] then
        SetModelAsNoLongerNeeded(model)
        return
    end

    local obj = CreateObject(model, data.x, data.y, data.z, false, false, false)
    if not obj or obj == 0 then
        SetModelAsNoLongerNeeded(model)
        return
    end

    FreezeEntityPosition(obj, true)
    SetEntityCollision(obj, false, false)
    -- Thrown and dropped items get snapped to the ground: their z is approximate (a physics
    -- rest point, or "in front of the ped minus half a metre") and the snap tidies it up.
    -- A PLACED item is the opposite case: its z, heading and tilt are exact (the placing-mode
    -- ghost stood on that surface), and the snap would drop a wallet placed on a table to the
    -- floor. The full rotation (the ghost's order-2 call) puts a slope placement ON the slope.
    -- Frozen + no collision means the prop cannot fall on its own.
    if data.placed then
        -- Re-assert the coords with NoOffset: CreateObject positions an object with a
        -- model-dependent offset, while the ghost was placed with SetEntityCoordsNoOffset.
        -- Same native, same rotation, same numbers as the ghost (WYSIWYG).
        SetEntityCoordsNoOffset(obj, data.x, data.y, data.z, false, false, false)
        SetEntityRotation(obj, data.rx or 0.0, data.ry or 0.0, data.heading or 0.0, 2, true)
    else
        SetEntityHeading(obj, data.heading or 0.0)
        PlaceObjectOnGroundProperly(obj)
    end
    SetEntityAsMissionEntity(obj, true, true)

    SetModelAsNoLongerNeeded(model)
    groundItemProps[data.id] = obj
    RegisterGroundPrompt(data)
end

local function DespawnGroundProp(id)
    flyingPrompts[id] = nil
    local obj = groundItemProps[id]
    if obj then
        local closeAt = grabbing[id]
        if closeAt and GetGameTimer() < closeAt and DoesEntityExist(obj) then
            -- Picked up while the hand is still reaching for it (PlayGrab): it leaves the ground as the hand closes.
            SetTimeout(closeAt - GetGameTimer(), function()
                if DoesEntityExist(obj) then DeleteEntity(obj) end
            end)
        elseif DoesEntityExist(obj) then
            DeleteEntity(obj)
        end
        groundItemProps[id] = nil
    end

    -- Unregister from 3D interaction system
    if Interactions then
        Interactions.remove('ground_' .. id)
    end
end

-- ============================================
-- NUI Ground Panel Refresh
-- ============================================

--- Rebuild nearby ground items and push to the NUI ground panel.
---
--- Global: the ground<->glovebox swap in client/vehicles.lua repaints this panel when it is visible
--- again (its data stays current meanwhile). The gate on the next line is why the caller must clear
--- Inventory.activeVehicleStorage FIRST.
function RefreshNUIGroundItems()
    if not Inventory.isOpen or not Inventory.isOpen() then return end
    if Inventory.activeContainerId or Inventory.activeVehicleStorage or ActiveShopId then return end

    local coords = GetEntityCoords(PlayerPedId())
    local pickupRange = Config.GroundItemPickupRange or 10.0
    local rangeSq = pickupRange * pickupRange
    local nearby = {}

    for id, data in pairs(groundItemsData) do
        local dx = coords.x - data.x
        local dy = coords.y - data.y
        local dz = coords.z - data.z
        -- In reach AND in sight: not through a wall (pileInSight).
        if (dx * dx + dy * dy + dz * dz) <= rangeSq and pileInSight(id) then
            nearby[#nearby + 1] = data
        end
    end

    local groundSlots = {}
    for i, gItem in ipairs(nearby) do
        groundSlots[tostring(i)] = {
            item     = gItem.item,
            amount   = gItem.amount,
            metadata = gItem.metadata,
            groundId = gItem.id,
        }
    end

    SendNUIMessage({ action = 'groundItemsRefresh', data = groundSlots })
end

-- ============================================
-- Server → Client: Sync Events
-- ============================================

--- Full sync (on connect/load) — receives nearby items from server
RegisterNetEvent('whip_core:client:groundItemsSync', function(items)
    groundItemsData = {}
    clientGrid = {}
    clientItemCells = {}
    if items then
        for id, data in pairs(items) do
            local numId = tonumber(id) --[[@as number]]   -- the server's pile ids
            groundItemsData[numId] = data
            clientGridInsert(numId, data.x, data.y)
        end
    end
end)

--- Incremental cell sync: server sends items from newly entered cells, which cells they are, and the
--- cells it no longer tells us about
RegisterNetEvent('whip_core:client:groundItemsBatchAdd', function(items, cells, leftCells)
    items = items or {}
    local count = 0

    --- Forget one pile here (not deleted on the server: just not ours to know about now).
    local function forget(id)
        clientGridRemove(id)
        groundItemsData[id] = nil
        sightCache[id] = nil
        DespawnGroundProp(id)
        count = count + 1
    end

    -- What we hold is what we are told about (a delete goes only to the players holding the pile's
    -- cell). Cells the server stopped telling us about are forgotten now (all at least the stream
    -- range away), and a grant is the cells' whole contents: whatever we hold in a granted cell that
    -- the batch does not carry is gone.
    if type(leftCells) == 'table' then
        for key in pairs(leftCells) do
            local bucket = clientGrid[key]
            if bucket then
                local ids = {}
                for id in pairs(bucket) do ids[#ids + 1] = id end
                for _, id in ipairs(ids) do forget(id) end
            end
        end
    end
    if type(cells) == 'table' then
        local carried = {}
        for id in pairs(items) do carried[tonumber(id)] = true end
        for key in pairs(cells) do
            local bucket = clientGrid[key]
            if bucket then
                local gone = {}
                for id in pairs(bucket) do
                    if not carried[id] then gone[#gone + 1] = id end
                end
                for _, id in ipairs(gone) do forget(id) end
            end
        end
    end

    for id, data in pairs(items) do
        local numId = tonumber(id) --[[@as number]]   -- the server's pile ids
        local known = groundItemsData[numId]
        if not known then
            groundItemsData[numId] = data
            clientGridInsert(numId, data.x, data.y)
            count = count + 1
        elseif known.x ~= data.x or known.y ~= data.y or known.z ~= data.z or known.flight ~= data.flight
            or known.heading ~= data.heading then
            -- Where it lies changed while we were not told (a throw that came to rest out of our
            -- cells): taken as the grant has it, and drawn afresh by the streaming pass.
            clientGridRemove(numId)
            groundItemsData[numId] = data
            clientGridInsert(numId, data.x, data.y)
            sightCache[numId] = nil
            DespawnGroundProp(numId)
            count = count + 1
        elseif known.amount ~= data.amount then
            -- A pile we already knew is brought up to date: a split made while we were away was not
            -- announced to us. (Where it lies does not change.)
            known.amount, known.metadata = data.amount, data.metadata
            if groundItemProps[numId] and Interactions then
                Interactions.updateLabel('ground_' .. numId, GroundPromptLabel(known))
            end
            count = count + 1
        end
    end
    if count > 0 then
        RefreshNUIGroundItems()
    end
end)

--- Could this item be on the ground panel right now? These events go to every client holding the
--- pile's cell, so a repaint is skipped out of reach. A little past the pickup range, so an item at
--- its edge still repaints.
local function onMyPanel(data)
    if not data or not data.x then return false end
    local coords = GetEntityCoords(PlayerPedId())
    local reach  = (Config.GroundItemPickupRange or 10.0) + 2.0
    local dx, dy, dz = coords.x - data.x, coords.y - data.y, coords.z - data.z
    return (dx * dx + dy * dy + dz * dz) <= reach * reach
end

--- Is this pile close enough to be drawn (the streaming range)?
---@param data table
---@return boolean
local function inStreamRange(data)
    local c = GetEntityCoords(PlayerPedId())
    local range = Config.GroundItemStreamRange or 100.0
    local dx, dy, dz = c.x - data.x, c.y - data.y, c.z - data.z
    return (dx * dx + dy * dy + dz * dz) <= range * range
end

--- Single item created (broadcast from server)
RegisterNetEvent('whip_core:client:groundItemCreated', function(data)
    if not data or not data.id then return end
    groundItemsData[data.id] = data
    clientGridInsert(data.id, data.x, data.y)
    -- A throw's prompt at once: it is in the air for a second or two, and the streaming pass could
    -- leave it unshown for half of one. (A flying pile has no model to load, so this does not wait.)
    if data.flight and inStreamRange(data) then SpawnGroundProp(data) end
    -- Watched while it flies: thrown hard into this player, it knocks them down (client/inventory.lua)
    if data.flight then Inventory.watchThrow(data.flight, data.flightBy) end
    if onMyPanel(data) then RefreshNUIGroundItems() end
end)

--- Single item removed (broadcast from server)
RegisterNetEvent('whip_core:client:groundItemDeleted', function(id)
    if not id then return end
    local known = groundItemsData[id]
    if known then Inventory.unwatchThrow(known.flight) end   -- caught out of the air
    clientGridRemove(id)
    groundItemsData[id] = nil
    sightCache[id] = nil
    DespawnGroundProp(id)
    if onMyPanel(known) then RefreshNUIGroundItems() end
end)

--- A throw came to rest (GroundItems.settle): where it lies now, and how. Drawn AT ONCE rather than
--- on the next streaming pass, because its flying object is deleted a second after this is sent and
--- the pile must already be there when it goes.
RegisterNetEvent('whip_core:client:groundItemSettled', function(data)
    if type(data) ~= 'table' or not data.id then return end
    local was = groundItemsData[data.id]
    local netId = was and was.flight
    Inventory.unwatchThrow(netId)   -- landed
    clientGridRemove(data.id)
    groundItemsData[data.id] = data
    clientGridInsert(data.id, data.x, data.y)
    DespawnGroundProp(data.id)   -- the prompt that followed it through the air
    if inStreamRange(data) then SpawnGroundProp(data) end

    -- And the flying one goes from this screen now: anyone but the thrower sees it a little behind
    -- where it really is (the game smooths another player's object). Invisible here at once, with no
    -- collision; the server deletes it shortly.
    local obj = flyingObject(netId)
    if obj then
        SetEntityAlpha(obj, 0, false)
        SetEntityCollision(obj, false, false)
    end
    if onMyPanel(data) then RefreshNUIGroundItems() end
end)

--- A pile's count changed (a split on the ground). The prop stays where it is; the count on its
--- prompt and in the Nearby panel follow.
RegisterNetEvent('whip_core:client:groundItemUpdated', function(id, amount)
    local known = id and groundItemsData[id]
    if not known or type(amount) ~= 'number' then return end
    known.amount = amount
    if groundItemProps[id] and Interactions then
        Interactions.updateLabel('ground_' .. id, GroundPromptLabel(known))
    end
    if onMyPanel(known) then RefreshNUIGroundItems() end
end)

-- ============================================
-- Streaming Thread — grid-accelerated spawn/despawn
-- ============================================

--- Forget piles in cells the server no longer syncs to us (ground items never expire). The server
--- re-sends a cell's piles when we enter it again (groundItemsBatchAdd), so a cell outside the square
--- it syncs (one ring wider, to be sure) is safe to drop.
local PRUNE_EVERY = 20   -- streaming passes (500 ms each): every ten seconds
local function pruneFarCells(playerCoords, streamRange)
    local keep = clientGetNearbyCellKeys(playerCoords.x, playerCoords.y, streamRange + getClientCellSize())
    for key, bucket in pairs(clientGrid) do
        if not keep[key] then
            for id in pairs(bucket) do
                if not groundItemProps[id] then
                    groundItemsData[id] = nil
                    clientItemCells[id] = nil
                    bucket[id] = nil
                end
            end
            if not next(bucket) then clientGrid[key] = nil end
        end
    end
end

-- The cells round the player, kept until they step into another cell (or the range changes): working them out is 25
-- joined strings and a table, twice a second for every player standing still.
local nearCells, nearCx, nearCy, nearRadius = nil, nil, nil, nil
local function cellsAround(x, y, range)
    local cs = getClientCellSize()
    local radius = math.ceil(range / cs)
    local cx, cy = math.floor(x / cs), math.floor(y / cs)
    if not (nearCells and cx == nearCx and cy == nearCy and radius == nearRadius) then
        nearCells, nearCx, nearCy, nearRadius = clientGetNearbyCellKeys(x, y, range), cx, cy, radius
    end
    return nearCells
end

CreateThread(function()
    local passes = 0
    while true do
        -- No ground items known and none drawn: nothing to stream in, out or prune
        if next(groundItemsData) == nil and next(groundItemProps) == nil then
            Wait(500)
            goto continue
        end

        local cost = WhipCost.start()
        local playerCoords = GetEntityCoords(PlayerPedId())
        local streamRange = Config.GroundItemStreamRange or 100.0
        local streamRangeSq = streamRange * streamRange

        passes = passes + 1
        if passes >= PRUNE_EVERY then
            passes = 0
            pruneFarCells(playerCoords, streamRange)
        end

        -- Spawn pass: only check items in nearby cells
        local nearbyCells = cellsAround(playerCoords.x, playerCoords.y, streamRange)
        local inRange = {}

        for key in pairs(nearbyCells) do
            local bucket = clientGrid[key]
            if bucket then
                for id in pairs(bucket) do
                    local data = groundItemsData[id]
                    if data then
                        local dx = playerCoords.x - data.x
                        local dy = playerCoords.y - data.y
                        local dz = playerCoords.z - data.z
                        if (dx * dx + dy * dy + dz * dz) <= streamRangeSq then
                            inRange[id] = true
                            if not groundItemProps[id] then
                                SpawnGroundProp(data)
                            end
                        end
                    end
                end
            end
        end

        -- Despawn pass: remove props no longer in range
        for id in pairs(groundItemProps) do
            if not inRange[id] then
                DespawnGroundProp(id)
            end
        end

        WhipCost.stop('ground items: stream in and out (2 a second)', cost)
        Wait(500)
        ::continue::
    end
end)

-- ============================================
-- Cleanup on resource stop
-- ============================================

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then
        for _, obj in pairs(groundItemProps) do
            if DoesEntityExist(obj) then
                DeleteEntity(obj)
            end
        end
        groundItemProps = {}
        groundItemsData = {}
        clientGrid = {}
        clientItemCells = {}
        if Interactions then
            Interactions.removeGroup('ground_items')
        end
    end
end)

-- ============================================
-- NUI Callbacks — Ground Operations
-- ============================================

-- ---- Where a dropped item lands ----
--
-- Found here, because only a client can see walls (a drop must not land on the far side of one).
-- Each candidate spot must have nothing between the player and it — a
-- ray at chest height and one at knee height, to a little past the spot so the item is not in the
-- wall either — and a floor under it not far below the feet (no ledge, no hole), and no pile on it
-- already. Tried in front first, a little wider each time, then all the way round. None clear:
-- "Nowhere to place!", and nothing is sent. The server takes the spot only within reach of the player.

local DROP_RAY_FLAGS = 1 | 2 | 16   -- the map (interiors included), vehicles, objects; not peds
local DROP_RAY_OPTIONS = 4          -- ignore no-collision only: glass still stops a drop

local function blocked(x1, y1, z1, x2, y2, z2, ped)
    local ray = StartExpensiveSynchronousShapeTestLosProbe(x1, y1, z1, x2, y2, z2, DROP_RAY_FLAGS, ped, DROP_RAY_OPTIONS)
    local _, hit, at = GetShapeTestResult(ray)
    return hit == 1, at
end

--- A clear spot to drop on, as x, y, z (the floor), or nil when there is none.
---@return number|nil x, number|nil y, number|nil z
local function findDropSpot()
    local ped = PlayerPedId()
    if ped == 0 then return nil end
    local p = GetEntityCoords(ped)            -- the pelvis, about 1 m up
    local heading = GetEntityHeading(ped)
    local chest, knee = p.z + 0.3, p.z - 0.5
    local reach = math.max(0.8, (Config.GroundItemPickupRange or 2.0) - 0.4)

    local function try(angle, dist)
        local h = math.rad(-(heading + angle))
        local dx, dy = math.sin(h), math.cos(h)
        local x, y = p.x + dx * dist, p.y + dy * dist
        local px, py = p.x + dx * (dist + 0.25), p.y + dy * (dist + 0.25)
        if blocked(p.x, p.y, chest, px, py, chest, ped) then return nil end
        if blocked(p.x, p.y, knee, px, py, knee, ped) then return nil end
        local floor, at = blocked(x, y, chest, x, y, p.z - 2.5, ped)
        if not floor then return nil end
        for _, g in pairs(groundItemsData) do
            if g.x and (g.x - x) ^ 2 + (g.y - y) ^ 2 < 0.09 then return nil end
        end
        return x, y, at.z
    end

    for n = 0, 7 do
        local x, y, z = try((math.random() * 2.0 - 1.0) * (35.0 + n * 12.0),
            math.min(reach, 0.6 + n * 0.15 + math.random() * 0.5))
        if x then return x, y, z end
    end
    for n = 0, 11 do
        local x, y, z = try(n * 30.0 + math.random() * 20.0, 0.5 + math.random() * 0.4)
        if x then return x, y, z end
    end
    return nil
end

--- Answer the page's drop with "Nowhere to place!": its optimistic op goes back, the reason shown.
local function nowhereToPlace(opId)
    SendNUIMessage({
        action = 'inventoryRevert',
        error  = 'Nowhere to place!',
        opId   = (tonumber(opId) or 0) > 0 and opId or nil,
    })
end

-- opId rides along on all three: the NUI opens an optimistic operation for every ground
-- gesture, and the server echoes the id on refusal so the revert unwinds exactly that
-- gesture (storeMove's contract).
RegisterNUICallback('dropToGround', function(data, cb)
    cb('ok')
    local x, y, z = findDropSpot()
    if not x then return nowhereToPlace(data.opId) end
    TriggerServerEvent('whip_core:server:dropToGround',
        data.fromContainer, data.fromSlot, data.amount, data.opId or 0, x, y, z
    )
end)

RegisterNUICallback('pickupGroundItem', function(data, cb)
    cb('ok')
    -- Asked again at the drag: the panel was built before the player may have stepped behind a wall.
    local id = tonumber(data.groundId)
    if id and groundItemsData[id] then
        sightCache[id] = nil
        if not pileInSight(id) then
            SendNUIMessage({ action = 'inventoryRevert', error = "You can't reach that from here",
                opId = (tonumber(data.opId) or 0) > 0 and data.opId or nil })
            return
        end
    end
    TriggerServerEvent('whip_core:server:pickupGroundItem',
        data.groundId, data.toContainer, data.toSlot, data.opId or 0
    )
end)

RegisterNUICallback('dropOneToGround', function(data, cb)
    cb('ok')
    local x, y, z = findDropSpot()
    if not x then return nowhereToPlace(data.opId) end
    TriggerServerEvent('whip_core:server:dropOneToGround',
        data.fromContainer, data.fromSlot, data.opId or 0, x, y, z
    )
end)

-- The Nearby panel's context menu: Split and Destroy, like every other grid outside the pockets.
RegisterNUICallback('splitGroundItem', function(data, cb)
    TriggerServerEvent('whip_core:server:splitGroundItem',
        data.groundId, data.splitAmount, data.opId or 0
    )
    cb('ok')
end)

RegisterNUICallback('destroyGroundItem', function(data, cb)
    TriggerServerEvent('whip_core:server:destroyGroundItem',
        data.groundId, data.opId or 0
    )
    cb('ok')
end)

-- ============================================
-- Which pile an object is (the Object Viewer's options, Dungeon Mode)
-- ============================================

GroundPiles = {}

--- The ground pile an object is, as this game knows it: { id, item, amount, label }, or nil.
---@param entity number
---@return table|nil
function GroundPiles.of(entity)
    if not entity or entity == 0 then return nil end
    for id, obj in pairs(groundItemProps) do
        if obj == entity then
            local d = groundItemsData[id]
            if not d then return nil end
            local def = Config.Items[d.item]
            return { id = id, item = d.item, amount = d.amount or 1, label = def and def.name or d.item }
        end
    end
    return nil
end

--- A pile's object on this game now, or nil (not made here: out of range, or in the air).
---@param id number
---@return number|nil
function GroundPiles.prop(id)
    local obj = groundItemProps[id]
    return obj and obj ~= 0 and DoesEntityExist(obj) and obj or nil
end

-- ============================================
-- Utility
-- ============================================

function TableCount(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

