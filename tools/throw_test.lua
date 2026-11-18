-- ============================================
-- Dev Tools — Throw test (/throwtest)
-- ============================================
--
-- Tries ThrowGroundItem (server/ground.lua) in the world, the way a script calls it: a point it is thrown from, a
-- point it is aimed at, and how hard. Each throw is one item picked at random from every item any resource has
-- registered, thrown by the server's export with `by` = you, so your game flies it when you stand near the point.
--
--   G held / RT held      throw: one at once, and while it stays down, up to 20 a second after HOLD_MS (the server
--                         throws one every 500 ms and queues the rest)
--   ↑ ↓ / D-pad ↑ ↓       the power, up or down by 5, from 0 to 40 (a player throws at 18)
--   F / X                 place the point it is thrown from, with the object viewer's markers (PlacePoint)
--   X / Y                 place the target the same way; its ring turns how an item lies when it is put down
--   Delete / RB           take back what this test threw that still lies on the ground
--   Esc / B               leave
--
-- The blue ball is where it is thrown from, the orange one the target, and the line the arc the server aims it on
-- (ThrowAim, the same numbers): white when it reaches the target, red when it falls short, where a red ball marks
-- where it comes down. The card counts the throws a game flew and the ones the server put down instead (nobody near
-- enough, or no launch in time), and says the last item or why it failed.
--
-- An admin mode (PropertyEditor.start, `padBack`): Esc or B, death and a resource stop end it the same way. While a
-- point is being placed the mode's keys wait, its Esc and B too: PlacePoint's Esc and B are PlacePoint's. The world's prompts stay up
-- (`prompts = true`), so what it threw can be picked up with E or A without leaving: none of its keys is E, A or the
-- scroll wheel, which are the prompts'.

