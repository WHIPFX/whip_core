-- ============================================
-- Dev Tools — Interior Probe
-- ============================================
--
-- PHASE 0 OF THE PROPERTIES REBUILD, and the reason it comes first: every later piece of the
-- Configurator leans on interior natives that whip has never called, and their exact behaviour on
-- THESE map packs is not something to reason about from documentation. This captures what they
-- actually answer — standing inside an interior, run `/propprobe [archetypeName]` — and hands the
-- lot to the server, which writes it to whip_core/dev/probe/ where it can be read and compared.
--
-- WHAT EACH RUN RECORDS, and the question each part settles (numbers match the plan's Phase 0):
--
--   identity    (1, 2)  the interior handle, GetInteriorLocationAndNamehash's position and hash,
--                       GetInteriorPosition / Rotation / Heading, and the typed archetype name's
--                       GetHashKey — do they agree, and in which sign?
--   basis       (3, 4)  GetOffsetFromInteriorInWorldCoords at the origin and one metre along each
--                       local axis: the yaw the whole template system is built on, and whether the
--                       placement is yaw-only (ez.z ~ 1)
--   rooms       (5)     count, names, flags, LOCAL extents, and whether the ped's room key equals
--                       the hash of its room's name
--   portals     (6)     from/to, flags, LOCAL corners, and every attached entity — archetype,
--                       local position, the world position two ways (the native, and whip's own
--                       maths), and whether a real object stands there
--   objects     (7)     every object inside this interior, with its model size: what a "door
--                       shaped" filter has to recognise, and which doors are NOT on a portal
--   re-resolve  (9)     GetInteriorAtCoordsWithTypehash at the origin and a floor above/below
--   readiness   (10)    how long PinInteriorInMemory takes to make an interior ready, when it
--                       was not already
--
-- Door behaviour with the packs' own helpers switched off (8) is watched by eye, not measured.
--
-- DEV ONLY. The command asks the server for devtools access before doing anything, and the save
-- is ACE-gated on the server regardless. It sends one latent event per run and holds no state.

local PROBE_OBJECT_CAP = 400   -- objects recorded per run; the nearest first
local PROBE_READY_MS   = 10000 -- how long to wait for PinInteriorInMemory to make it ready

--- Round for the record, so the JSON is readable and diffs between runs mean something.
local function r3(v)
    if type(v) ~= 'number' then return v end
    return math.floor(v * 1000 + 0.5) / 1000
end

local function vec(x, y, z)
    if type(x) == 'vector3' or type(x) == 'table' then
        return { x = r3(x.x), y = r3(x.y), z = r3(x.z) }
    end
    return { x = r3(x), y = r3(y), z = r3(z) }
end

--- Both spellings of a 32-bit hash, because which one each native returns is one of the things
--- being measured. FiveM Lua usually hands back the signed form; the map packs write unsigned.
local function hashForms(h)
    if type(h) ~= 'number' then return { raw = h } end
    local u = h % 4294967296
    local s = (u >= 2147483648) and (u - 4294967296) or u
    return { raw = h, signed = math.floor(s), unsigned = math.floor(u) }
end

--- Call a native, recording a failure instead of throwing. Several of the CFX interior natives
--- have been broken on some builds (GetInteriorRoomExtents was, for a while), and one missing or
--- throwing native must not cost the rest of the report.
local function try(errs, label, fn, ...)
    local res = table.pack(pcall(fn, ...))
    if not res[1] then
        errs[#errs + 1] = ('%s: %s'):format(label, tostring(res[2]))
        return nil
    end
    return table.unpack(res, 2, res.n)
end

--- Local to world with whip's own maths — the transform every runtime path will use, measured
--- here against the native so a disagreement shows up in the first run rather than the fiftieth.
local function toWorld(origin, yawDeg, lx, ly, lz)
    local t = math.rad(yawDeg)
    local c, s = math.cos(t), math.sin(t)
    return {
        x = r3(origin.x + lx * c - ly * s),
        y = r3(origin.y + lx * s + ly * c),
        z = r3(origin.z + lz),
    }
end

local function dist(a, b)
    if not a or not b then return nil end
    local dx, dy, dz = (a.x or 0) - (b.x or 0), (a.y or 0) - (b.y or 0), (a.z or 0) - (b.z or 0)
    return r3(math.sqrt(dx * dx + dy * dy + dz * dz))
end

--- Yaw from a quaternion, for comparison with the basis-vector yaw only. The plan does NOT use
--- GetInteriorRotation, because whether it returns the placement rotation or its inverse is
--- exactly what is unknown; this records its answer next to the one that is trusted.
local function quatYawDeg(x, y, z, w)
    if not (x and y and z and w) then return nil end
    return r3(math.deg(math.atan(2.0 * (w * z + x * y), 1.0 - 2.0 * (y * y + z * z))))
end

local function probe(archetypeName)
    local errs = {}
    local ped = PlayerPedId()
    local pedPos = GetEntityCoords(ped)

    local report = {
        probeVersion = 1,
        at           = GetGameTimer(),
        ped          = { pos = vec(pedPos), heading = r3(GetEntityHeading(ped)) },
        errors       = errs,
    }

    local id = try(errs, 'GetInteriorFromEntity', GetInteriorFromEntity, ped) or 0
    local roomKey = try(errs, 'GetRoomKeyFromEntity', GetRoomKeyFromEntity, ped)
    report.ped.interior = id
    report.ped.roomKey = hashForms(roomKey)
    report.ped.primaryViewInterior = try(errs, 'GetInteriorFromPrimaryView', GetInteriorFromPrimaryView)
    report.ped.viewportRoomKey = hashForms(try(errs, 'GetRoomKeyForGameViewport', GetRoomKeyForGameViewport))
    report.ped.interiorAtCoords = try(errs, 'GetInteriorAtCoords', GetInteriorAtCoords,
        pedPos.x, pedPos.y, pedPos.z)

    if archetypeName and archetypeName ~= '' then
        report.typedArchetype = { name = archetypeName, hash = hashForms(GetHashKey(archetypeName)) }
    end

    if not id or id == 0 then
        report.verdict = 'not inside an interior (GetInteriorFromEntity returned 0)'
        return report
    end

    -- ---- readiness (10) ----
    local ready = try(errs, 'IsInteriorReady', IsInteriorReady, id)
    report.readiness = {
        valid = try(errs, 'IsValidInterior', IsValidInterior, id),
        readyAtStart = ready,
        group = try(errs, 'GetInteriorGroupId', GetInteriorGroupId, id),
    }
    if not ready then
        local t0 = GetGameTimer()
        try(errs, 'PinInteriorInMemory', PinInteriorInMemory, id)
        while not IsInteriorReady(id) and GetGameTimer() - t0 < PROBE_READY_MS do Wait(50) end
        report.readiness.pinnedReadyMs = GetGameTimer() - t0
        report.readiness.readyAfterPin = IsInteriorReady(id)
    end

    -- ---- identity (1, 2) ----
    local locPos, locHash = try(errs, 'GetInteriorLocationAndNamehash', GetInteriorLocationAndNamehash, id)
    local ipx, ipy, ipz = try(errs, 'GetInteriorPosition', GetInteriorPosition, id)
    local qx, qy, qz, qw = try(errs, 'GetInteriorRotation', GetInteriorRotation, id)
    local heading = try(errs, 'GetInteriorHeading', GetInteriorHeading, id)

    report.identity = {
        locationPos     = locPos and vec(locPos) or nil,
        locationHash    = hashForms(locHash),
        interiorPos     = ipx and vec(ipx, ipy, ipz) or nil,
        rotationQuat    = qx and { x = r3(qx), y = r3(qy), z = r3(qz), w = r3(qw) } or nil,
        rotationQuatYaw = quatYawDeg(qx, qy, qz, qw),
        headingRaw      = r3(heading),
        headingAsDeg    = heading and r3(math.deg(heading)) or nil,
    }
    if report.typedArchetype and locHash then
        report.identity.typedHashMatches = (hashForms(locHash).signed == report.typedArchetype.hash.signed)
    end

    -- ---- basis (3, 4) ----
    local o  = try(errs, 'offset origin', GetOffsetFromInteriorInWorldCoords, id, 0.0, 0.0, 0.0)
    local px = try(errs, 'offset +x', GetOffsetFromInteriorInWorldCoords, id, 1.0, 0.0, 0.0)
    local py = try(errs, 'offset +y', GetOffsetFromInteriorInWorldCoords, id, 0.0, 1.0, 0.0)
    local pz = try(errs, 'offset +z', GetOffsetFromInteriorInWorldCoords, id, 0.0, 0.0, 1.0)

    local origin, yaw = nil, nil
    if o and px and py and pz then
        origin = vec(o)
        local ex, ey, ez = px - o, py - o, pz - o
        yaw = r3(math.deg(math.atan(ex.y, ex.x)))
        report.basis = {
            origin = origin,
            ex = vec(ex), ey = vec(ey), ez = vec(ez),
            yawFromEx = yaw,
            yawFromEy = r3(math.deg(math.atan(-ey.x, ey.y))),
            yawOnly = (ez.z >= 0.999),
            originVsLocationPos = locPos and dist(origin, vec(locPos)) or nil,
            originVsInteriorPos = ipx and dist(origin, vec(ipx, ipy, ipz)) or nil,
        }
    end

    -- ---- re-resolve (9) ----
    if origin and locHash then
        local function at(dz)
            return try(errs, 'WithTypehash dz=' .. dz, GetInteriorAtCoordsWithTypehash,
                origin.x, origin.y, origin.z + dz, locHash)
        end
        report.reresolve = {
            atOrigin = at(0.0), up3 = at(3.0), down3 = at(-3.0), up6 = at(6.0), down6 = at(-6.0),
            sameAsHandle = (at(0.0) == id),
        }
    end

    -- ---- rooms (5) ----
    local rooms = {}
    local roomCount = try(errs, 'GetInteriorRoomCount', GetInteriorRoomCount, id) or 0
    for i = 0, roomCount - 1 do
        local name = try(errs, 'room name ' .. i, GetInteriorRoomName, id, i)
        local x1, y1, z1, x2, y2, z2 = try(errs, 'room extents ' .. i, GetInteriorRoomExtents, id, i)
        rooms[#rooms + 1] = {
            index = i,
            name = name,
            nameHash = name and hashForms(GetHashKey(name)) or nil,
            flag = try(errs, 'room flag ' .. i, GetInteriorRoomFlag, id, i),
            timecycle = try(errs, 'room timecycle ' .. i, GetInteriorRoomTimecycle, id, i),
            min = x1 and vec(x1, y1, z1) or nil,
            max = x1 and vec(x2, y2, z2) or nil,
        }
    end
    report.rooms = { count = roomCount, list = rooms }
    if roomKey and roomKey ~= 0 then
        report.rooms.pedRoomIndex = try(errs, 'GetInteriorRoomIndexByHash', GetInteriorRoomIndexByHash, id, roomKey)
    end

    local ex1, ey1, ez1, ex2, ey2, ez2 = try(errs, 'GetInteriorEntitiesExtents', GetInteriorEntitiesExtents, id)
    report.entitiesExtents = ex1 and { min = vec(ex1, ey1, ez1), max = vec(ex2, ey2, ez2) } or nil

    -- ---- portals (6) ----
    local portals = {}
    local portalCount = try(errs, 'GetInteriorPortalCount', GetInteriorPortalCount, id) or 0
    for p = 0, portalCount - 1 do
        local corners = {}
        for c = 0, 3 do
            local cx, cy, cz = try(errs, ('portal %d corner %d'):format(p, c),
                GetInteriorPortalCornerPosition, id, p, c)
            if cx then corners[#corners + 1] = vec(cx, cy, cz) end
        end

        local ents = {}
        local entCount = try(errs, 'portal entity count ' .. p, GetInteriorPortalEntityCount, id, p) or 0
        for e = 0, entCount - 1 do
            local arch = try(errs, ('portal %d ent %d archetype'):format(p, e),
                GetInteriorPortalEntityArchetype, id, p, e)
            local lx, ly, lz = try(errs, ('portal %d ent %d position'):format(p, e),
                GetInteriorPortalEntityPosition, id, p, e)
            local rx, ry, rz, rw = try(errs, ('portal %d ent %d rotation'):format(p, e),
                GetInteriorPortalEntityRotation, id, p, e)

            local entry = {
                archetype = hashForms(arch),
                localPos = lx and vec(lx, ly, lz) or nil,
                localRot = rx and { x = r3(rx), y = r3(ry), z = r3(rz), w = r3(rw) } or nil,
                flag = try(errs, ('portal %d ent %d flag'):format(p, e), GetInteriorPortalEntityFlag, id, p, e),
            }
            if lx then
                local nat = try(errs, ('portal %d ent %d native world'):format(p, e),
                    GetOffsetFromInteriorInWorldCoords, id, lx, ly, lz)
                entry.worldByNative = nat and vec(nat) or nil
                if origin and yaw then
                    entry.worldByMath = toWorld(origin, yaw, lx, ly, lz)
                    entry.mathVsNative = dist(entry.worldByMath, entry.worldByNative)
                end
                -- Is a real object standing there? This is what door resolution will rely on.
                local w = entry.worldByNative or entry.worldByMath
                if w and arch then
                    local obj = GetClosestObjectOfType(w.x, w.y, w.z, 1.0, arch, false, false, false)
                    if obj and obj ~= 0 then
                        local op = GetEntityCoords(obj)
                        entry.object = {
                            found = true,
                            pos = vec(op),
                            distance = dist(vec(op), w),
                            heading = r3(GetEntityHeading(obj)),
                            model = hashForms(GetEntityModel(obj)),
                        }
                    else
                        entry.object = { found = false }
                    end
                end
            end
            ents[#ents + 1] = entry
        end

        portals[#portals + 1] = {
            index = p,
            from = try(errs, 'portal from ' .. p, GetInteriorPortalRoomFrom, id, p),
            to = try(errs, 'portal to ' .. p, GetInteriorPortalRoomTo, id, p),
            flag = try(errs, 'portal flag ' .. p, GetInteriorPortalFlag, id, p),
            corners = corners,
            entities = ents,
        }
    end
    report.portals = { count = portalCount, list = portals }

    -- ---- objects in this interior (7) ----
    local objs = {}
    for _, obj in ipairs(GetGamePool('CObject')) do
        if DoesEntityExist(obj) and GetInteriorFromEntity(obj) == id then
            local op = GetEntityCoords(obj)
            local model = GetEntityModel(obj)
            local mn, mx = GetModelDimensions(model)
            local rec = {
                model = hashForms(model),
                pos = vec(op),
                heading = r3(GetEntityHeading(obj)),
                size = (mn and mx) and vec(mx.x - mn.x, mx.y - mn.y, mx.z - mn.z) or nil,
                pedDistance = dist(vec(op), vec(pedPos)),
                -- No room key per object: GetRoomKeyFromEntity crashes inside the game on some
                -- world objects (native 47c2a06d4f5f424b), and the whole probe went
                -- with it. The object's interior is already checked above.
            }
            if origin and yaw then
                -- The inverse transform, so an object's LOCAL position can be read straight off
                -- the report and compared with a portal entity's.
                local t = math.rad(yaw)
                local dx, dy = op.x - origin.x, op.y - origin.y
                rec.localPos = {
                    x = r3(dx * math.cos(t) + dy * math.sin(t)),
                    y = r3(-dx * math.sin(t) + dy * math.cos(t)),
                    z = r3(op.z - origin.z),
                }
            end
            objs[#objs + 1] = rec
        end
    end
    table.sort(objs, function(a, b) return (a.pedDistance or 0) < (b.pedDistance or 0) end)
    local total = #objs
    for i = PROBE_OBJECT_CAP + 1, #objs do objs[i] = nil end
    report.objects = { total = total, recorded = #objs, list = objs }

    if not ready then try(errs, 'UnpinInterior', UnpinInterior, id) end

    report.verdict = ('interior %s hash %s: %d room(s), %d portal(s), %d object(s), yaw %s, yaw-only %s')
        :format(tostring(id), tostring(locHash), roomCount, portalCount, total, tostring(yaw),
                tostring(report.basis and report.basis.yawOnly))
    return report
end

--- What the probe found, in the editor HUD, for as long as the rooms are drawn. A later probe
--- takes the HUD over, so an earlier one's timer must not hide it: the token says whose it is.
local PROBE_SHOW_MS = 20000
local _hudRows, _hudToken = nil, 0

local function showProbeHud(label, report)
    local b = report.basis
    local ident = report.identity
    -- The report's row LAST: propertyProbeSaved (below) writes its answer there.
    _hudRows = {
        { label = 'Interior', value = ident and ident.locationHash and tostring(ident.locationHash.signed)
            or tostring(report.ped and report.ped.interior or 0) },
        { label = 'Rooms', value = ('%d, yours in blue'):format(report.rooms and report.rooms.count or 0) },
        { label = 'Portals', value = report.portals and report.portals.count or 0 },
        { label = 'Objects', value = report.objects and report.objects.total or 0 },
        { label = 'Yaw', value = b and b.yawFromEx or '—' },
        { label = 'Report', value = 'sending…' },
    }
    -- Whether the interior only turns (never tilts) is the probe's verdict: the chip.
    local chip = nil
    if b then chip = b.yawOnly and { text = 'Yaw only', tone = 'ok' } or { text = 'Tilted', tone = 'err' } end
    EditorHud.show({
        house = true, icon = 'devtools', title = 'Interior probe', sub = label, chip = chip,
        rows = _hudRows,
    })
    _hudToken = _hudToken + 1
    local mine = _hudToken
    SetTimeout(PROBE_SHOW_MS, function()
        if _hudToken == mine then EditorHud.hide() end
    end)
end

RegisterCommand('propprobe', function(_, args)
    if not Callback('whip_core:devtools:checkAccess') then return end

    local name = args[1]
    local label = args[2] or name or 'interior'

    local report = probe(name)
    print('[whip_core:probe] ' .. tostring(report.verdict))
    if #report.errors > 0 then
        print(('[whip_core:probe] %d native call(s) failed — listed in the saved report'):format(#report.errors))
    end

    -- DRAW THE ROOMS, for twenty seconds. Each room's extents are read as interior-LOCAL and put in
    -- the world with shared/property_math.lua, the same transform every property will be placed
    -- with. So this is the check with your own eyes: if the boxes sit on the walls, the transform
    -- and the "extents are local" reading are both right; if they are turned or shifted, neither is.
    ZonePreview.clearPrefix('probe:')
    local b = report.basis
    if b and b.origin and b.yawFromEx and report.rooms then
        local place = { x = b.origin.x, y = b.origin.y, z = b.origin.z, yaw = b.yawFromEx }
        for _, room in ipairs(report.rooms.list) do
            local locals = PropertyMath.expandSpace({ { type = 'interior' } }, { room })
            local s = locals[1] and PropertyMath.shapeToWorld(place, locals[1])
            if s then
                -- The room you are standing in is blue, the rest grey.
                ZonePreview.set('probe:room:' .. room.index, { s }, {
                    name = room.index == report.rooms.pedRoomIndex and 'current' or 'other',
                    label = ('room %d · %s'):format(room.index, tostring(room.name)),
                    ms = PROBE_SHOW_MS,
                })
            end
        end
    end
    showProbeHud(label, report)

    local body = json.encode(report)
    -- LATENT, because a busy interior's object list runs well past what a plain net event should
    -- carry. The server writes the file and answers with where it went.
    TriggerLatentServerEvent('whip_core:server:propertyProbeSave', 200000, label, body)
    print(('[whip_core:probe] sending %d bytes to the server…'):format(#body))
end, false)

RegisterNetEvent('whip_core:client:propertyProbeSaved', function(ok, where)
    if ok then
        print('[whip_core:probe] saved: ' .. tostring(where))
        UI.Notify('Interior probe saved', 'success')
    else
        print('[whip_core:probe] save FAILED: ' .. tostring(where))
        UI.Notify('Interior probe could not be saved', 'error')
    end
    if _hudRows and EditorHud.isShown() then
        local last = _hudRows[#_hudRows]
        last.value = ok and 'saved' or 'NOT saved'
        last.tone = ok and 'ok' or 'err'
        EditorHud.update({ rows = _hudRows })
    end
end)
