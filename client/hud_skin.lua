-- ============================================
-- HUD SKIN — Config.HudSkin
-- ============================================
--
--   'classic'  the HUD as it was: gauges as discs filling white, inside the capsule.
--   'black'    the gauges as black discs in a white rim that drains, with no capsule behind them
--              (it comes back only for a notification or the chat field) —
--              html/css/hud-skin.css — and, here:
--                * a white frame round the minimap, drawn UNDER GTA's HUD so the N and the blips
--                  that sit on the map's edge are drawn over it;
--                * the minimap's tiles swapped for whip's own dark map (stream/whipmap_*.ytd, made
--                  from the pause menu's vector map by dev/map_tiles/minimap_tiles.js);
--                * the waypoint, its blip and the GPS line in whip's blue instead of GTA's purple.
-- The vehicle dial is not part of it. Switched live in /whip → Config.
--
-- The frame is not on the page: everything on the NUI page is drawn over the game, radar included,
-- so a frame there would cover the compass N and the edge blips. Drawn by the game with
-- GFX_ORDER_BEFORE_HUD, it is under the radar: a filled rounded box (black, white, black from the
-- map's edge out), a little bigger than the map, which covers its middle. One baked sprite
-- (FRAME_DICT); while /radardebug is open, three vector layers that follow its sliders live.
--
-- /radardebug's "frame over the HUD" switch is for a build that draws the radar before script graphics.

local SKIN_DICT = 'whiphud'          -- stream/whiphud.ytd: 'disc', a white circle (the tuner's live frame's corners)
--- stream/whipframe_<shape>.ytd: 'frame', the whole frame baked for each minimap shape (dev/map_tiles/hud_frame.js).
--- One DrawSprite a frame (the vector frame is 18 draws). The vector frame is drawn only while /radardebug is open,
--- where the frame is being moved; the baked one is made from this file's numbers, so bake again after changing them.
local FRAME_DICT = 'whipframe_'
--- The black behind the map, as solid as each player likes: the frame's middle is filled black (GTA's radar is
--- see-through; the black makes it solid). stream/whipring_<shape>.ytd: 'ring', the same frame
--- with the middle left clear (dev/map_tiles/hud_frame.js ring). Solid: the frame alone, as ever (one draw). Part
--- way: the frame at the player's strength, then the ring over it at full, so only the middle fades (two). None: the
--- ring alone (one). The pause menu's Settings → Server → Map & HUD → Map background (map.background, below).
local RING_DICT = 'whipring_'
local ROUTE_COLOUR = 142             -- HUD_COLOUR_WAYPOINT: the waypoint, its blip and the GPS line
local ROUTE_BLUE = { 96, 165, 250 }  -- whip's Signal Blue (--ui-accent)

--- GTA's radar is six tiles, minimap_sea_<row>_<col>: two columns, three rows, 4500 m square, from
--- (-4140, 8400) at the top left (minimap.ymt). Each is swapped for whipmap_<row>_<col>.
local MAP_TILES = { '0_0', '0_1', '1_0', '1_1', '2_0', '2_1' }

--- The map's visible box, where the frame goes: posX, posY (up from the bottom), sizeX, sizeY, as
--- fractions of a 16:9 screen with the safe zone at FULL size — buildLayers adds the player's own
--- margin. Tuned in game with /radardebug's 'frame' row.
local frame = { 0.0060, 0.0700, 0.1720, 0.1655 }

--- The corners follow the mask's, which is stretched over the map: whip's 'rounded' mask is 512 x 396
--- with a 46 px radius (stream/whipmask_rounded.ytd), so its corners are 46/512 of the map's width
--- across and 46/396 of its height down — ellipses, on a map wider than the mask. 'circle' is the
--- whole box; 'square' has none. frameCorner scales them (the tuner's 'corner'; 1 = the mask's).
local MASK_CORNERS = { rounded = { 46 / 512, 46 / 396 }, square = { 0, 0 }, circle = { 0.5, 0.5 } }
local frameCorner = 1.0

--- The border, from the map's edge outwards, in screen heights: a black line, the white, a black edge
--- (1.3, 3.7 and 1.9 px at 1080p).
local BANDS = { inner = 0.0012, white = 0.0034, outer = 0.0018 }

--- GFX_ORDER_BEFORE_HUD, or GFX_ORDER_AFTER_HUD when the tuner says the frame must go on top.
local drawOrder = 1

local skinNow = nil       -- the skin last applied
---@type { colour: number[], rects: number[][], discs: number[][], dw: number, dh: number }[]|nil
local layers = nil        -- the frame's three layers, worked out for this screen (buildLayers)
---@type { dict: string, ring: string, x: number, y: number, w: number, h: number }|nil
local sprite = nil        -- the baked frame: its dictionary, centre and size on this screen (buildLayers)
local spriteReady, discReady = false, false   -- their dictionaries loaded, as last checked (buildLayers)
local ringReady = false   -- the ring's dictionary loaded, as last checked (buildLayers)
local fillAlpha = 255     -- the black behind the map, 0-255: the player's Map background (map.background)
local layersDue = 0       -- GetGameTimer() when they are looked at again
local sentBox = nil       -- the frame's box as the page was last told it
-- What they were last worked out from that nothing here hears change: the screen, its safe zone, the minimap's shape.
-- The rest (the tuner's frame and corner, the Map background) clears `layers` when it changes.
local builtW, builtH, builtSafe, builtMask = nil, nil, nil, nil
local routeWas = nil      -- GTA's own waypoint colour, before whip changed it
local mapSwapped = false

-- ---- the frame ----------------------------------------------------------------------------------

--- The frame's dictionaries: loaded yet? Asked for if not. Natives only, so it is asked on every pass, the ones that
--- change nothing too: a dictionary still streaming is picked up as it arrives.
local function checkReady()
    ---@cast sprite -nil   -- called only from buildLayers, once sprite is set
    spriteReady = HasStreamedTextureDictLoaded(sprite.dict) and true or false
    if not spriteReady then RequestStreamedTextureDict(sprite.dict, false) end
    -- The ring only while the black behind the map is not solid: a player at full never loads it.
    ringReady = fillAlpha < 255 and HasStreamedTextureDictLoaded(sprite.ring) and true or false
    if fillAlpha < 255 and not ringReady then RequestStreamedTextureDict(sprite.ring, false) end
    discReady = HasStreamedTextureDictLoaded(SKIN_DICT) and true or false
    if not discReady and RadarDebugOpen then RequestStreamedTextureDict(SKIN_DICT, false) end
end

--- The three filled rounded rectangles, back to front, for this screen's shape and safe zone. Looked at once a
--- second; worked out again only when something it is made from changed (it makes some 30 small tables, so a pass
--- that changes nothing makes nothing).
local function buildLayers()
    layersDue = GetGameTimer() + 1000
    local w, h = GetActiveScreenResolution()
    local safe = GetSafeZoneSize() or 1.0
    local mask = Config.MinimapMask
    if layers and w == builtW and h == builtH and safe == builtSafe and mask == builtMask then
        checkReady()
        return
    end
    builtW, builtH, builtSafe, builtMask = w, h, safe, mask
    local aspect = (h and h > 0) and (w / h) or (16 / 9)
    local xs = (16 / 9) / aspect                       -- a 16:9 width fraction, on this screen
    local margin = (1.0 - safe) / 2
    local left = margin + frame[1] * xs
    local bottom = 1.0 - (margin + frame[2])
    local fw, fh = frame[3] * xs, frame[4]
    local top = bottom - fh
    local corner = MASK_CORNERS[mask] or MASK_CORNERS.rounded
    local cx = math.min(fw / 2, corner[1] * fw * frameCorner)   -- the map's corner, across
    local cy = math.min(fh / 2, corner[2] * fh * frameCorner)   -- ...and down

    -- One layer: the map's box grown by e (screen heights) on every side, its corners with it.
    local function layer(e, colour)
        local ex = e / aspect
        local rx, ry = cx + ex, cy + e
        local L, R = left - ex, left + fw + ex
        local T, B = top - e, bottom + e
        local W, H = R - L, B - T
        return {
            colour = colour,
            -- a cross of two rects, and a disc (stretched to the corner's ellipse) in each corner
            rects = { { L + W / 2, T + H / 2, W, H - 2 * ry }, { L + W / 2, T + H / 2, W - 2 * rx, H } },
            discs = { { L + rx, T + ry }, { R - rx, T + ry }, { L + rx, B - ry }, { R - rx, B - ry } },
            dw = 2 * rx, dh = 2 * ry,
        }
    end

    local b = BANDS
    local outer = b.inner + b.white + b.outer
    layers = {
        layer(outer, { 0, 0, 0 }),
        layer(b.inner + b.white, { 255, 255, 255 }),
        layer(b.inner, { 0, 0, 0 }),
    }

    -- The baked frame covers the outer layer's box exactly. Its dictionary is asked for and checked on each look
    -- (checkReady), rather than every frame; a shape changed in /whip → Settings picks its own on the next look.
    local shape = MASK_CORNERS[mask] and mask or 'rounded'
    local L, R = left - outer / aspect, left + fw + outer / aspect
    local T, B = top - outer, bottom + outer
    sprite = { dict = FRAME_DICT .. shape, ring = RING_DICT .. shape, x = (L + R) / 2, y = (T + B) / 2, w = R - L, h = B - T }
    checkReady()

    -- The page lines the gauges up under the frame's outside edge (js/status-hud.js). Sent when it
    -- moves: the screen, the safe zone or the tuner. Fractions of the screen, from the left and the top.
    local box = { left = left - outer / aspect, right = left + fw + outer / aspect, bottom = bottom + outer }
    local key = ('%.4f %.4f %.4f'):format(box.left, box.right, box.bottom)
    if key ~= sentBox then
        sentBox = key
        SendNUIMessage({ action = 'hudFrameBox', left = box.left, right = box.right, bottom = box.bottom })
    end
end

--- Every frame while the black skin is on (held on the ControlBlocks loop: no thread of its own). Five natives a frame:
--- the two radar checks, the draw order there and back, and the one sprite. (IsMinimapRendering is false under GTA's
--- own pause menu too, so that is not asked separately.)
local function drawFrame()
    -- Looked at once a second, by the clock rather than a count of frames, for a resolution or safe-zone change.
    if not layers or GetGameTimer() >= layersDue then buildLayers() end
    ---@cast layers -nil   -- buildLayers has set both
    ---@cast sprite -nil

    if not IsMinimapRendering() or IsBigmapActive() then return end
    if CleanScreen.on then return end   -- a recording (client/clean_screen.lua): the map is hidden, so its frame is

    if not RadarDebugOpen then
        if not spriteReady then return end
        SetScriptGfxDrawOrder(drawOrder)
        if fillAlpha >= 255 or not ringReady then
            -- Solid (or the ring not in yet): the frame alone, as it always was.
            DrawSprite(sprite.dict, 'frame', sprite.x, sprite.y, sprite.w, sprite.h, 0.0, 255, 255, 255, 255)
        else
            -- The black behind the map at the player's strength, then the border solid over it (RING_DICT, above).
            if fillAlpha > 0 then
                DrawSprite(sprite.dict, 'frame', sprite.x, sprite.y, sprite.w, sprite.h, 0.0, 255, 255, 255, fillAlpha)
            end
            DrawSprite(sprite.ring, 'ring', sprite.x, sprite.y, sprite.w, sprite.h, 0.0, 255, 255, 255, 255)
        end
        SetScriptGfxDrawOrder(4)   -- GFX_ORDER_AFTER_HUD, the default, for whatever draws after this
        return
    end

    -- /radardebug is open: the live vector frame, which follows every slider (and the corner scale) exactly. Its
    -- middle stays solid whatever Map background says: the tuner is for where the frame sits.
    if not discReady then return end
    SetScriptGfxDrawOrder(drawOrder)
    for i = 1, #layers do
        local l = layers[i]
        local c = l.colour
        for j = 1, 2 do
            local r = l.rects[j]
            DrawRect(r[1], r[2], r[3], r[4], c[1], c[2], c[3], 255)
        end
        for j = 1, 4 do
            local d = l.discs[j]
            DrawSprite(SKIN_DICT, 'disc', d[1], d[2], l.dw, l.dh, 0.0, c[1], c[2], c[3], 255)
        end
    end
    SetScriptGfxDrawOrder(4)   -- GFX_ORDER_AFTER_HUD, the default, for whatever draws after this
end

local frameHeld = false

local function holdFrame(on)
    if on == frameHeld then return end
    frameHeld = on
    if on then
        layers, sentBox = nil, nil   -- worked out again, and the page told again
        ControlBlocks.hold('hudSkinFrame', {}, drawFrame)
    else
        ControlBlocks.release('hudSkinFrame')
    end
end

--- The border off, the black look on: nothing is drawn, but the page is still told where the frame would be (once a
--- second, sent only when it moves: buildLayers), so the gauges line up under the map as they do with it on.
local boxGen = 0

local function keepBoxSent(on)
    boxGen = boxGen + 1
    if not on then return end
    local gen = boxGen
    CreateThread(function()
        while gen == boxGen do
            buildLayers()
            Wait(1000)
        end
    end)
end

-- ---- the dark map -------------------------------------------------------------------------------

--- Swap GTA's radar tiles for whip's, or give them back. Fails soft: a tile whose dictionary did not
--- stream keeps GTA's (and says so once in F8).
local function swapMap(on)
    if on == mapSwapped then return end
    mapSwapped = on
    for _, t in ipairs(MAP_TILES) do
        local orig, mine = 'minimap_sea_' .. t, 'whipmap_' .. t
        if on then
            if LoadTextureDict(mine, 5000) then
                AddReplaceTexture(orig, orig, mine, mine)
            else
                print(('[whip_core:hud] the dark map tile %s did not stream — keeping GTA\'s. Expected stream/%s.ytd')
                    :format(t, mine))
            end
        else
            RemoveReplaceTexture(orig, orig)
            SetStreamedTextureDictAsNoLongerNeeded(mine)
        end
    end
    -- The radar picks the swap up on its next rebuild (client/hud.lua).
    if RadarRebuild then RadarRebuild() end
end

-- ---- the waypoint's colour ----------------------------------------------------------------------

local function blueRoute(on)
    if on then
        if not routeWas then routeWas = { GetHudColour(ROUTE_COLOUR) } end
        ReplaceHudColourWithRgba(ROUTE_COLOUR, ROUTE_BLUE[1], ROUTE_BLUE[2], ROUTE_BLUE[3], 255)
    elseif routeWas then
        ReplaceHudColourWithRgba(ROUTE_COLOUR, routeWas[1], routeWas[2], routeWas[3], routeWas[4])
    end
end

-- ---- applying -----------------------------------------------------------------------------------

--- Apply Config.HudSkin: the page's half always (it may have missed the last message), the game's
--- half when it changed. In a thread: the dictionaries are waited for.
---@param loaded boolean|nil  a character has just loaded (PlayerLoaded may not be set yet in that handler)
local function applySkin(loaded)
    local skin = Config.HudSkin == 'black' and 'black' or 'classic'
    SendNUIMessage({ action = 'setHudSkin', skin = skin })
    -- Decided here, not in the thread: two calls a moment apart (the start and a character loading)
    -- must not both think the skin changed.
    local changed = skin ~= skinNow
    skinNow = skin
    CreateThread(function()
        local black = skin == 'black'
        -- GTA's radar is up only for the tuner (/radardebug: whip's own minimap is everyone else's), so its frame and
        -- its dark tiles (six 4096 textures) are loaded only then. The page's gauges line up under where the frame
        -- would be either way: keepBoxSent tells it.
        local tuner = RadarDebugOpen == true
        if black and tuner then
            local shape = MASK_CORNERS[Config.MinimapMask] and Config.MinimapMask or 'rounded'
            LoadTextureDict(FRAME_DICT .. shape, 5000)
        end
        if skinNow ~= skin then return end   -- changed again while the dictionary loaded
        local shown = black and (loaded == true or PlayerLoaded == true)
        local border = PlayerPrefs.get('map.border') ~= false
        holdFrame(shown and border and tuner)
        keepBoxSent(shown and not (border and tuner))
        if changed then blueRoute(black) end
        swapMap(black and tuner)   -- (no change, nothing done)
    end)
end

--- The tuner opened or closed (client/radar_debug.lua): GTA's radar dressing on or off with it.
function HudSkinTunerChanged() applySkin() end

-- The border is each player's own: map.border, declared by client/minimap.lua (the pause menu's Settings → Server
-- → Minimap), whose minimap draws it. This file's game-drawn frame is only for /radardebug, where GTA's radar is up, and
-- is drawn for any border but none.

-- The black behind the map (RING_DICT, above): each player's own, from solid (100%, the look as it was) to none (0%,
-- GTA's see-through radar). Drawn only with the border. Never shown now: whip's own minimap (client/minimap.lua) is
-- solid, and GTA's radar is up only for /radardebug, where the frame is drawn solid anyway.
PlayerPrefs.define({
    key = 'map.background', group = 'Map & HUD', type = 'slider', label = 'Map background',
    help = 'How solid the black behind the minimap is. Lower lets the world show through the map, as GTA\'s own does.',
    min = 0, max = 100, step = 5, unit = '%', default = 100,
    visible = function() return false end,
})

local function readFill()
    local pct = tonumber(PlayerPrefs.get('map.background')) or 100
    fillAlpha = math.floor(math.max(0, math.min(100, pct)) / 100 * 255 + 0.5)
    layers = nil   -- worked out again next frame, which loads the ring if it is now wanted
end
readFill()

CreateThread(function() applySkin() end)
Settings.onChange('HudSkin', function() applySkin() end)
PlayerPrefs.onChange('map.border', function() applySkin() end)
PlayerPrefs.onChange('map.background', readFill)

RegisterNetEvent('whip_core:client:playerLoaded', function()
    applySkin(true)
end)

RegisterNetEvent('whip_core:client:playerLogout', function()
    holdFrame(false)
    keepBoxSent(false)
end)

-- whip_core stopping: GTA's colour and tiles back (the ControlBlocks loop goes with the resource).
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    blueRoute(false)
    for _, t in ipairs(MAP_TILES) do RemoveReplaceTexture('minimap_sea_' .. t, 'minimap_sea_' .. t) end
end)

-- ---- seams for the radar tuner (client/radar_debug.lua) ------------------------------------------

--- The frame's box and corner scale, as shipped or as last tuned.
---@return table  { posX, posY, sizeX, sizeY, corner }
function HudSkinGetFrame()
    return { frame[1], frame[2], frame[3], frame[4], frameCorner }
end

--- Move the frame (the tuner's 'frame' row). Live; nothing is saved.
---@param r table  { posX, posY, sizeX, sizeY, corner }
function HudSkinSetFrame(r)
    frame = { r[1] + 0.0, r[2] + 0.0, r[3] + 0.0, r[4] + 0.0 }
    if r[5] then frameCorner = r[5] + 0.0 end
    layers = nil
end

--- Draw the frame on top of GTA's HUD instead of under it (the tuner's switch), for when the radar
--- turns out to be drawn before script graphics.
---@param over boolean
function HudSkinFrameOver(over)
    drawOrder = over and 4 or 1
end
