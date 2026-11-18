-- The Configurator's in-world modes (drawing a property's space, picking its doors, placing its sign, checking what
-- was built). Every mode follows the same rules so none can strand an admin:
--   the /whip panel is suspended (hidden, focus released) for the mode and resumed after it
--   the editor HUD (tools/editor_hud.lua) says what the mode is and which keys do what
--   Esc leaves the mode (a mode may ask first, if leaving would lose something)
--   death, a resource stop, or another mode starting all end it the same way
--   ZonePreview keys starting 'pe:' belong to the mode and are cleared with it
-- PropertyEditorActive is true while one runs; the furnisher reads it so nothing else claims the camera or E.
--
--   PropertyEditor.start({
--       name     = 'Show space',
--       hud      = { title = ..., rows = ..., hints = ... },   -- EditorHud.show
--       solo     = 'group',        -- optional: Interactions.setSolo for the mode's own prompts
--       block    = { controls = { 24, 25 } },   -- optional: held off for the mode (ControlBlocks), never by hand
--       padBack  = true,           -- optional: B on a pad leaves too, as Esc does (a mode with nothing else on B)
--       prompts  = true,           -- optional: the world's prompts stay up and usable under the mode (it reads
--                                  -- neither E/A nor the scroll wheel: the throw test, where piles are picked up)
--       onFrame  = function() end, -- every frame; return 'exit' to finish
--       onEscape = function() end, -- optional; return false to stay in the mode
--       onExit   = function(reason) end,  -- 'done' | 'back' | 'died' | 'replaced' | 'error' | 'stopped'
--   })

PropertyEditorActive = false
PropertyEditor = {}

local mode = nil
local startLoop   -- the mode's frame loop, started by PropertyEditor.start; defined below

-- A `padBack` mode's B is the way out: B on foot is also melee and reload, held off so the press that leaves does
-- not throw a punch as well.
local PAD_BACK_BLOCK = { controls = { 45, 140, 141, 142 } }

local function finish(reason)
    local m = mode
    if not m then return end
    mode = nil
    PropertyEditorActive = false
    ControlBlocks.release('propEditMode')   -- the mode's own `block` (fine when it named none)
    ControlBlocks.release('propEditBack')
    ZonePreview.clearPrefix('pe:')
    EditorHud.hide()
    if m.solo and Interactions then Interactions.setSolo(nil) end
    if m.onExit then
        local ok, err = pcall(m.onExit, reason)
        if not ok then print('[whip_core:propedit] onExit errored: ' .. tostring(err)) end
    end
    if reason ~= 'stopped' then WhipPanelResume() end
end

---@param m table  see the header
function PropertyEditor.start(m)
    if mode then finish('replaced') end
    if FurnishModeActive then
        UI.Notify('Close the furnisher first', 'error')
        return false
    end
    mode = m
    PropertyEditorActive = true
    -- The controls the mode holds off, through the one control loop (so /whipcontrols and heldByOthers see
    -- them).
    if type(m.block) == 'table' then ControlBlocks.hold('propEditMode', m.block) end
    if m.padBack then ControlBlocks.hold('propEditBack', PAD_BACK_BLOCK) end
    WhipPanelSuspend()
    if m.solo and Interactions then Interactions.setSolo(m.solo) end
    EditorHud.show(m.hud or { title = m.name or 'Property' })
    startLoop()
    return true
end

function PropertyEditor.stop(reason)
    finish(reason or 'done')
end

function PropertyEditor.isActive()
    return mode ~= nil
end

--- Does the running mode leave the world's prompts up (`prompts = true`)? IsGameInputFree asks it for the prompts.
function PropertyEditor.promptsUp()
    return mode ~= nil and mode.prompts == true
end

--- Started with a mode, ended when none is left.
local loopRunning = false

local function run()
    while true do
        if not mode then
            break
        elseif PlayerIsDead then
            finish('died')
            Wait(0)
        else
            if IsDisabledControlJustPressed(0, 200) or (mode.padBack and WhipKeyPressed(nil, 202)) then
                local stay = mode.onEscape and mode.onEscape() == false
                if not stay then finish('back') end
            elseif mode.onFrame then
                local ok, res = pcall(mode.onFrame)
                if not ok then
                    print('[whip_core:propedit] mode "' .. tostring(mode and mode.name) .. '" errored: ' .. tostring(res))
                    finish('error')
                elseif res == 'exit' then
                    finish('done')
                end
            end
            Wait(0)
        end
    end
end

local function loop()
    -- ESC is the way out. Named in a control block, so the pause menu leaves it to the mode (disabling
    -- it here does not stop the pause keys reading it). Let go however the loop ends:
    -- a block left held would keep the pause menu off Esc for good.
    ControlBlocks.hold('propEdit', { controls = { 200 } })
    local ok, err = pcall(run)
    if not ok then
        print('[whip_core:propedit] the mode loop failed: ' .. tostring(err))
        if mode then pcall(finish, 'error') end
    end
    ControlBlocks.release('propEdit')
    loopRunning = false
end

startLoop = function()
    if loopRunning then return end
    loopRunning = true
    CreateThread(loop)
end

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if mode then finish('stopped') end
end)

-- ============================================
-- Place a sign
-- ============================================
--
-- AIM IT, DO NOT STAND ON IT. A sign goes on a wall, at a height, at an angle, and the only thing
-- that knows where the wall is is a ray from the camera — so this is housing's entry placer again:
-- a live preview on the end of the ray, facing you, Q / E turning it off that, Enter to put it
-- there and C or Esc to leave it where it was. The sign post's keys and card, a controller's when one is in hand.
--
-- THE PREVIEW IS THE REAL PROMPT, drawn by whichever renderer is live and the only prompt on
-- screen (setSolo), so what you see while aiming is the sign itself, at its real size, edge-on
-- when you are beside it.

