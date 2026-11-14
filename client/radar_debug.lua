-- ============================================
-- RADAR TUNER — /radardebug
-- ============================================
--
-- WHY THIS EXISTS. The minimap's geometry is six numbers per component across three components,
-- and the game applies none of them the way the names suggest: `minimap_mask` places the GPS
-- route line rather than masking anything, `minimap_blur` resizes the map, and `minimap` places
-- BOTH the map and the scaleform overlay (the compass N, the clamped waypoint arrow) on two
-- different mappings. None of that is documented anywhere, and it was reached by probing.
--
-- AND BY PROBING WRONG FIRST. The mask was written off as inert because halving it moved nothing
-- visible — with no waypoint set, there was no route on screen to move. Set a waypoint before
-- judging that component, and treat "nothing happened" as a statement about the test, not the
-- component.
--
-- Chat commands were not enough to finish the job: a nudge prints numbers but you cannot see
-- WHICH BOX moved, so "I think I'm adjusting it, but I just can't clearly tell" is the correct
-- description of tuning eighteen coupled values blind. This draws every rect on screen, gives
-- each a slider, and lets the numbers be dragged while watching the map.
--
-- IT IS A DEV TOOL AND NOT A FEATURE. It writes nothing, persists nothing, and survives no
-- reconnect. The deliverable is the table it prints — paste that into radarRects in
-- client/hud.lua and the tool has done its job.

--- Read by hud.lua's radarShouldShow so the radar stays up while the tuner is open. Global,
--- because hud.lua loads first and reads it as a global exactly like ActivePanels.
RadarDebugOpen = false

