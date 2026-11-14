-- ============================================
-- GARAGE POSITION HELPER — the bay outline a driver sees
-- ============================================
--
-- Interaction prompts are hidden while the player is in a vehicle (client/interact.lua), which
-- leaves a parking bay invisible to the driver. So a driver gets the bay laid on the tarmac: a glass
-- slab with a white ring drawing itself on round it and the garage icon in the middle, and the ring
-- complete over a blue wash once the car is in it (html/interact3d/garagebay.html).
--
-- A hint, not a control: nothing here is pressable, triggers events or asks the server anything.
--
-- ============================================
-- How it is built
-- ============================================
--
-- One browser for the whole feature (the DUI count must not grow with the things on screen): a car
-- park with thirty bays draws thirty quads from ONE texture.
--
-- State changes cost nothing: the page is an atlas (the bay and its icon, approaching and parked),
-- and switching a bay samples a different band of v. The icon is a quad of its own over the bay's
-- centre so it can turn to face the camera.
--
-- Positions come from the engine, computed in the same frame as the camera (no lag behind a moving
-- car), and real polygons depth-test (the outline goes behind a car parked on it).
--
-- ============================================
-- SWEEP, THEN DRAW
-- ============================================
--
-- The same split client/garage_spots.lua uses: the expensive question four times a second, the
-- cheap one every frame.
--
--   SWEEP   which bays qualify, and what state each is in. Walks the spot table, so it must not
--           run per frame.
--   DRAW    ease each live bay's alpha and put a quad on the ground. No decisions.
--
-- A bay that stops qualifying is not dropped: it keeps its own copy of what it needs and fades
-- out first (something that is dropped cannot fade).

local HELPER_PAGE = 'garagebay'
local TXD = 'whip_garagebay'
local TEX = 'bay'

local DUI_W, DUI_H = 384, 1024

-- The atlas cells. Must match html/interact3d/garagebay.html: the two bay cells stacked 256x512
-- down the left (u 0 to 256/384), the two icon cells 128x128 at the top of the right-hand strip.
local BAY_U1 = 256 / DUI_W
local ROW_APPROACH = { v0 = 0.0, v1 = 0.5 }
local ROW_PARKED   = { v0 = 0.5, v1 = 1.0 }
local ICON_APPROACH = { v0 = 0.0,   v1 = 0.125 }
local ICON_PARKED   = { v0 = 0.125, v1 = 0.25 }

-- The icon's square, as a share of the bay's width: 128 px of a 256 px-wide bay, so it is drawn
-- at the same pixels per metre as the bay round it.
local ICON_SCALE = 0.5

-- Lifted over the bay by a centimetre, so the two flat quads never fight for the same depth.
local ICON_LIFT = 0.01

--- [spotId] = { x, y, z, heading, alpha, target, parked }
---
--- Its own copy of the bay, not a reference into GetGarageSpotDefs() (a bay deleted mid-fade).
local live = {}

--- When an editor last drew a bay of its own (GarageBayDraw: the bay tool, PropertyEditor.placeBays). While one does,
--- the driving rules stand aside: they would draw each saved bay a second time, where it was, under the one being
--- moved.
local editorDrawAt = -1000000

local function cfg()
    return Config.GaragePositionHelper or {}
end

-- ============================================
-- The browser
-- ============================================

--- Made the first time a bay draws (page:ensure() in every draw, which also keeps it), and given back
--- after Config.GaragePositionHelper.idleReleaseMs drawing nothing: reversing out and back in should not
--- rebuild a browser. 0 keeps it.
local page = DuiPage.new({
    name = 'garagehelper', url = ('interact3d/%s.html'):format(HELPER_PAGE), width = DUI_W, height = DUI_H,
    txd = TXD, tex = TEX, without = 'the bay outline will not draw',
    idleMs = function() return cfg().idleReleaseMs or 60000 end,
})

-- ============================================
-- The decisions
-- ============================================

--- Is this heading close enough to the bay's to count as parked straight?
---
--- Either way round: a car reversed in is parked as much as one driven in nose first (180 degrees
--- off counts; sideways does not). Wrapped into -180..180 before comparing (355 in a bay at 5 is
--- ten degrees out, not 350).
---@param vehHeading number
---@param spotHeading number
---@param tolDeg number
---@return boolean
function GarageHelperAligned(vehHeading, spotHeading, tolDeg)
    local diff = math.abs(((vehHeading or 0.0) - (spotHeading or 0.0) + 180.0) % 360.0 - 180.0)
    local tol = tolDeg or 25.0
    return diff <= tol or diff >= 180.0 - tol