local POWER_STEP = 5
local POWER_MAX  = 40          -- ThrowGroundItem's most (server/ground.lua THROW_FOR_POWER)
local HOLD_MS    = 250         -- held this long, the throws keep coming
local ASK_MS     = 50          -- ...asked for 20 a second at most (the server's throwTest limit)
local FLIER_RANGE = 50.0       -- your game flies it within this of the point (server/ground.lua THROW_FOR_RANGE)
local LOOK_REACH = 40.0        -- where you look, for the first target
local ARC_STEPS  = 24
local CARD_MS    = 100

-- Everything the mode reads, held off so the game does not act on it as well: G (47), F (23), X (73), the phone's up
-- and down (172, 173), Delete (178), the triggers (24, 25), and a pad's X, Y, RB and B underneath their frontend
-- buttons (22 jump, 23, 44 cover, 45 / 140-142 reload and melee). No `mode`: that would stand the prompts down too.
-- The hotbar and the pad's world buttons stand down anyway, for any PropertyEditor mode (IsGameInputFree).
local BLOCK = { groups = { 'weaponWheel' },
                controls = { 22, 23, 24, 25, 37, 44, 45, 47, 73, 140, 141, 142, 172, 173, 178 } }

local active = false
local S = nil   -- the test while it runs: { from, target, power, placing, quietUntil, heldSince, askedAt, sent, flown, put, failed, last, lastTone }

--- Where the camera looks: the first surface within LOOK_REACH, or nil.
---@return vector3|nil
local function lookedAt()
    local c = GetFinalRenderedCamCoord()
    local fx, fy, fz = InteractGetCameraForward()
    local ray = StartShapeTestRay(c.x, c.y, c.z, c.x + fx * LOOK_REACH, c.y + fy * LOOK_REACH, c.z + fz * LOOK_REACH,
        1 + 16, PlayerPedId(), 0)
    local _, hit, at = GetShapeTestResult(ray)
    if hit == 1 or hit == true then return at end
    return nil
end

-- ---- the arc, as the server aims it (server/ground.lua throwPath, with a power) ----

local arcKey, arc = nil, nil   -- the points of the arc for the inputs in arcKey

---@return table { points, reaches, lands }
local function arcFor(from, target, power)
    local key = ('%.3f %.3f %.3f %.3f %.3f %.3f %d'):format(from.x, from.y, from.z, target.x, target.y, target.z, power)
    if key == arcKey then return arc end
    local vx, vy, vz = ThrowAim.arc(from, target, power)
    local reaches = vx ~= nil
    if not reaches then
        if power > 0 then vx, vy, vz = ThrowAim.straight(from, target, power) end
        if not vx then vx, vy, vz = 0.0, 0.0, 0.0 end
    end
    local lx, ly, lz = ThrowAim.landing(from, vx, vy, vz, target.z)
    local g = ThrowAim.GRAVITY
    local t = (vz + math.sqrt(math.max(0.0, vz * vz + 2.0 * g * (from.z - lz)))) / g
    local points = {}
    for i = 0, ARC_STEPS do
        local s = t * i / ARC_STEPS
        points[#points + 1] = vector3(from.x + vx * s, from.y + vy * s, from.z + vz * s - 0.5 * g * s * s)
    end
    arcKey, arc = key, { points = points, reaches = reaches, lands = vector3(lx, ly, lz) }
    return arc
end

local function draw()
    local f, t = S.from, S.target
    local a = arcFor(f, t, S.power)
    local r, g, b = 255, 255, 255
    if not a.reaches then r, g, b = 255, 80, 80 end
    for i = 2, #a.points do
        local p, q = a.points[i - 1], a.points[i]
        DrawLine(p.x, p.y, p.z, q.x, q.y, q.z, r, g, b, 220)
    end
    DrawMarker(28, f.x, f.y, f.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.12, 0.12, 0.12, 80, 170, 255, 210,
        false, false, 2, false, nil, nil, false)
    DrawMarker(28, t.x, t.y, t.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.16, 0.16, 0.16, 255, 150, 40, 210,
        false, false, 2, false, nil, nil, false)
    if not a.reaches then
        local l = a.lands
        DrawMarker(28, l.x, l.y, l.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.12, 0.12, 0.12, 255, 80, 80, 210,
            false, false, 2, false, nil, nil, false)
    end
end

-- ---- the card ----

local function card()
    local me = GetEntityCoords(PlayerPedId())
    local f, t = S.from, S.target
    local fromMe = #(me - f)
    local reaches = arcFor(f, t, S.power).reaches
    local waiting = S.sent - S.flown - S.put - S.failed
    return {
        house = true, icon = 'target', title = 'Throw test', sub = 'ThrowGroundItem · a random item each throw',
        chip = S.placing and { text = 'Placing' }
            or { text = reaches and 'Reaches the target' or 'Falls short', tone = reaches and 'ok' or 'warn' },
        rows = {
            { label = 'Power', value = ('%d of %d'):format(S.power, POWER_MAX) },
            { label = 'From', value = ('%.1f m from you'):format(fromMe),
              tone = fromMe > FLIER_RANGE and 'warn' or nil },
            { label = 'Target', value = ('%.1f m from the start'):format(#(vector3(t.x, t.y, t.z) - f)) },
            -- Every throw asked for, then how each went: flown by a game, or put down at the target by the server
            -- (and failed, a refused ask). Waiting: asked, the server's answer not back yet (up to ~10 s each).
            { label = 'Thrown', value = waiting > 0 and ('%d (%d waiting)'):format(S.sent, waiting) or tostring(S.sent) },
            { label = 'Landed', value = ('%d flew · %d put down%s'):format(S.flown, S.put,
                S.failed > 0 and (' · %d failed'):format(S.failed) or '') },
            { label = 'Last', value = S.last or 'Nothing yet', tone = S.lastTone or false },
        },
        hints = {
            { key = 'G', pad = 'rt', text = 'Throw (hold for more)', off = S.placing },
            { key = '↑ / ↓', pad = { 'dpad_up', 'dpad_down' }, text = 'Power', off = S.placing },
            { key = 'F', pad = 'x', text = 'Place the start', off = S.placing },
            { key = 'X', pad = 'y', text = 'Place the target', off = S.placing },
            { key = 'Delete', pad = 'rb', text = 'Take back what it threw', off = S.placing },
            { key = 'Esc', pad = 'b', text = 'Leave', off = S.placing },
        },
    }
end

local nextCard = 0
local function refreshCard(now)
    if now and now < nextCard then return end
    nextCard = (now or GetGameTimer()) + CARD_MS
    EditorHud.update(card())
end

-- ---- doing things ----

local function throwOne()
    local f, t = S.from, S.target
    S.sent = S.sent + 1
    S.askedAt = GetGameTimer()
    TriggerServerEvent('whip_core:server:throwTest', f.x, f.y, f.z, t.x, t.y, t.z, t.w or 0.0, S.power + 0.0)
end

--- Place one of the two points with PlacePoint (waits: run in a thread). `which` is 'from' or 'target'.
local function place(which)
    local my = S
    local was = my[which]
    my.placing = true
    refreshCard()
    -- Under pcall: an error in here must not leave `placing` on, or neither Esc nor B could leave the mode.
    -- (The start is a vector3, the target a vector4 with its heading.)
    local ok, point = pcall(PlacePoint, {
        at = { x = was.x, y = was.y, z = was.z, w = which == 'target' and was.w or 0.0 },
        label = which == 'from' and 'Where it is thrown from' or 'The target',
    })
    if S ~= my then return end   -- (left meanwhile, a death or a stop, or left and opened again)
    S.placing = false
    -- The Esc or B that ended the placing may still be read a frame after: not the way out too
    S.quietUntil = GetGameTimer() + 400
    if not ok then
        print(('^1[whip_core:throwtest] placing the %s failed: %s^7'):format(which == 'from' and 'start' or 'target',
            tostring(point)))
        EditorHud.status('Could not place it (F8 says why)', 'err')
    elseif point then
        if which == 'from' then
            S.from = vector3(point.x, point.y, point.z)
        else
            S.target = vector4(point.x, point.y, point.z, point.w or 0.0)
        end
        EditorHud.status(which == 'from' and 'Start placed' or 'Target placed', 'ok')
    end
    refreshCard()
end

local function onFrame()
    if not S then return 'exit' end
    draw()
    local now = GetGameTimer()
    -- Placing, just placed, or a whip dialog up (it reads the same buttons): the mode's keys wait
    if S.placing or now < S.quietUntil or UI.IsBusy() then S.heldSince = nil refreshCard(now) return end
    local pad = WhipLastInputIsPad()

    -- Throw: at once, then up to 20 a second while held past HOLD_MS
    local down
    if pad then down = WhipPadTrigger('rt') > 0.35 else down = WhipKeyHeld(47, nil) end
    if down then
        if not S.heldSince then
            S.heldSince = now
            throwOne()
        elseif now - S.heldSince >= HOLD_MS and now - (S.askedAt or 0) >= ASK_MS then
            throwOne()
        end
    else
        S.heldSince = nil
    end

    -- Power
    local step = 0
    if WhipKeyPressed(172, 188) then step = POWER_STEP end
    if WhipKeyPressed(173, 187) then step = -POWER_STEP end
    if step ~= 0 then S.power = math.max(0, math.min(POWER_MAX, S.power + step)) end

    -- The two points (PlacePoint waits)
    if WhipKeyPressed(23, 203) then CreateThread(function() place('from') end)
    elseif WhipKeyPressed(73, 204) then CreateThread(function() place('target') end) end

    if WhipKeyPressed(178, 206) then TriggerServerEvent('whip_core:server:throwTestClear') end

    refreshCard(now)
end

local function start()
    if active then PropertyEditor.stop('done') return end
    local ped = PlayerPedId()
    local from = GetOffsetFromEntityInWorldCoords(ped, 0.0, 0.6, 0.35)        -- in front of you, at chest height
    local at = lookedAt() or GetOffsetFromEntityInWorldCoords(ped, 0.0, 8.0, -0.9)
    S = { from = from, target = vector4(at.x, at.y, at.z, 0.0), power = 20, placing = false, quietUntil = 0,
          heldSince = nil, sent = 0, flown = 0, put = 0, failed = 0, last = nil, lastTone = nil }
    active = true
    nextCard = 0
    local started = PropertyEditor.start({
        name = 'Throw test',
        hud = card(),
        block = BLOCK,
        padBack = true,   -- B leaves, as Esc does
        prompts = true,   -- the piles it throws can be picked up without leaving
        onFrame = onFrame,
        -- Esc or B while a point is placed is PlacePoint's
        onEscape = function() return not (S and (S.placing or GetGameTimer() < S.quietUntil)) end,
        onExit = function()
            -- Left while a point was being placed (a death, another mode): its markers and ghost go too
            if S and S.placing and OvMove.active() then OvMove.stop() end
            active = false
            S = nil
            arcKey, arc = nil, nil
        end,
    })
    if not started then active, S = false, nil end
end

DevCommand('throwtest', function() start() end)

-- ---- the server's answers ----

RegisterNetEvent('whip_core:client:throwTestResult', function(how, label, why)
    if not S then return end
    if how == 'thrown' then
        S.flown = S.flown + 1
        S.last, S.lastTone = tostring(label), false
    elseif how == 'ground' then
        -- Put down at the target by the server, not flown: why, word for word (server/ground.lua askThrow), so a
        -- pile seen to snap to the target says which check it failed
        -- (The card cuts a long row short: the why goes to its status line, and to F8 once per new reason.)
        S.put = S.put + 1
        S.last, S.lastTone = ('%s · put down'):format(tostring(label)), 'warn'
        local said = tostring(why or 'not flown')
        if said ~= S.lastWhy then
            S.lastWhy = said
            EditorHud.status('Put down at the target: ' .. said, 'warn')
            print(('[whip_core:throwtest] put down at the target: %s'):format(said))
        end
    else
        S.failed = S.failed + 1
        S.last, S.lastTone = ('%s: %s'):format(tostring(label or 'No item'), tostring(why or 'failed')), 'err'
    end
end)

RegisterNetEvent('whip_core:client:throwTestCleared', function(removed)
    if not S then return end
    EditorHud.status(('Took back %d'):format(tonumber(removed) or 0), 'ok')
end)