--- Every component the game exposes through SetMinimapComponentPosition, from the <minimap>
--- block of common:/data/ui/frontend.xml. The first three are the ones whip sets; the rest are
--- here because the compass hunt has already disproved two confident theories, and the next
--- one might live in a component nobody thinks to try.
---
--- Values are this file's own working copy — the tuner starts from whatever hud.lua shipped
--- and diverges freely. STOCK is the game's default, for the reset button and for the
--- components whip does not otherwise touch.
local COMPONENTS = {
    { key = 'minimap',       label = 'minimap',       note = 'map render + scaleform (N, waypoint)' },
    { key = 'minimap_mask',  label = 'minimap_mask',  note = 'the GPS route line — set a waypoint to see it' },
    { key = 'minimap_blur',  label = 'minimap_blur',  note = 'resizes the map, leaves the N alone' },
    { key = 'bigmap',        label = 'bigmap',        note = 'the expanded map (hold the toggle)' },
    { key = 'bigmap_mask',   label = 'bigmap_mask',   note = '' },
    { key = 'bigmap_blur',   label = 'bigmap_blur',   note = '' },
    { key = 'golf_courses',  label = 'golf_courses',  note = 'unused by whip; probe fodder' },
    -- NOT A GAME COMPONENT: the black skin's frame round the map (client/hud_skin.lua), in the same
    -- terms, plus a scale on its corners (1 = the mask's own). Only drawn while Config.HudSkin is 'black'.
    { key = 'frame',         label = 'frame (black skin)', note = 'the map\'s white border: line it up with the map\'s edge' },
}

--- posX, posY, sizeX, sizeY, alignX, alignY — the stock frontend.xml values.
local STOCK = {
    minimap      = { -0.0045, -0.022,    0.210,  0.258888,    'L', 'B' },
    minimap_mask = {  0.000,   0.032,    0.101,  0.259,       'L', 'B' },
    minimap_blur = {  0.012,   0.022,    0.256,  0.337,       'L', 'B' },
    bigmap       = { -0.003975, 0.022,   0.364,  0.460416666, 'L', 'B' },
    bigmap_mask  = {  0.145,   0.015,    0.176,  0.395,       'L', 'B' },
    bigmap_blur  = { -0.019,   0.022,    0.262,  0.464,       'L', 'B' },
    golf_courses = {  0.003,  -0.038,    0.27375, 0.347,      'L', 'B' },
    -- GTA has no frame; its "stock" is whip's own (client/hud_skin.lua).
    frame        = {  0.0060,  0.0700,   0.1720,  0.1655,     'L', 'B', 1.0 },
}

--- The live working set. Seeded from whip's shipped values where they exist, stock otherwise.
local rects = {}

--- Which rects to outline on screen. Keyed by component, so several can be shown at once —
--- seeing minimap and minimap_blur together is what makes their relationship legible.
local outlines = {}

--- Extra switches that are not rects. Kept beside them because "every possible setting" was the
--- ask, and because a tuning session that cannot toggle the health bars back on cannot tell
--- whether the scaleform moved.
local opts = {
    showOutlines  = true,
    radarZoom     = 0,      -- 0 = leave the game's own zoom alone
    clipType      = -1,     -- -1 = do not call SetMinimapClipType at all
    bigmapOn      = false,
    hideBars      = true,
    maskShape     = Config.MinimapMask or false,
    frameOver     = false,  -- the black skin's frame drawn over GTA's HUD instead of under it
}

-- ============================================
-- Applying
-- ============================================

--- Has the working set been filled in yet this session?
---
--- THE TUNING SURVIVES CLOSING THE PANEL. It did not at first: the command re-seeded from
--- hud.lua on every open, so stepping out to move the camera and stepping back in threw the
--- session away — "every time I exit to move the camera around, it resets it, which undoes my
--- work". Closing is not abandoning; it is looking at the thing from somewhere else.
---
--- Only two things refill it now: the first open after a resource start, and the reset buttons,
--- which is what they are for.
local seeded = false

local function SeedFromShipped()
    for _, c in ipairs(COMPONENTS) do
        local s = STOCK[c.key]
        local live = RadarGetShippedRect and RadarGetShippedRect(c.key)
        if c.key == 'frame' then
            local f = HudSkinGetFrame and HudSkinGetFrame() or s
            rects.frame = { f[1], f[2], f[3], f[4], 'L', 'B', f[5] or s[7] }
        elseif live then
            rects[c.key] = { live[1], live[2], live[3], live[4], 'L', 'B' }
        else
            rects[c.key] = { s[1], s[2], s[3], s[4], s[5], s[6] }
        end
    end

    -- The switches seed from whip too, for the same reason the rects do: a panel that opens
    -- reading -1 while the game is running 0 is a panel that lies about the thing being tuned.
    if RadarGetShippedClipType then opts.clipType = RadarGetShippedClipType() end
end

--- Push every rect at the game and force the rebuild that makes them take.
---
--- THE REBUILD IS THE SLOW PART, so it is debounced: a slider drag fires dozens of updates a
--- second and each one would otherwise flick bigmap on and off, which looks like a strobe and
--- drowns the thing being looked at. Values are applied immediately; the rebuild follows once
--- the drag settles.
local rebuildPending = false
local function ApplyAll(rebuild)
    for _, c in ipairs(COMPONENTS) do
        local r = rects[c.key]
        if r and c.key == 'frame' then
            if HudSkinSetFrame then HudSkinSetFrame({ r[1], r[2], r[3], r[4], r[7] }) end
        elseif r then
            SetMinimapComponentPosition(c.key, r[5], r[6], r[1], r[2], r[3], r[4])
        end
    end
    if HudSkinFrameOver then HudSkinFrameOver(opts.frameOver == true) end

    if opts.radarZoom and opts.radarZoom > 0 then SetRadarZoom(math.floor(opts.radarZoom)) end
    if opts.clipType and opts.clipType >= 0 then SetMinimapClipType(math.floor(opts.clipType)) end

    if rebuild == false or rebuildPending then return end
    rebuildPending = true
    CreateThread(function()
        Wait(180)               -- debounce window; a drag coalesces into one rebuild
        rebuildPending = false
        SetRadarBigmapEnabled(true, false)
        Wait(50)
        SetRadarBigmapEnabled(opts.bigmapOn, false)
        Wait(0)
        if opts.hideBars and HideMinimapHealthArmourPublic then HideMinimapHealthArmourPublic() end
    end)
end

-- ============================================
-- Outlines
-- ============================================
--
-- WHAT THIS DRAWS, AND WHAT IT CANNOT. The game's own mapping from these normalised values to
-- screen pixels is not public — it involves the safe zone and an aspect correction nobody has
-- written down. This uses the straightforward reading: posX is the left edge, posY is the
-- offset UP from the bottom, sizes are fractions of the screen.
--
-- So treat the boxes as a REFERENCE, not as truth: their value is showing which rect moves when
-- a slider moves and how the three relate to each other, which is exactly the thing that was
-- impossible to see. Where a box sits relative to the real map is itself information — a
-- consistent offset between box and map IS the aspect correction, made visible.

local OUTLINE_COLOURS = {
    minimap      = { 96, 165, 250 },    -- Signal Blue
    minimap_mask = { 74, 222, 128 },
    minimap_blur = { 251, 191, 36 },
    bigmap       = { 248, 113, 113 },
    bigmap_mask  = { 167, 139, 250 },
    bigmap_blur  = { 56, 189, 248 },
    golf_courses = { 255, 255, 255 },
    frame        = { 244, 114, 182 },
}

local function DrawOutline(r, col)
    local x, w = r[1], r[3]
    local h = r[4]
    -- posY is measured up from the bottom, DrawRect's Y runs down from the top.
    local bottom = 1.0 - r[2]
    local top = bottom - h
    local t = 0.0015                 -- line thickness in screen fractions

    local cr, cg, cb = col[1], col[2], col[3]
    DrawRect(x + w / 2, top,          w, t, cr, cg, cb, 200)   -- top
    DrawRect(x + w / 2, bottom,       w, t, cr, cg, cb, 200)   -- bottom
    DrawRect(x,         top + h / 2,  t * 0.56, h, cr, cg, cb, 200)   -- left
    DrawRect(x + w,     top + h / 2,  t * 0.56, h, cr, cg, cb, 200)   -- right
end

--- Fallback outline colour, allocated once (a literal in a draw loop allocates every frame).
local OUTLINE_FALLBACK = { 255, 255, 255 }

--- True while the draw thread below is alive, so opening twice does not start two of them.
---
--- Separate from RadarDebugOpen (the tool's state, which hud.lua reads): this one is the thread's.
local outlineThreadRunning = false

--- Born with the panel and gone with it: a thread costs its wake whatever its body does, so nothing
--- ticks on a client that has never run /radardebug.
local function StartOutlineThread()
    if outlineThreadRunning then return end
    outlineThreadRunning = true

    CreateThread(function()
        while RadarDebugOpen do
            if opts.showOutlines then
                for key, on in pairs(outlines) do
                    if on and rects[key] then
                        DrawOutline(rects[key], OUTLINE_COLOURS[key] or OUTLINE_FALLBACK)
                    end
                end
                Wait(0)
            else
                -- Open, but outlines switched off from the panel. Still cheap, and still only
                -- while somebody has the tuner up.
                Wait(250)
            end
        end

        outlineThreadRunning = false
    end)
end

-- ============================================
-- Open / close
-- ============================================

local function BuildPayload()
    local comps = {}
    for i, c in ipairs(COMPONENTS) do
        local r = rects[c.key]
        comps[i] = {
            key = c.key, label = c.label, note = c.note,
            posX = r[1], posY = r[2], sizeX = r[3], sizeY = r[4],
            alignX = r[5], alignY = r[6],
            outline = outlines[c.key] and true or false,
            colour = OUTLINE_COLOURS[c.key],
            managed = (c.key == 'minimap' or c.key == 'minimap_mask' or c.key == 'minimap_blur' or c.key == 'frame'),
        }
        if c.key == 'frame' then
            -- whip's own: a corner scale as well, and always anchored left and bottom
            comps[i].corner = r[7]
            comps[i].fields = { 'posX', 'posY', 'sizeX', 'sizeY', 'corner' }
            comps[i].noAlign = true
        end
    end
    return { components = comps, opts = opts }
end

local function OpenTuner()
    if RadarDebugOpen then return end
    RadarDebugOpen = true
    -- AFTER the flag, because the thread's own loop condition is that flag — starting it first
    -- would have it read false and exit immediately.
    StartOutlineThread()
    Focus.take('radarDebug', { screen = true })
    SendNUIMessage({ action = 'radarDebugOpen', data = BuildPayload() })
    if HudSkinTunerChanged then HudSkinTunerChanged() end   -- the black skin's frame and dark tiles, for GTA's radar
end

local function CloseTuner()
    if not RadarDebugOpen then return end
    -- The draw thread's loop condition is this flag, so clearing it is also how the thread is
    -- stopped — it exits on its next wake and clears outlineThreadRunning on the way out. Nothing
    -- here has to know the thread exists.
    RadarDebugOpen = false
    Focus.release('radarDebug')
    SendNUIMessage({ action = 'radarDebugClose' })
    if HudSkinTunerChanged then HudSkinTunerChanged() end   -- and given back
end

RegisterCommand('radardebug', function()
    if RadarDebugOpen then
        -- Closing changes NOTHING about the radar. The rects stay applied, the working set
        -- stays in memory, and re-opening picks up exactly where it left off. The only thing
        -- that goes is the panel and its mouse focus.
        CloseTuner()
        return
    end

    if not seeded then
        SeedFromShipped()
        seeded = true
    end
    OpenTuner()
    ApplyAll(true)
end, false)

-- ============================================
-- NUI callbacks
-- ============================================

RegisterNUICallback('radarDebugSet', function(data, cb)
    local r = data and data.key and rects[data.key]
    if r then
        if data.posX   then r[1] = data.posX + 0.0 end
        if data.posY   then r[2] = data.posY + 0.0 end
        if data.sizeX  then r[3] = data.sizeX + 0.0 end
        if data.sizeY  then r[4] = data.sizeY + 0.0 end
        if data.alignX then r[5] = data.alignX end
        if data.alignY then r[6] = data.alignY end
        if data.corner and data.key == 'frame' then r[7] = data.corner + 0.0 end
        ApplyAll(data.rebuild ~= false)
    end
    cb('ok')
end)

RegisterNUICallback('radarDebugOutline', function(data, cb)
    if data and data.key then outlines[data.key] = data.on and true or false end
    cb('ok')
end)

RegisterNUICallback('radarDebugOpt', function(data, cb)
    if data and data.name ~= nil then
        opts[data.name] = data.value
        if data.name == 'maskShape' then
            -- Re-running the swap needs the dict for the NEW shape; ApplyMinimapMask reads
            -- Config, so the config value is what it keys off.
            Config.MinimapMask = data.value
            if ApplyMinimapMaskPublic then ApplyMinimapMaskPublic() end
        end
        ApplyAll(true)
    end
    cb('ok')
end)

--- Reset, to one of two baselines.
---
--- 'config' IS THE DEFAULT AND THE USEFUL ONE: whip's own shipped values, straight out of
--- radarRects in client/hud.lua. That is the "known good" a tuning session wants to get back
--- to after wandering — the point it left from. The button first reset to GTA's vanilla
--- frontend.xml instead, which threw away the tuned position and was never what anyone meant
--- by "reset".
---
--- 'stock' keeps vanilla reachable, because it is a real diagnostic rather than a mistake:
--- if the compass aligns at vanilla values and nowhere else, that says the scaleform ignores
--- the overrides entirely, and that is worth being able to check in one click.
RegisterNUICallback('radarDebugReset', function(data, cb)
    if data and data.mode == 'stock' then
        for _, c in ipairs(COMPONENTS) do
            local s = STOCK[c.key]
            rects[c.key] = { s[1], s[2], s[3], s[4], s[5], s[6], s[7] }
        end
        -- Back to "never call the native" as well. Vanilla is the diagnostic where whip asserts
        -- nothing, and leaving whip's clip type asserted would make it a half-vanilla test.
        --
        -- CAVEAT: this stops RE-asserting, it cannot UN-assert. A clip type already pushed at
        -- the game this session stays until something overwrites it, and there is no "what was
        -- it before" to restore — the native is write-only. Harmless while whip ships 0, which
        -- is the default anyway; if a session has been dragging that slider, restart the
        -- resource before trusting a vanilla comparison.
        opts.clipType = -1
    else
        -- Re-reads hud.lua's live table, so this also picks up anything /radar changed in the
        -- same session rather than snapshotting at open.
        SeedFromShipped()
    end
    ApplyAll(true)
    SendNUIMessage({ action = 'radarDebugOpen', data = BuildPayload() })
    cb('ok')
end)

RegisterNUICallback('radarDebugPrint', function(_, cb)
    print('[whip_core:radardebug] radarRects = {')
    for _, key in ipairs({ 'minimap', 'minimap_mask', 'minimap_blur' }) do
        local r = rects[key]
        print(('    %-13s = { %8.4f, %8.4f, %8.4f, %8.4f },'):format(key, r[1], r[2], r[3], r[4]))
    end
    print('}')
    print('[whip_core:radardebug] -- non-default extras, if any:')
    for _, key in ipairs({ 'bigmap', 'bigmap_mask', 'bigmap_blur', 'golf_courses' }) do
        local r, s = rects[key], STOCK[key]
        if r[1] ~= s[1] or r[2] ~= s[2] or r[3] ~= s[3] or r[4] ~= s[4] then
            print(('    %-13s = { %8.4f, %8.4f, %8.4f, %8.4f },'):format(key, r[1], r[2], r[3], r[4]))
        end
    end

    -- The switches are printed too: if the tuner can change it, the print has to say so.
    print('[whip_core:radardebug] -- switches (their off values are noted, not their stock ones):')
    print(('    clipType   = %d   -- -1 = never call SetMinimapClipType; 0+ = assert that type')
        :format(opts.clipType))
    print(('    radarZoom  = %d   -- 0 = leave the game zoom alone'):format(opts.radarZoom))
    print(('    maskShape  = %s   -- false = the game texture, no replacement')
        :format(tostring(opts.maskShape)))
    print(('    hideBars   = %s   -- whip hides the scaleform health/armour bars')
        :format(tostring(opts.hideBars)))

    -- The black skin's frame: paste into client/hud_skin.lua (frame, frameCorner).
    local f = rects.frame
    if f then
        print('[whip_core:radardebug] -- the black skin\'s frame (client/hud_skin.lua):')
        print(('    local frame = { %.4f, %.4f, %.4f, %.4f }'):format(f[1], f[2], f[3], f[4]))
        print(('    local frameCorner = %.2f'):format(f[7] or 1))
        -- The box is at the safe zone's full size: hud_skin.lua adds this player's margin when it draws.
        print(('    -- (this player\'s safe zone: %.3f, so %.4f was added to posX and posY on screen)')
            :format(GetSafeZoneSize(), (1.0 - GetSafeZoneSize()) / 2))
        print(('    frameOver  = %s   -- true: drawn over GTA\'s HUD (the radar was drawn first)')
            :format(tostring(opts.frameOver)))
    end
    cb('ok')
end)

RegisterNUICallback('radarDebugClose', function(_, cb)
    CloseTuner()
    cb('ok')
end)