end

--- The vehicle this player is DRIVING, or nil.
---
--- The driver's seat specifically: a passenger cannot park anything.
local function drivenVehicle()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if not veh or veh == 0 then return nil end
    if GetPedInVehicleSeat(veh, -1) ~= ped then return nil end
    return veh
end

--- Cached ownership answer, because the sweep runs four times a second and the vehicle under the
--- player changes about as often as they get out of it.
---
--- It expires: ownership can change while the player sits in the car (buying it).
local ownedCacheEntity, ownedCacheValue, ownedCacheAt = nil, false, 0
local OWNED_TTL_MS = 5000

--- Would this car be worth showing bays for?
---
--- `owned` on a vehicle context means whip holds a def for it, and a client is only ever sent defs
--- for its OWN character's vehicles (server-side Vehicles.wireForOwner) — so this is "my car", it
--- costs no round trip, and it matches the rule the server enforces when storing.
---
--- Ownership itself, not a key item. A car the server would store but this client holds no def for
--- is what Config.GaragePositionHelper.requireStorable exists to switch off.
---@param veh number
---@return boolean
local function vehicleQualifies(veh)
    if not cfg().requireStorable then return true end

    local now = GetGameTimer()
    if ownedCacheEntity == veh and (now - ownedCacheAt) < OWNED_TTL_MS then
        return ownedCacheValue
    end

    local ok, ctx = pcall(function()
        return Vehicles.get({ entity = veh })
    end)
    ownedCacheEntity = veh
    ownedCacheAt = now
    -- `mine`, not `owned`: GetVehicle's context names this field `mine` (client/vehicles.lua,
    -- BuildVehicleContext).
    ownedCacheValue = (ok and ctx and ctx.mine) and true or false
    return ownedCacheValue
end

-- ============================================
-- Sweep
-- ============================================

--- Is this bay one the helper shows? One rule, for the drawing (sweep):
---   * never a bay of somebody's private garage (GarageUsable, client/garage_spots.lua);
---   * a free bay, or one not swept yet (the tri-state: nil is not "taken");
---   * the bay my car is in (inSpotId), or one only the car I drive takes;
---   * on foot, every bay (the outline says where the garage is).
---@return boolean usable
---@return string|nil why  why not, for the report
---@return boolean|nil taken  the occupancy, for the report's note
local function bayRule(spotId, s, inSpotId, onFoot)
    local taken, takenByMyCar = nil, nil
    if GarageSpotOccupancy then taken, takenByMyCar = GarageSpotOccupancy(spotId) end
    if GarageUsable and not GarageUsable(s.garageKey) then return false, 'a private garage this player may not use', taken end
    if taken ~= true or spotId == inSpotId or takenByMyCar or onFoot then return true, nil, taken end
    return false, 'occupied by another vehicle', taken
end