local SIGN_GROUP = 'pe_sign'
local SIGN_PREVIEW = 'pe_sign_preview'
local SIGN_LIFT = 0.05          -- off the surface, so the badge does not z-fight the wall
local SIGN_TURN = 60.0          -- degrees a second: Q / E, or a trigger all the way down (the sign post's)
local SIGN_TURN_FINE = 15.0     -- with Alt
-- On a pad, held while it places: Menu (named, so the pause menu stands aside), X's jump, Y's get-in.
local SIGN_PAD_BLOCK = { controls = { 199, 22, 23 } }

--- Aim a sign and hand the spot back: the one placing mode, for a saved property (placeSign,
--- below) and for the wizard's draft alike.
---
---   opts = { name = 'Mega B 805', what = 'Outside sign' | 'Manager', forText = 'this property',
---            start = { x, y, z, heading } | nil, onPlaced = function(x, y, z, heading) end,
---            icon = 'house' (the preview's glyph) }
---@return boolean started
function PropertyEditor.aimSign(opts)
    if not Interactions then return false end
    local reach = Config.PropertySignPlaceRange or 12.0
    local start = opts.start or {}
    local ped = GetEntityCoords(PlayerPedId())
    local x, y, z = start.x or ped.x, start.y or ped.y, start.z or ped.z
    local heading = start.heading or 0.0
    local valid, turn = false, 0.0
    local what = opts.what or 'Sign'
    local scopeText = opts.forText or 'this property'
    local name = opts.name or 'Property'
    local pad, padHeld = false, false

    local function card()
        return {
            house = true, icon = 'place', title = what, sub = name,
            rows = {
                { label = 'For', value = scopeText },
                { label = 'Aim', value = valid and ('facing %.0f°'):format(heading) or 'at a wall or the floor',
                  tone = not valid and 'warn' or nil },
            },
            hints = {
                { key = 'Enter', pad = 'a', text = 'Put it here', off = not valid },
                { key = 'Q / E', pad = { 'lt', 'rt' }, text = 'Turn it' },
                { key = 'Alt', pad = false, text = 'Turn slowly' },
                { key = 'C', pad = 'b', text = 'Cancel' },
            },
        }
    end

    local function holdPad(on)
        if on == padHeld then return end
        padHeld = on
        if on then ControlBlocks.hold('placeSignPad', SIGN_PAD_BLOCK) else ControlBlocks.release('placeSignPad') end
    end
    -- A press on the device in hand only: a pad's buttons are keys on a keyboard too, and the reverse.
    local pressed = WhipKeyPressed

    local started = PropertyEditor.start({
        name = 'Place sign',
        solo = SIGN_GROUP,
        hud = card(),
        onExit = function()
            holdPad(false)
            Interactions.remove(SIGN_PREVIEW)
        end,
        -- What is read, held off so it does not also fire underneath: the wheel, attack and aim (a pad's
        -- triggers), cover, Q / E (44, 38), melee, Enter (201, 18), Alt (19). C (26) too.
        block = { controls = { 14, 15, 16, 17, 24, 25, 26, 37, 38, 44, 140, 141, 142, 201, 18, 19, 257, 263, 264 } },
        onFrame = (function()
            local nextHud, lastValid = 0, nil
            return function()
                pad = WhipLastInputIsPad()
                holdPad(pad)
                local dt = GetFrameTime()

                -- Turn it off facing you: Q / E held, or the triggers.
                if pad then
                    local t = WhipPadTrigger('rt') - WhipPadTrigger('lt')   -- RT turns it right, LT left
                    if t ~= 0.0 then turn = (turn - t * SIGN_TURN * dt) % 360.0 end
                else
                    local rate = IsDisabledControlPressed(0, 19) and SIGN_TURN_FINE or SIGN_TURN
                    if IsDisabledControlPressed(0, 44) then turn = (turn + rate * dt) % 360.0
                    elseif IsDisabledControlPressed(0, 38) then turn = (turn - rate * dt) % 360.0 end
                end

                local cam = GetFinalRenderedCamCoord()
                local fx, fy, fz = InteractGetCameraForward()
                local ray = StartShapeTestRay(cam.x, cam.y, cam.z, cam.x + fx * reach, cam.y + fy * reach,
                    cam.z + fz * reach, 1 + 16, PlayerPedId(), 0)
                local _, hit, coords, normal = GetShapeTestResult(ray)
                valid = hit == 1
                if valid then
                    local n = normal or vector3(0.0, 0.0, 1.0)
                    x, y, z = coords.x + n.x * SIGN_LIFT, coords.y + n.y * SIGN_LIFT, coords.z + n.z * SIGN_LIFT
                    -- Facing you: GTA heading of the direction back to the camera, plus the turn.
                    local dx, dy = cam.x - x, cam.y - y
                    if dx * dx + dy * dy > 0.0001 then heading = (math.deg(math.atan(-dx, dy)) + turn) % 360.0 end
                    -- WHERE THE PROMPTS LOOK FOR IT, not only where it is drawn. `follow` (below) runs
                    -- only for a prompt already on screen, and the preview starts at your feet (or the
                    -- old spot) — off screen in first person or from across a room — so it never got
                    -- on screen and never moved: aiming at a wall showed nothing.
                    Interactions.updatePosition(SIGN_PREVIEW, x, y, z)
                    Interactions.updateHeading(SIGN_PREVIEW, heading)
                end

                if valid and (pressed(201, 201) or (not pad and IsDisabledControlJustPressed(0, 18))) then
                    if opts.onPlaced then
                        local ok, err = pcall(opts.onPlaced, x, y, z, heading)
                        if not ok then print('[whip_core:propedit] onPlaced errored: ' .. tostring(err)) end
                    end
                    return 'exit'
                end
                -- C / B: leave it where it was. Menu on a pad too (Esc is the mode's own).
                if WhipCancelJustPressed() or (pad and pressed(199, 199)) then return 'exit' end

                -- The card: at once when the aim finds or loses a surface, else five times a second.
                local now = GetGameTimer()
                if valid ~= lastValid then nextHud = 0 end
                lastValid = valid
                if now >= nextHud then
                    nextHud = now + 200
                    EditorHud.update(card())
                end
            end
        end)(),
    })
    if not started then return false end

    Interactions.register({
        id = SIGN_PREVIEW,
        x = x, y = y, z = z,
        group = SIGN_GROUP,
        icon = opts.icon or 'house',
        label = name .. '  —  ' .. what:lower(),
        -- Live: the mode's frame writes these, the renderer reads them.
        follow = function() return x, y, z, heading end,
        -- Ranged wide so it can be aimed from where it will be read, drawn at the real prompt's size.
        visibleRange = reach + 2.0,
        activeRange = reach + 2.0,
        sizeRange = Config.InteractActiveRange or 3.0,
        condition = function() return PropertyEditor.isActive() end,
    })
    return true
end

--- Move a saved property's sign: aim it, and the server stores it.
---@param p table          a property as client/properties.lua holds it
---@param which string     'sign' (outside) | 'manager' (inside)
---@param scope string     'property' | 'unit'
---@param uses number|nil  how many properties share its unit, for the HUD
function PropertyEditor.placeSign(p, which, scope, uses)
    if not p then return false end
    local current = p[which] or (which == 'manager' and p.sign) or nil
    return PropertyEditor.aimSign({
        name = p.name or ('Property #' .. tostring(p.id)),
        what = which == 'sign' and 'Outside sign' or 'Manager',
        forText = (scope == 'unit' and (uses or 1) > 1) and ('all %d properties on this unit'):format(uses)
            or (p.name or 'this property'),
        start = current or { x = p.x, y = p.y, z = p.z },
        onPlaced = function(x, y, z, heading)
            TriggerServerEvent('whip_core:server:propertyAdminSetSign', p.id, which, scope, x, y, z, heading)
        end,
    })
end

-- ============================================
-- Put up a sign post
-- ============================================
--
-- THE OUTSIDE SIGN ON A POST: the prompt goes at a set spot on the board, so it is right every time. Aim at the ground and a see-through post stands there with its board facing
-- you, and the for-sale prompt on the board's panel: the real prompt, where it will be. What goes back to the caller
-- is the PROMPT's spot and the post's model, as every outside sign is stored (shared/property_math.lua, Sign posts).
--
-- On the house card, with a controller (the house rules: the device in hand only):
--
--     put it here                  Enter    A
--     turn it                      Q / E    LT / RT     (Alt slowly)
--     the next sign post           X        X
--     leave it as it was           C        B           (Esc or Menu: the same)

local POST_PREVIEW   = 'pe_post_preview'
local POST_TURN      = 60.0    -- degrees a second: Q / E, or a trigger all the way down
local POST_TURN_FINE = 15.0    -- with Alt
local POST_ALPHA     = 170     -- the see-through post
local POST_LOAD_MS   = 5000    -- a model not loaded by then is said to be missing
-- On a pad, held while it is in hand: Menu (named, so the pause menu stands aside), X's jump, Y's get-in.
local POST_PAD_BLOCK = { controls = { 199, 22, 23 } }

--- Put up a sign post and hand the prompt's spot back.
---
---   opts = { name = 'Mega B 805', forText = 'this property',
---            model = 'whip_forsale_timber' | nil,        -- the post to start with (the first listed otherwise)
---            heading = n | nil,                          -- the post's heading to start with (Move): kept relative
---                                                           to you as you first aim, then turned from there
---            listing = { name, bays, rooms, price } | nil,   -- what its board will say (PropertyListing): shown
---                                                           printed on the see-through post as you aim
---            onPlaced = function(model, x, y, z, heading) end }   -- the prompt's spot, on the post's panel
---@return boolean started
function PropertyEditor.placeSignPost(opts)
    if not Interactions then return false end
    -- The ones the rest of whip knows them by (PropertyMath.signPost): a model listed twice counts once.
    local posts = {}
    for _, p in ipairs(Config.PropertySignPosts or {}) do
        if type(p) == 'table' and PropertyMath.signPost(p.model) == p then posts[#posts + 1] = p end
    end
    if #posts == 0 then
        UI.Notify('There are no sign posts set up (Config.PropertySignPosts)', 'error')
        return false
    end
    local reach = Config.PropertySignPlaceRange or 12.0
    local at = 1
    for i, p in ipairs(posts) do if p.model == opts.model then at = i end end

    local x, y, z, heading, valid = 0.0, 0.0, 0.0, 0.0, false
    local px, py, pz, ph = 0.0, 0.0, 0.0, 0.0          -- the prompt's spot, as stored: the panel's middle
    local cx, cy, cz, ch = 0.0, 0.0, 0.0, 0.0          -- where its control ("More…") stands on the board
    local cfit = {}                                    -- and the box it stays inside there
    local listing = opts.listing or { name = opts.name }
    local turn, startHeading = 0.0, tonumber(opts.heading)
    local ghost, ghostModel, loadingSince = nil, nil, nil
    local pad, padHeld = false, false

    local function dropGhost()
        if ghost and DoesEntityExist(ghost) then DeleteEntity(ghost) end
        ghost, ghostModel = nil, nil
    end

    -- The see-through post, the one picked. Its model is asked for and the post made once it is in, a frame at a
    -- time: a frame never waits.
    local function ensureGhost()
        local want = posts[at].model
        if ghost and ghostModel == want then return end
        dropGhost()
        local hash = GetHashKey(want)
        if not IsModelInCdimage(hash) then
            if not loadingSince then
                loadingSince = -1
                EditorHud.status(('%s is not in the game: is it streamed?'):format(want), 'err')
            end
            return
        end
        if not HasModelLoaded(hash) then
            RequestModel(hash)
            loadingSince = loadingSince or GetGameTimer()
            if loadingSince > 0 and GetGameTimer() - loadingSince > POST_LOAD_MS then
                loadingSince = -1
                EditorHud.status(('%s did not load'):format(want), 'err')
            end
            return
        end
        loadingSince = nil
        ghost = CreateObjectNoOffset(hash, x, y, z, false, false, false)
        SetModelAsNoLongerNeeded(hash)
        if not ghost or ghost == 0 then ghost = nil return end
        ghostModel = want
        SetEntityAlpha(ghost, POST_ALPHA, false)
        SetEntityCollision(ghost, false, false)
        FreezeEntityPosition(ghost, true)
    end

    local function card()
        local p = posts[at]
        return {
            house = true, icon = 'house', title = 'Sign post', sub = opts.name or 'Property',
            chip = { text = p.label or p.model },
            rows = {
                { label = 'Sign', value = #posts > 1 and ('%s  ·  %d of %d'):format(p.label or p.model, at, #posts)
                    or (p.label or p.model) },
                { label = 'For', value = opts.forText or 'this property' },
                { label = 'Aim', value = valid and ('facing %.0f°'):format(ph) or 'at flat ground',
                  tone = not valid and 'warn' or nil },
            },
            hints = {
                { key = 'Enter', pad = 'a', text = 'Put it here', off = not (valid and ghost) },
                { key = 'Q / E', pad = { 'lt', 'rt' }, text = 'Turn it' },
                { key = 'Alt', pad = false, text = 'Turn slowly' },
                { key = 'X', pad = 'x', text = 'Next sign post', off = #posts < 2 },
                { key = 'C', pad = 'b', text = 'Cancel' },
            },
        }
    end

    local function holdPad(on)
        if on == padHeld then return end
        padHeld = on
        if on then ControlBlocks.hold('placePostPad', POST_PAD_BLOCK) else ControlBlocks.release('placePostPad') end
    end
    -- A press on the device in hand only: a pad's buttons are keys on a keyboard too, and the reverse.
    local pressed = WhipKeyPressed

    local started = PropertyEditor.start({
        name = 'Sign post',
        solo = 'pe_post',
        hud = card(),
        onExit = function()
            holdPad(false)
            dropGhost()
            Interactions.remove(POST_PREVIEW)
            PropertyListing.remove(POST_PREVIEW)
        end,
        -- What is read, held off so it does not also fire underneath: the wheel, attack and aim (a pad's
        -- triggers), cover, Q / E (44, 38), reload, X (73), melee, Enter (201, 18), Alt (19). C (26) too.
        block = { controls = { 14, 15, 16, 17, 24, 25, 26, 37, 38, 44, 45, 73, 140, 141, 142, 201, 18, 19, 257, 263, 264 } },
        onFrame = (function()
            local nextHud, lastValid = 0, nil
            return function()
                pad = WhipLastInputIsPad()
                holdPad(pad)
                local dt = GetFrameTime()
                local fine = not pad and IsDisabledControlPressed(0, 19)
                local acted = false

                -- Turn it: Q / E held, or the triggers.
                if pad then
                    local t = WhipPadTrigger('rt') - WhipPadTrigger('lt')   -- RT turns it right, LT left
                    if t ~= 0.0 then turn = (turn - t * POST_TURN * dt) % 360.0 end
                else
                    local rate = fine and POST_TURN_FINE or POST_TURN
                    if IsDisabledControlPressed(0, 44) then turn = (turn + rate * dt) % 360.0
                    elseif IsDisabledControlPressed(0, 38) then turn = (turn - rate * dt) % 360.0 end
                end
                if #posts > 1 and pressed(73, 203) then
                    at = at % #posts + 1
                    loadingSince = nil
                    acted = true
                end

                -- Where the aim lands. World only: a post stands on the ground, never on a car or a prop.
                local cam = GetFinalRenderedCamCoord()
                local fx, fy, fz = InteractGetCameraForward()
                local ray = StartShapeTestRay(cam.x, cam.y, cam.z, cam.x + fx * reach, cam.y + fy * reach,
                    cam.z + fz * reach, 1, PlayerPedId(), 0)
                local _, hit, coords, normal = GetShapeTestResult(ray)
                valid = hit == 1 and normal ~= nil and normal.z >= 0.7
                if valid then
                    x, y, z = coords.x, coords.y, coords.z
                    -- Its board facing you (the board is the post's back: heading + 180 looks at you), plus the turn.
                    -- Moving one: the turn that keeps the heading it had, taken at the first aim.
                    local dx, dy = cam.x - x, cam.y - y
                    if dx * dx + dy * dy > 0.0001 then
                        local facing = math.deg(math.atan(-dx, dy)) - 180.0
                        if startHeading then
                            turn = (startHeading - facing) % 360.0
                            startHeading = nil
                        end
                        heading = (facing + turn) % 360.0
                    end
                    px, py, pz, ph = PropertyMath.postToPrompt(posts[at], x, y, z, heading)
                    cx, cy, cz, ch = PropertyListing.controls(posts[at], { x = px, y = py, z = pz, heading = ph }, 0.0, cfit)
                    -- WHERE THE PROMPTS LOOK FOR IT (as aimSign's): `follow` runs only for a prompt on screen.
                    Interactions.updatePosition(POST_PREVIEW, cx, cy, cz)
                    Interactions.updateHeading(POST_PREVIEW, ch)
                end

                ensureGhost()
                if ghost then
                    SetEntityCoordsNoOffset(ghost, x, y, z, false, false, false)
                    SetEntityHeading(ghost, heading)
                    SetEntityVisible(ghost, valid, false)
                end
                -- Its board as it will read, printed on the see-through post.
                if ghost and valid then
                    PropertyListing.set(POST_PREVIEW, ghost, posts[at], { x = px, y = py, z = pz, heading = ph }, listing)
                else
                    PropertyListing.remove(POST_PREVIEW)
                end

                if pressed(201, 201) or (not pad and IsDisabledControlJustPressed(0, 18)) then
                    if not valid then
                        EditorHud.status('Aim at flat ground first', 'warn')
                    elseif not ghost then
                        EditorHud.status('The sign post is still loading', 'warn')
                    else
                        if opts.onPlaced then
                            local ok, err = pcall(opts.onPlaced, posts[at].model, px, py, pz, ph)
                            if not ok then print('[whip_core:propedit] placeSignPost onPlaced errored: ' .. tostring(err)) end
                        end
                        return 'exit'
                    end
                end
                -- C / B: leave it as it was. Menu on a pad too (Esc is the mode's own).
                if WhipCancelJustPressed() or (pad and pressed(199, 199)) then return 'exit' end

                -- The card: at once when the post or the aim changes, else five times a second.
                local now = GetGameTimer()
                if acted or valid ~= lastValid then nextHud = 0 end
                lastValid = valid
                if now >= nextHud then
                    nextHud = now + 200
                    EditorHud.update(card())
                end
            end
        end)(),
    })
    if not started then return false end

    Interactions.register({
        id = POST_PREVIEW,
        x = x, y = y, z = z,
        group = 'pe_post',
        icon = 'info',
        label = 'More…',
        -- Live, in the board's corner: flat on it (no pull), inside its safe zone and at the board's size, as the
        -- real one is (client/properties.lua).
        follow = function() return cx, cy, cz, ch, 0.0, nil, nil, nil, cfit end,
        visibleRange = reach + 2.0,
        activeRange = reach + 2.0,
        sizeRange = Config.InteractActiveRange or 3.0,
        scale = PropertyListing.CONTROL_SCALE,
        condition = function() return PropertyEditor.isActive() and valid end,
    })
    return true
end

--- Put a saved property's outside sign on a sign post (or move its post): the server stores the prompt's spot and
--- the post (propertyAdminSetSign).
---@param p table          a property as client/properties.lua holds it
---@param scope string     'property' | 'unit'
---@param uses number|nil  how many properties share its unit, for the card
function PropertyEditor.placePropertyPost(p, scope, uses)
    if not p then return false end
    local s = type(p.sign) == 'table' and p.sign.x and p.sign or nil
    local post = s and PropertyMath.signPost(s.post)
    local postHeading = s and post and select(4, PropertyMath.promptToPost(post, s.x, s.y, s.z, s.heading or 0.0)) or nil
    return PropertyEditor.placeSignPost({
        name = p.name or ('Property #' .. tostring(p.id)),
        forText = (scope == 'unit' and (uses or 1) > 1) and ('all %d properties on this unit'):format(uses)
            or (p.name or 'this property'),
        model = post and post.model or nil,
        heading = postHeading,
        listing = { name = p.name, bays = p.bays, rooms = p.rooms, price = p.price, closed = p.active == false },
        onPlaced = function(model, x, y, z, heading)
            TriggerServerEvent('whip_core:server:propertyAdminSetSign', p.id, 'sign', scope, x, y, z, heading, model)
        end,
    })
end

-- ============================================
-- Set out garage bays
-- ============================================
--
-- THE ONE BAY TOOL. Every garage's bays are set out here:
--
--   a property's private garage   /whip → Properties → the Garage step          (tools/property_wizard.lua)
--   a new public garage           /whip → Garages → + New Garage → Bays          (tools/panel_sections/garages.lua)
--   a saved public garage         /whip → Garages → a garage → Set out bays      (the same file)
--
-- Aim at the ground and the bay outline sits there — the garage system's own (GarageBayDraw), so what is set out is
-- what a driver will see. Aim at a bay already there and it lights up: pick it up to move it, or take it away.
-- Nothing is written here: the bays go back to the caller, in the world, and the caller keeps them (the property's
-- draft, the wizard's draft, or one save for a saved garage).
--
-- On the house card, with a controller (the house rules: the device in hand only; LB + anything is LB's):
--
--     put a bay down; pick up the one aimed at; put it down again   Enter    A
--     turn it                                                       Q / E    LT / RT           (Alt slowly)
--     raise / lower it                                              ↑ / ↓    D-pad up / down   (Alt slowly)
--     take away the one aimed at, or carried                        X        X
--     done                                                          Esc      Menu
--     put a carried bay back; with none, undo this visit            C        B
--
-- The height is an offset from the ground aimed at, kept as you re-aim: a level the aim cannot land on.

local BAY_REACH      = 25.0    -- metres the aim reaches
local BAY_TURN       = 60.0    -- degrees a second: Q / E, or a trigger all the way down
local BAY_TURN_FINE  = 15.0    -- with Alt
local BAY_RAISE      = 0.35    -- metres a second
local BAY_RAISE_FINE = 0.05    -- with Alt
local BAY_RAISE_MAX  = 5.0     -- either way
local BAY_AIM_DZ     = 3.0     -- how far over or under the ground aimed at a bay may sit and still be the one aimed at
-- On a pad, held while it drives: Menu (named, so the pause menu stands aside), X's jump, Y's get-in.
local BAY_PAD_BLOCK  = { controls = { 199, 22, 23 } }

local BAY_GREEN = { 120, 255, 140 }
local BAY_WHITE = { 255, 255, 255 }
local BAY_RED   = { 255, 110, 110 }

--- The bay whose outline a point is inside (its length along its heading, its width across; the nearest if several):
--- the one aimed at. The outline's size is the helper's (Config.GaragePositionHelper), the one drawn.
---@return number|nil index
local function bayAt(bays, px, py, pz)
    local c = Config.GaragePositionHelper or {}
    local halfW, halfL = (c.width or 2.60) / 2.0, (c.length or 5.20) / 2.0
    local best, bestSq = nil, nil
    for i, b in ipairs(bays) do
        if math.abs(pz - b.z) <= BAY_AIM_DZ then
            local dx, dy = px - b.x, py - b.y
            local h = math.rad(b.heading)
            -- GTA headings: forward is (-sin, cos), right (cos, sin) — WorldQuad.groundBasis's.
            local along = -dx * math.sin(h) + dy * math.cos(h)
            local across = dx * math.cos(h) + dy * math.sin(h)
            if math.abs(along) <= halfL and math.abs(across) <= halfW then
                local d = dx * dx + dy * dy
                if not bestSq or d < bestSq then best, bestSq = i, d end
            end
        end
    end
    return best
end

--- Set bays out in the world.
---
---   opts = { name   = 'Pillbox Parking',                  -- the card's line under its title
---            bays   = { { x, y, z, heading, id }, ... },  -- the bays it has, in the world. `id` is the caller's (a
---                                                            saved bay's spotId), carried through a move
---            max    = 40,                                 -- how many it may have (more than that come in and stay;
---                                                            none are added)
---            min    = 1,                                  -- optional: Done refuses fewer (a saved garage: its bays
---                                                            are its only way in)
---            onDone = function(bays, undone, reason) end } -- the bays when it closes, in their order: a moved bay
---                                                            keeps its place and its id, new ones go on the end.
---                                                            `undone`: C / B put them back as they came. `reason`:
---                                                            PropertyEditor's ('done' | 'back' | 'died' | ...)
---@return boolean started
function PropertyEditor.placeBays(opts)
    local max = tonumber(opts.max) or 8
    local min = tonumber(opts.min) or 0
    local bays, hasIds = {}, false
    for _, b in ipairs(opts.bays or {}) do
        if type(b) == 'table' and tonumber(b.x) and tonumber(b.y) and tonumber(b.z) then
            bays[#bays + 1] = { x = b.x + 0.0, y = b.y + 0.0, z = b.z + 0.0,
                                heading = ((tonumber(b.heading) or 0.0) % 360.0) + 0.0, id = b.id }
            if b.id ~= nil then hasIds = true end
        end
    end
    -- As they came, for C / B. A bay is never changed in place (a move puts a new one in its slot), so the list's
    -- copy is enough.
    local before = {}
    for i, b in ipairs(bays) do before[i] = b end

    local x, y, z, valid = 0.0, 0.0, 0.0, false
    local heading = GetEntityHeading(PlayerPedId())
    local raise = 0.0          -- metres above (or below) the ground aimed at: kept as you re-aim
    local aimed = nil          -- the index of the bay aimed at (never while one is carried)
    local carry = nil          -- the bay picked up: { bay = as it was, at = its place, raise = the height dialled before }
    local pad, padHeld, undone = false, false, false

    -- What the card calls a bay: a saved one by its number, a new one among saved ones as new, else by its place.
    local function nameOf(b, i)
        if b.id ~= nil then return ('Bay #%s'):format(tostring(b.id)) end
        return hasIds and 'The new bay' or ('Bay %d'):format(i)
    end

    local function card()
        local n = #bays + (carry and 1 or 0)
        local chip
        if carry then chip = { text = 'Moving ' .. nameOf(carry.bay, carry.at):gsub('^The ', ''), tone = 'warn' }
        elseif aimed then chip = { text = nameOf(bays[aimed], aimed):gsub('^The ', '') }
        elseif n > 0 then chip = { text = ('%d bay%s'):format(n, n == 1 and '' or 's'), tone = 'ok' }
        else chip = { text = 'No bays yet' } end
        local aim
        if aimed then aim = { label = 'Aim', value = 'at ' .. nameOf(bays[aimed], aimed):lower(), tone = 'ok' }
        else aim = { label = 'Aim', value = valid and ('facing %.0f°'):format(heading) or 'at flat ground',
                     tone = not valid and 'warn' or nil } end
        return {
            house = true, icon = 'garage', title = 'Garage bays', sub = opts.name or 'Garage',
            chip = chip,
            rows = {
                { label = 'Bays', value = ('%d of %d'):format(n, max), tone = n > 0 and 'ok' or nil },
                aim,
                { label = 'Height', value = math.abs(raise) < 0.005 and 'on the ground' or ('%+.2f m'):format(raise) },
            },
            hints = {
                { key = 'Enter', pad = 'a',
                  text = carry and 'Put it down here' or aimed and 'Pick this bay up' or 'Put a bay here',
                  off = (carry and not valid) or (not carry and not aimed and (not valid or n >= max)) },
                { key = 'Q / E', pad = { 'lt', 'rt' }, text = 'Turn it', off = aimed ~= nil },
                { key = '↑ / ↓', pad = { 'dpad_up', 'dpad_down' }, text = 'Raise / lower it', off = aimed ~= nil },
                { key = 'Alt', pad = false, text = 'Turn or raise slowly', off = aimed ~= nil },
                { key = 'X', pad = 'x', text = carry and 'Take it away' or 'Take this bay away',
                  off = not carry and not aimed },
                { key = 'Esc', pad = 'menu', text = 'Done', off = n < min },
                { key = 'C', pad = 'b', text = carry and 'Put it back' or 'Undo these changes' },
            },
        }
    end

    -- A carried bay back in its place, as it was.
    local function putBack()
        if not carry then return end
        table.insert(bays, carry.at, carry.bay)
        raise = carry.raise
        carry = nil
    end

    -- Done, if it may be: never with fewer than `min`; a bay still in hand goes back where it was (in hand is not
    -- yet a decision).
    local function canFinish()
        if #bays + (carry and 1 or 0) < min then
            EditorHud.status(min == 1 and 'Leave at least one bay: bays are the only way into a garage'
                or ('Leave at least %d bays'):format(min), 'err')
            return false
        end
        putBack()
        return true
    end

    local function holdPad(on)
        if on == padHeld then return end
        padHeld = on
        if on then ControlBlocks.hold('placeBaysPad', BAY_PAD_BLOCK) else ControlBlocks.release('placeBaysPad') end
    end
    -- A press on the device in hand only: a pad's buttons are keys on a keyboard too, and the reverse.
    local pressed = WhipKeyPressed

    return PropertyEditor.start({
        name = 'Garage bays',
        solo = 'pe_bays',
        hud = card(),
        onEscape = canFinish,        -- Esc is Done: false stays
        onExit = function(reason)
            holdPad(false)
            putBack()
            if opts.onDone then
                local ok, err = pcall(opts.onDone, bays, undone, reason)
                if not ok then print('[whip_core:propedit] placeBays onDone errored: ' .. tostring(err)) end
            end
        end,
        -- What is read, held off so it does not also fire underneath: the wheel, attack and aim (a pad's
        -- triggers), cover, Q / E (44, 38), reload, X (73), melee, Enter (201, 18), Alt (19), and the arrows
        -- (172, 173: the phone's up and down). C (26) too.
        block = { controls = { 14, 15, 16, 17, 24, 25, 26, 37, 38, 44, 45, 73, 140, 141, 142, 201, 18, 19, 257, 263, 264,
                               172, 173 } },
        onFrame = (function()
            local nextHud, lastAimed, lastCarry = 0, nil, nil
            return function()
                pad = WhipLastInputIsPad()
                holdPad(pad)
                local dt = GetFrameTime()
                local fine = not pad and IsDisabledControlPressed(0, 19)

                -- Where the aim lands. World only: a bay goes on the ground, never on a car standing on it.
                local cam = GetFinalRenderedCamCoord()
                local fx, fy, fz = InteractGetCameraForward()
                local ray = StartShapeTestRay(cam.x, cam.y, cam.z, cam.x + fx * BAY_REACH, cam.y + fy * BAY_REACH,
                    cam.z + fz * BAY_REACH, 1, PlayerPedId(), 0)
                local _, hit, coords, normal = GetShapeTestResult(ray)
                valid = hit == 1 and normal ~= nil and normal.z >= 0.7
                -- The bay aimed at: the one whose outline the aim lands in. Not while one is carried.
                aimed = (not carry and hit == 1) and bayAt(bays, coords.x, coords.y, coords.z) or nil

                -- Turn and raise what is in hand: a carried bay, or the next one. Not while a bay is aimed at: the
                -- next one is not drawn then, and a turn nobody saw would only surprise you at the next bay.
                if not aimed then
                    if pad then
                        local t = WhipPadTrigger('rt') - WhipPadTrigger('lt')   -- RT turns it right, LT left
                        if t ~= 0.0 then heading = (heading - t * BAY_TURN * dt) % 360.0 end
                    else
                        local rate = fine and BAY_TURN_FINE or BAY_TURN
                        if IsDisabledControlPressed(0, 44) then heading = (heading + rate * dt) % 360.0
                        elseif IsDisabledControlPressed(0, 38) then heading = (heading - rate * dt) % 360.0 end
                    end
                    -- Raise / lower: ↑ / ↓ held on a keyboard, the D-pad on a pad (not with LB held).
                    local up, down = WhipKeyHeld(172, 188), WhipKeyHeld(173, 187)
                    local zRate = fine and BAY_RAISE_FINE or BAY_RAISE
                    if up then raise = math.min(BAY_RAISE_MAX, raise + zRate * dt)
                    elseif down then raise = math.max(-BAY_RAISE_MAX, raise - zRate * dt) end
                end
                if valid then x, y, z = coords.x, coords.y, coords.z + raise end

                -- The bays, green; the one aimed at lit (the "car is in it" picture); the one in hand white — red
                -- when there is no room for another — and a carried bay's old place faint, for what C puts back.
                for i, b in ipairs(bays) do
                    if i == aimed then GarageBayDraw(b.x, b.y, b.z, b.heading, 1.0, BAY_WHITE, true)
                    else GarageBayDraw(b.x, b.y, b.z, b.heading, 0.9, BAY_GREEN) end
                end
                if carry then
                    GarageBayDraw(carry.bay.x, carry.bay.y, carry.bay.z, carry.bay.heading, 0.3, BAY_GREEN)
                    if valid then GarageBayDraw(x, y, z, heading, 0.9, BAY_WHITE) end
                elseif valid and not aimed then
                    GarageBayDraw(x, y, z, heading, 0.9, #bays < max and BAY_WHITE or BAY_RED)
                end

                local acted = false
                -- Enter (201, or 18) on a keyboard, A on a pad: put a bay down; pick up the one aimed at; put it
                -- down again.
                if pressed(201, 201) or (not pad and IsDisabledControlJustPressed(0, 18)) then
                    acted = true
                    if carry then
                        if not valid then
                            EditorHud.status('Aim at flat ground first', 'warn')
                        else
                            -- A new bay in its place, with its id: the caller sees a move, not a new bay.
                            table.insert(bays, carry.at, { x = x, y = y, z = z, heading = heading, id = carry.bay.id })
                            EditorHud.status(nameOf(carry.bay, carry.at) .. ' moved', 'ok')
                            raise, carry = carry.raise, nil
                        end
                    elseif aimed then
                        local b = table.remove(bays, aimed)
                        -- Its own height, as an offset from the ground under it: it lifts off where it was.
                        carry = { bay = b, at = aimed, raise = raise }
                        heading = b.heading
                        raise = math.max(-BAY_RAISE_MAX, math.min(BAY_RAISE_MAX, b.z - coords.z))
                        EditorHud.status(nameOf(b, aimed) .. ' picked up: aim where it goes', 'info')
                        aimed = nil
                    elseif not valid then
                        EditorHud.status('Aim at flat ground first', 'warn')
                    elseif #bays >= max then
                        EditorHud.status(('This garage has room for %d bays'):format(max), 'err')
                    else
                        bays[#bays + 1] = { x = x, y = y, z = z, heading = heading }
                        EditorHud.status(nameOf(bays[#bays], #bays) .. ' put down', 'ok')
                    end
                end
                -- X: away with the one carried, or the one aimed at.
                if pressed(73, 203) then
                    if carry then
                        EditorHud.status(nameOf(carry.bay, carry.at) .. ' taken away', 'info')
                        raise, carry = carry.raise, nil
                        acted = true
                    elseif aimed then
                        local b = table.remove(bays, aimed)
                        EditorHud.status(nameOf(b, aimed) .. ' taken away', 'info')
                        aimed, acted = nil, true
                    end
                end
                -- Done: Esc on a keyboard (onEscape), Menu on a pad.
                if pad and pressed(199, 199) and canFinish() then return 'exit' end
                -- C / B: a carried bay goes back where it was; with none, every change this visit is undone.
                if WhipCancelJustPressed() then
                    if carry then
                        EditorHud.status(nameOf(carry.bay, carry.at) .. ' put back', 'info')
                        putBack()
                        acted = true
                    else
                        bays, undone = before, true
                        return 'exit'
                    end
                end

                -- The card: at once when what is aimed at or held changes, else five times a second.
                local now = GetGameTimer()
                if acted or aimed ~= lastAimed or (carry ~= nil) ~= lastCarry then nextHud = 0 end
                lastAimed, lastCarry = aimed, carry ~= nil
                if now >= nextHud then
                    nextHud = now + 200
                    EditorHud.update(card())
                end
            end
        end)(),
    })
end

-- ============================================
-- Show space
-- ============================================
--
-- The admin panel's "Show space": the property's space drawn in the world in blue, its neighbours
-- in grey, with how big it is and how far away you are. Nothing to edit — it answers "is this
-- the flat I think it is, and does its box fit the walls".

--- The floor area of a list of wire shapes, in square metres.
local function areaOf(shapes)
    local a = 0.0
    for _, s in ipairs(shapes or {}) do a = a + Shapes.area(s) end
    return a
end

---@param p table  a property as client/properties.lua holds it
function PropertyEditor.showSpace(p)
    if not p then return false end
    local shapes = p.shapes or {}
    if #shapes == 0 then
        UI.Notify('This property has no space set up yet', 'error')
        return false
    end

    local a = p.anchor or { x = p.x, y = p.y, z = p.z, r = 10.0 }
    local area = areaOf(shapes)
    local neighbours = 0

    local started = PropertyEditor.start({
        name = 'Show space',
        padBack = true,
        hud = {
            house = true, icon = 'house', title = 'Space',
            sub = (p.name or ('Property #' .. tostring(p.id))) .. ', in blue',
            chip = { text = 'Saved', tone = 'ok' },
            rows = {},
            hints = { { key = 'Esc', pad = 'b', text = 'Back to the panel' } },
        },
        onFrame = (function()
            local nextAt = 0
            return function()
                local now = GetGameTimer()
                if now < nextAt then return end
                nextAt = now + 500
                local c = GetEntityCoords(PlayerPedId())
                local dx, dy, dz = c.x - a.x, c.y - a.y, c.z - a.z
                local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
                EditorHud.update({ rows = {
                    { label = 'Shapes', value = #shapes },
                    { label = 'Floor area', value = ('%.1f m²'):format(area) },
                    { label = 'Neighbours', value = neighbours == 0 and 'none near' or ('%d, in grey'):format(neighbours) },
                    { label = 'You are', value = ('%.0f m away'):format(dist),
                      tone = dist > 150 and 'warn' or nil },
                } })
            end
        end)(),
    })
    if not started then return false end

    ZonePreview.set('pe:space', shapes, { name = 'current', label = p.name })
    for id, other in pairs(GetPropertyDefs and GetPropertyDefs() or {}) do
        if id ~= p.id and other.anchor and other.shapes and #other.shapes > 0 then
            local ox, oy, oz = other.anchor.x - a.x, other.anchor.y - a.y, other.anchor.z - a.z
            if ox * ox + oy * oy + oz * oz < 80.0 * 80.0 then
                ZonePreview.set('pe:n:' .. id, other.shapes, { name = 'other', label = other.name })
                neighbours = neighbours + 1
            end
        end
    end
    return true
end
