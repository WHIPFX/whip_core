-- ============================================
-- VIEWPORT ROOM — keeping the game's idea of the camera's room right
-- ============================================
--
-- GTA draws an MLO by the ROOM the camera is in — that room, and whatever can be seen from it through
-- doorways (the MLO's portals) — and it keeps track of which room that is by watching the camera pass
-- through the doorways. Walking always goes through a doorway, so it never loses count. A camera that
-- gets somewhere WITHOUT one does:
--
--   a free camera   flies through walls and floors (client/freecam.lua: noclip, the furnisher's camera)
--   a spawn         puts the player, and the gameplay camera behind them, straight into a room —
--                   loading into a character who logged out inside a property culled the interior
--                   until they walked out and back in
--
-- and the game goes on believing the camera is in the room (or the street) it was in before: it draws
-- that one's view and culls the room the camera is really in.
--
-- So the camera's room is worked out by client/interior_rooms.lua from the interior's own room boxes
-- and handed to the game with ForceRoomForGameViewport, the native Rockstar's scripts use for their
-- own cameras inside interiors. Leaving the interior, the game is told the camera is outside (the
-- interior's room 0, limbo), then given its own judgement back (ClearRoomForGameViewport).
--
-- CHECKED, NOT ASSUMED. Which number the native wants for the interior has not been seen on this
-- server (/propprobe found the at-coords natives name an interior with a different number from
-- GetInteriorFromEntity), so the game is asked back (GetRoomKeyForGameViewport) and a room it will
-- not take is tried with the other number — and kept. /freecamroom draws it.

ViewportRoom = {}

local HAS = ForceRoomForGameViewport ~= nil and ClearRoomForGameViewport ~= nil
    and GetRoomKeyForGameViewport ~= nil and GetInteriorRoomCount ~= nil and GetInteriorRoomName ~= nil
    and GetInteriorRoomExtents ~= nil

local ROOM_EVERY_MS = 100     -- the camera's room is looked up at most this often...
local ROOM_MOVE_M   = 0.25    -- ...or as soon as it has moved this far
local REFUSED_FRAMES = 30     -- the game not taking a room this long: try naming the interior the other way
local OUT_HOLD_FRAMES = 15    -- "outside" held this long before the room is handed back
local PLAYER_ROOM_NEAR_M = 2.0 -- a camera this close to the player takes the player's own room where boxes overlap

local want = nil              -- the room the camera is in: { id, alt, key, name }, or nil outside every room
local inInterior = false      -- does the game put an interior at the camera at all (GetInteriorAtCoords)
local forced = nil            -- what was last told to the game: { id, alt, key } — or nil
local lookedAt, lookedFrom = -math.huge, nil
local useAlt = false          -- learned: the game takes a room only when the interior is named the other way
local refused = 0
local outFrames = 0

local function sameKey(a, b) return InteriorRooms.sameKey(a, b) end

--- Tell the game a room, by whichever number for the interior it has been taking.
local function force(id, alt, key)
    local use = (useAlt and alt and alt ~= 0) and alt or id
    ForceRoomForGameViewport(use, key)
    forced = { id = id, alt = alt, key = key }
end

--- Hand the room back to the game, if it was taken, and forget everything followed.
function ViewportRoom.release()
    if forced and HAS then ClearRoomForGameViewport() end
    forced, want = nil, nil
    lookedAt, lookedFrom, refused, outFrames = -math.huge, nil, 0, 0
end

--- Every frame a camera is to be followed: keep the game's idea of its room right.
---@param p vector3  where the camera is
function ViewportRoom.follow(p)
    if not HAS then return end
    local now = GetGameTimer()
    if not lookedFrom or #(p - lookedFrom) > ROOM_MOVE_M or now - lookedAt >= ROOM_EVERY_MS then
        lookedAt, lookedFrom = now, p
        want, inInterior = InteriorRooms.find(p.x, p.y, p.z, nil, InteriorRooms.playerRoomNear(p, PLAYER_ROOM_NEAR_M))
    end

    if want then
        outFrames = 0
        if sameKey(GetRoomKeyForGameViewport(), want.key) then
            -- The game already agrees. Remembered all the same, so leaving this room is told too.
            refused = 0
            if not forced or not sameKey(forced.key, want.key) then
                forced = { id = want.id, alt = want.alt, key = want.key }
            end
            return
        end
        force(want.id, want.alt, want.key)
        -- Told and not taken, frame after frame: name the interior the other way and see.
        refused = refused + 1
        if refused >= REFUSED_FRAMES then
            refused = 0
            if want.alt and want.alt ~= 0 and want.alt ~= want.id then
                useAlt = not useAlt
                print(('[whip_core:rooms] the game would not take room %s by interior %s — trying %s'):format(
                    want.name, tostring(useAlt and want.id or want.alt), tostring(useAlt and want.alt or want.id)))
            end
        end
    elseif forced and not inInterior then
        -- OUT OF THE INTERIOR: say so (the interior's limbo is the outside), hold it a moment so the
        -- game takes it, then give the game its own judgement back. Clearing alone would leave it
        -- believing the last room it was told, and culling the street.
        --
        -- ONLY WHEN THE GAME PUTS NO INTERIOR HERE AT ALL. Inside one but in no room's box — in a
        -- wall, in a gap between boxes, in a room shaped so its box misses a corner — the last room
        -- stands: declaring the outside there would cull the very room the camera is in.
        local r = InteriorRooms.of(forced.id)
        if r and r.limbo and not sameKey(forced.key, r.limbo) then
            force(forced.id, forced.alt, r.limbo)
            outFrames = 0
        else
            outFrames = outFrames + 1
            if outFrames >= OUT_HOLD_FRAMES then ViewportRoom.release() end
        end
    end
end

--- Does the game agree with the room the camera is in (as last looked up)? Nil outside every room.
function ViewportRoom.agrees()
    if not want then return nil end
    return sameKey(GetRoomKeyForGameViewport(), want.key)
end

--- Is anything still told to the game (a room, or the outside on the way out)?
function ViewportRoom.holding() return forced ~= nil end

--- For /freecamroom: what the follower sees.
function ViewportRoom.state()
    return { want = want, useAlt = useAlt, available = HAS }
end

-- ============================================
-- After a teleport: the player's own camera
-- ============================================
--
-- A spawn (or any teleport) leaves the GAMEPLAY camera's room stale, the same as a free camera
-- through a wall — but this camera walks through doorways from then on, and the game's own tracking
-- is the better judge of those. So the room is not taken for good:
--
--   1. SETTLE   the camera's room is told to the game until it agrees for a moment (at most
--               SETTLE_MS: a camera outside every room has nothing to settle)
--   2. LET GO   the room is handed back, and the game watched for WATCH_MS
--   3. HOLD     only if the game slips back to its stale room once let go: the camera is followed
--               until it leaves the interior, as a free camera is
--
-- Which of 2 or 3 this game does has not been seen on this server; this works either way.

local SETTLE_MS, AGREE_FRAMES, WATCH_MS = 6000, 15, 1500
local GAMEPLAY_WAIT_MS = 20000
local settling = false

local function cam() return GetFinalRenderedCamCoord() end

--- Put the game's idea of the camera's room right after the player has been put somewhere (spawn).
--- Runs in its own thread; a second call while one is running is ignored. Stands aside for the free
--- camera, which follows its own room (client/freecam.lua).
function ViewportRoom.settle()
    if not HAS or settling then return end
    settling = true
    CreateThread(function()
        -- 0. THE GAMEPLAY CAMERA FIRST. A spawn happens while the character screen's (or the
        --    creator's) own camera may still be the one drawn; settling that one and stopping would
        --    leave the gameplay camera stale the moment it takes over.
        local waitUntil = GetGameTimer() + GAMEPLAY_WAIT_MS
        while not IsGameplayCamRendering() do
            if GetGameTimer() > waitUntil or (FreeCam and FreeCam.isActive()) then settling = false return end
            Wait(100)
        end

        -- 1. Settle.
        local deadline = GetGameTimer() + SETTLE_MS
        local agreed = 0
        while GetGameTimer() < deadline and agreed < AGREE_FRAMES do
            if FreeCam and FreeCam.isActive() then settling = false return end
            ViewportRoom.follow(cam())
            agreed = ViewportRoom.agrees() and agreed + 1 or 0
            Wait(0)
        end

        -- 2. Let go, and watch.
        ViewportRoom.release()
        local slipped = false
        local watchUntil = GetGameTimer() + WATCH_MS
        while GetGameTimer() < watchUntil do
            if FreeCam and FreeCam.isActive() then settling = false return end
            local c = cam()
            local room = InteriorRooms.find(c.x, c.y, c.z, nil, InteriorRooms.playerRoomNear(c, PLAYER_ROOM_NEAR_M))
            if room and not sameKey(GetRoomKeyForGameViewport(), room.key) then slipped = true break end
            Wait(100)
        end

        -- 3. Hold, only if the game slipped back.
        if slipped then
            print('[whip_core:rooms] the game lost the camera\'s room once let go — following it until it leaves the interior')
            repeat
                if FreeCam and FreeCam.isActive() then settling = false return end
                ViewportRoom.follow(cam())
                Wait(0)
            until not ViewportRoom.holding() and not ViewportRoom.agrees()
        end
        settling = false
    end)
end