--- Rebuild the set of bays that should be on screen, and what each should look like.
local function sweep()
    local c = cfg()

    -- Everything currently up starts as "going away". Anything the pass below finds is turned
    -- back on; whatever is left fades out on its own.
    for _, e in pairs(live) do e.target = 0.0 end

    if not c.enabled then return end

    -- The bay tool owns the screen while it is up (or a bay draws twice, saved and being moved).
    -- Everything already up fades out: the targets were zeroed before this check.
    if GetGameTimer() - editorDrawAt < 500 then return end

    -- All three checked (client/garage_spots.lua), so a file that failed to load is a quiet return.
    if not (GetGarageSpotDefs and GarageSpotOccupancy and GarageSpotForVehicle) then return end

    local veh = drivenVehicle()
    -- On foot too, closer: the bays of garages this player may use, within
    -- onFootRange of them, in the approaching look (no car is in one). Not for a passenger, or a
    -- player getting in or out: only someone standing on their own feet. 0 turns it off.
    local onFoot = false
    if veh then
        if not vehicleQualifies(veh) then return end
    else
        if (c.onFootRange or 0) <= 0 or IsPedInAnyVehicle(PlayerPedId(), true) then return end
        onFoot = true
    end

    -- On foot, measure from the player instead of a car they are not in.
    local vpos = veh and GetEntityCoords(veh) or GetEntityCoords(PlayerPedId())
    local vheading = veh and GetEntityHeading(veh) or GetEntityHeading(PlayerPedId())
    local range = onFoot and c.onFootRange or (c.showRange or 30.0)
    local rangeSq = range * range

    -- Which bay this car is actually sitting in, asked ONCE for the car rather than per bay.
    -- GarageSpotForVehicle uses Config.GarageSpotRadius, so "parked" means what it means to Store.
    local inSpot = GarageSpotForVehicle(veh)
    local inSpotId = inSpot and inSpot.spotId or nil

    for spotId, s in pairs(GetGarageSpotDefs()) do
        local dx, dy, dz = s.x - vpos.x, s.y - vpos.y, s.z - vpos.z

        -- The car you are driving does not count as occupying the bay (or the outline would vanish
        -- the moment it should say "you are in"); a bay occupied by anyone else still does.
        -- Unknown counts as usable: the occupancy cache is tri-state (nil: not swept yet), and a
        -- driver arrives exactly before the sweep has run. Only the prompt needs the strict reading.
        --
        -- The rule is bayRule (above): private garages never, on foot every bay (a car in it or not:
        -- what a car in the bay takes away is the bay's own prompt), and a bay taken only by the car
        -- I drive is mine.
        local usable = bayRule(spotId, s, inSpotId, onFoot)

        if (dx * dx + dy * dy + dz * dz) <= rangeSq and usable then
            local e = live[spotId]
            if not e then
                -- Starts invisible so it fades UP rather than snapping in at full strength.
                e = { alpha = 0.0 }
                live[spotId] = e
            end

            e.x, e.y, e.z, e.heading = s.x, s.y, s.z, s.heading
            e.target = 1.0
            e.parked = (spotId == inSpotId)
                and GarageHelperAligned(vheading, s.heading, c.alignDeg or 25.0) or false
        end
    end
end

-- ============================================
-- Draw
-- ============================================

--- The icon's flat basis at a bay's centre: its top pointing AWAY from the camera, so it reads the
--- right way up from wherever you are (nose first, reversing in, going past the end). It turns about
--- the vertical only, so it stays flat on the ground like the
--- bay. Right is up's clockwise perpendicular, as WorldQuad.groundBasis has it.
---
--- Right under the camera there is no "away", and the icon would spin as the camera moved over
--- it, so within 0.75 m it takes the way the camera is looking instead.
---@return number rx, number ry, number rz, number ux, number uy, number uz
local function iconBasis(x, y, camX, camY)
    local dx, dy = x - camX, y - camY
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.75 then
        local h = math.rad(GetFinalRenderedCamRot(2).z)
        dx, dy, len = -math.sin(h), math.cos(h), 1.0
    end
    local ux, uy = dx / len, dy / len
    return uy, -ux, 0.0, ux, uy, 0.0
end

--- One bay on the ground, and its icon over the centre turned to face the camera. Every place a
--- bay is drawn comes through here — the live bays and GarageBayDraw (the bay tool) — so the icon
--- can never be left behind by one of them.
---@param z number  already lifted by Config's zOffset
---@param alpha number  0-255
---@param sym table|nil  another symbol in its middle: { txd, tex, approach = { u0, v0, u1, v1 }, parked = {...} }
local function drawBay(x, y, z, heading, w, h, parked, alpha, tr, tg, tb, camX, camY, sym)
    local row = parked and ROW_PARKED or ROW_APPROACH
    local rx, ry, rz, ux, uy, uz = WorldQuad.groundBasis(heading)
    WorldQuad.draw(TXD, TEX,
        x, y, z,
        rx, ry, rz, ux, uy, uz,
        w, h,
        0.0, row.v0, BAY_U1, row.v1,
        alpha, tr, tg, tb)

    local s = w * ICON_SCALE
    rx, ry, rz, ux, uy, uz = iconBasis(x, y, camX, camY)
    if sym then
        local c = parked and sym.parked or sym.approach
        WorldQuad.draw(sym.txd, sym.tex,
            x, y, z + ICON_LIFT,
            rx, ry, rz, ux, uy, uz,
            s, s,
            c[1], c[2], c[3], c[4],
            alpha, tr, tg, tb)
        return
    end
    local icon = parked and ICON_PARKED or ICON_APPROACH
    WorldQuad.draw(TXD, TEX,
        x, y, z + ICON_LIFT,
        rx, ry, rz, ux, uy, uz,
        s, s,
        BAY_U1, icon.v0, 1.0, icon.v1,
        alpha, tr, tg, tb)
end

--- One frame. Returns true while anything is still visible, so the loop can idle when nothing is.
---@return boolean drewSomething
local function drawFrame()
    if not next(live) then return false end

    local c = cfg()
    local fade = (c.fadeMs or 180) / 1000.0
    if fade <= 0 then fade = 0.001 end

    -- Frame-rate independent, so the fade takes the same wall-clock time at 30fps and 140.
    local step = GetFrameTime() / fade

    local w = c.width or 2.60
    local h = c.length or 5.20
    local zOff = c.zOffset or 0.02

    -- Where the camera is, once for every bay this frame: the icons turn to face it.
    local cam = GetFinalRenderedCamCoord()
    local camX, camY = cam.x, cam.y

    local drew = false

    for spotId, e in pairs(live) do
        if e.alpha < e.target then
            e.alpha = math.min(e.target, e.alpha + step)
        elseif e.alpha > e.target then
            e.alpha = math.max(e.target, e.alpha - step)
        end

        if e.alpha <= 0.0 and e.target <= 0.0 then
            -- Finished fading out. Only now is it safe to forget.
            live[spotId] = nil
        else
            if page:ensure() then
                drawBay(e.x, e.y, e.z + zOff, e.heading, w, h, e.parked,
                    math.floor(e.alpha * 255.0), 255, 255, 255, camX, camY)

                drew = true
            end
        end
    end

    return drew
end

--- The bay outline at a spot, for ONE frame: for the bay tool (PropertyEditor.placeBays, every
--- garage's), so a bay being set out looks exactly like the bay a driver will see. Call it every
--- frame for as long as it should show; the browser is kept up while it is being called and
--- released as usual after, and the driving rules stand aside meanwhile (see editorDrawAt).
---@param alpha number|nil  0..1
---@param tint table|nil    { r, g, b } multiplied into the picture (the bay tool's green, white and red)
---@param parked boolean|nil  the "car is in it" picture
---@return boolean drawn
function GarageBayDraw(x, y, z, heading, alpha, tint, parked)
    if not page:ensure() then return false end
    local c = cfg()
    local cam = GetFinalRenderedCamCoord()
    drawBay(x, y, z + (c.zOffset or 0.02), heading or 0.0, c.width or 2.60, c.length or 5.20,
        parked, math.floor((alpha or 1.0) * 255.0),
        tint and tint[1] or 255, tint and tint[2] or 255, tint and tint[3] or 255,
        cam.x, cam.y)
    editorDrawAt = GetGameTimer()
    return true
end

--- The same bay for ONE frame under someone else's rules (a Director spot's garage marker:
--- client/director_spots.lua). Unlike GarageBayDraw, the driving rules keep running: a player's own
--- garage bays still show beside it.
---@param alpha number|nil  0..1
---@param parked boolean|nil  the "car is in it" picture
---@param sym table|nil  another symbol in its middle, from the caller's own browser (see drawBay)
---@return boolean drawn
function GarageBayDrawAt(x, y, z, heading, alpha, parked, sym)
    if not page:ensure() then return false end
    local c = cfg()
    local cam = GetFinalRenderedCamCoord()
    drawBay(x, y, z + (c.zOffset or 0.02), heading or 0.0, c.width or 2.60, c.length or 5.20,
        parked, math.floor((alpha or 1.0) * 255.0), 255, 255, 255, cam.x, cam.y, sym)
    return true
end

-- ============================================
-- Threads
-- ============================================

CreateThread(function()
    while true do
        local cost = WhipCost.start()
        sweep()
        WhipCost.stop('garage bays: sweep (4 a second)', cost)
        Wait(250)
    end
end)

CreateThread(function()
    while true do
        local cost = WhipCost.start()
        -- The bay tool draws its own (GarageBayDraw, from its own loop). drawFrame still runs
        -- underneath it so anything left over from driving finishes fading rather than being cut off.
        local drew = drawFrame()

        -- Per frame while something is on screen; a quarter second when nothing is. (The browser is given
        -- back by DuiPage after idleReleaseMs drawing nothing.)
        WhipCost.stop(drew and 'garage bays: drawing (every frame near a bay)' or 'garage bays: idle draw check', cost)
        Wait(drew and 0 or 250)
    end
end)

-- ============================================
-- Status, for the tuner and for tests
-- ============================================

--- What the helper is doing right now.
---
--- Observable state rather than a debug print, so tests can assert about it.
---@return table { enabled, duiActive, drawing, driving, qualifies }
exports('GetGarageHelperStatus', function()
    local n = 0
    for _, e in pairs(live) do
        if e.alpha > 0.0 then n = n + 1 end
    end

    local veh = drivenVehicle()
    return {
        enabled   = cfg().enabled and true or false,
        duiActive = page:exists(),
        drawing   = n,
        driving   = veh ~= nil,
        qualifies = (veh ~= nil) and vehicleQualifies(veh) or false,
    }
end)
