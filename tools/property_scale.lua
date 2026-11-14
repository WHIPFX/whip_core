-- ============================================
-- PROPERTY SCALE — Register here, Stamp mode, Verify
-- ============================================
--
-- The Configurator's tools for a tower rather than a house. An interior set up once is a template
-- (server/properties.lua), so every other copy of it in the world is a placement away from being
-- homes as well:
--
--   REGISTER HERE   stand in a copy of an interior whip knows; its units become properties, named
--                   from a pattern. A few seconds of their spaces in the world confirm it.
--   STAMP MODE      the same, flying: fly through a tower (the noclip camera) and every copy of a
--                   known interior you pass through lights up; E registers it, PgUp/PgDn move the
--                   floor number, Tab and Q the flat numbers. A tower is minutes, not an evening.
--   VERIFY          stand in each property in turn and check the world still matches it: the
--                   interior is there, where it was, with the rooms and doors it had.
--
-- All three are PropertyEditor modes (tools/property_editor.lua): the panel is suspended, the HUD
-- says the keys, Esc leaves, and dying or a restart cannot strand anyone. The server checks every
-- registration and every Verify result (server/property_admin.lua, "Scale").
--
-- NAMES come from a pattern, the same one the page previews (html/js/wp/properties.js):
--
--   {b} building   {u} unit label   {k} unit key   {f} floor   {n} number   {nn} number, two digits
--
-- The number is the start number plus the unit's place in its template (0 for the first), so
-- 'B{f}{nn}' with floor 8 and start 5 names a Mega half-floor's four flats B805 to B808.

PropertyScale = {}

---@class PropertyScaleRegister
---@field active boolean
---@field read boolean           an interior was read here
---@field why? string            why not
---@field templates table[]      whip's templates for it, their units in order
---@field place? table
---@field hash? number
---@field yawOnly? boolean

---@class PropertyScaleStamp
---@field form table             { building, namePattern, labelPattern, floor?, start }
---@field byHash table<number, table>   an interior's hash: its first (oldest) template
---@field here? table            the copy the camera is in: { place, tpl?, count }
---@field made number
---@field busy boolean
---@field nextRead number
---@field last? table            the last registration's answer
---@field pendingStep? number    how far the numbers move on once it is answered

---@class PropertyScaleTour
---@field ids number[]
---@field index number
---@field current? string        the property being checked, by name
---@field state? string          'loading' | 'checking'
---@field ok number
---@field attention number
---@field skipped number
---@field lastProblem? string
---@field paused boolean
---@field skip boolean
---@field stopped boolean
---@field modeLive boolean       its mode is still up (an Esc ends it first)
---@field start table            { x, y, z }: where the tour started, and ends
---@field heading number

---@type PropertyScaleRegister|nil
local reg = nil       -- Register here: what the page shows
---@type PropertyScaleStamp|nil
local stamp = nil     -- Stamp mode, while it runs
---@type PropertyScaleTour|nil
local tour = nil      -- Verify, while it runs

--- Forward-declared: the registration answer (in "Register here") redraws the Stamp HUD, which is
--- written further down.
local stampRows

local function push(kind, payload)
    WhipPanelData('properties', kind, payload)
end

-- ============================================
-- Names
-- ============================================

--- A property's name (or label) from a pattern. The page has a copy of these rules; keep them the
--- same (see the header).
---@param index number  the unit's place in its template, from 0
function PropertyScale.name(pattern, form, unit, index)
    -- Whole numbers, whatever arrives: a number through NUI can be 8.0, which would print as "8.0".
    local n = math.floor(tonumber(form.start) or 1) + index
    local floor = tonumber(form.floor)
    local values = {
        b = form.building or '', u = unit.label or unit.key or '', k = unit.key or '',
        f = floor and tostring(math.floor(floor)) or '', n = tostring(n), nn = ('%02d'):format(n),
    }
    local out = tostring(pattern or ''):gsub('{(%a+)}', function(tok)
        return values[tok] or ('{' .. tok .. '}')
    end)
    out = out:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    return out
end

--- The units of a template as register asks for them, named, in the template's order.
local function unitsFor(units, form, onlyNew)
    local out = {}
    for i, u in ipairs(units) do
        if not (onlyNew and (u.registered or u.clash)) and not (form.skip and form.skip[u.key]) then
            local name = PropertyScale.name(form.namePattern ~= '' and form.namePattern or '{b} {u}', form, u, i - 1)
            local label = form.labelPattern and form.labelPattern ~= '' and PropertyScale.name(form.labelPattern, form, u, i - 1) or nil
            out[#out + 1] = { key = u.key, name = name ~= '' and name or u.label or u.key, label = label }
        end
    end
    return out
end

local function sortUnits(units)
    table.sort(units, function(a, b) return (a.sortOrder or 0) < (b.sortOrder or 0) end)
    return units
end

-- ============================================
-- Register here
-- ============================================

local function readHere()
    local info, why = Interior.read()
    local r = { active = true, read = info ~= nil, why = why, templates = {} }
    reg = r
    if not info then return end
    r.place, r.hash, r.yawOnly = info.place, info.hash, info.yawOnly
    local known = Callback('whip_core:property:adminRegisterInfo', info.place)
    if reg ~= r then return end   -- closed (or read again) while it asked
    for _, t in ipairs((known and known.templates) or {}) do
        sortUnits(t.units)
        r.templates[#r.templates + 1] = t
    end
end

function PropertyScale.pushRegister()
    push('register', reg or { active = false })
end

--- A few seconds of what was just registered, in the world: each new property's space, named.
local function confirm(ids)
    local defs = GetPropertyDefs and GetPropertyDefs() or {}
    local shown = 0
    local started = PropertyEditor.start({
        name = 'Registered',
        hud = {
            title = 'Registered', sub = ('%d propert%s — their spaces, for a moment'):format(#ids, #ids == 1 and 'y' or 'ies'),
            rows = {}, hints = { { key = 'Esc', text = 'Back to the panel' } },
        },
        onFrame = (function()
            local untilAt = GetGameTimer() + 5000
            return function()
                if GetGameTimer() >= untilAt then return 'exit' end
            end
        end)(),
    })
    if not started then return end
    for _, id in ipairs(ids) do
        local p = defs[id]
        if p and p.shapes and #p.shapes > 0 then
            ZonePreview.set('pe:reg:' .. id, p.shapes, { name = 'ok', label = p.name })
            shown = shown + 1
        end
    end
    EditorHud.update({ rows = { { label = 'Shown', value = ('%d of %d'):format(shown, #ids),
                                  tone = shown == #ids and 'ok' or 'warn' } } })
end

RegisterNetEvent('whip_core:client:propertyAdminRegistered', function(res)
    res = type(res) == 'table' and res or {}
    if stamp then
        stamp.last = res
        local made, skipped = #(res.created or {}), #(res.skipped or {})
        stamp.made = stamp.made + made
        -- THE NUMBERS MOVE ON BY THEMSELVES, by as many units as were just named: a row of
        -- one-flat studios is W102, W103, W104 with nothing pressed in between, and a tower's two
        -- half-floors are 01-04 then 05-08 (Q takes them back to 01 on the next floor).
        if made > 0 and stamp.pendingStep then
            stamp.form.start = stamp.form.start + stamp.pendingStep
            EditorHud.update({ rows = stampRows() })
        end
        stamp.pendingStep = nil
        if made > 0 then
            EditorHud.status(('Registered %d%s'):format(made, skipped > 0 and (', ' .. skipped .. ' skipped') or ''), 'ok')
        else
            local why = res.why or (res.skipped and res.skipped[1] and (res.skipped[1].unit .. ': ' .. res.skipped[1].why)) or 'Nothing registered'
            EditorHud.status(why, 'err')
        end
        stamp.busy = false
        return
    end
    push('registered', res)
    if res.created and #res.created > 0 then
        CreateThread(function()
            confirm(res.created)
            while PropertyEditor.isActive() do Wait(200) end
            if reg and reg.active then readHere() PropertyScale.pushRegister() end
        end)
    end
end)

RegisterNUICallback('prStart', function(_, cb)
    readHere()
    PropertyScale.pushRegister()
    cb({ ok = true })
end)

RegisterNUICallback('prRead', function(_, cb)
    readHere()
    PropertyScale.pushRegister()
    if not reg then cb({ ok = false }) return end   -- closed while it read
    cb({ ok = reg.read, why = reg.why })
end)

RegisterNUICallback('prClose', function(_, cb)
    reg = nil
    PropertyScale.pushRegister()
    cb({ ok = true })
end)

RegisterNUICallback('prRegister', function(data, cb)
    if not (reg and reg.read) then cb({ ok = false, why = 'Stand inside the interior and read it first' }) return end
    local t = nil
    for _, x in ipairs(reg.templates) do if x.templateId == tonumber(data and data.templateId) then t = x end end
    if not t then cb({ ok = false, why = 'Pick which of its templates to use' }) return end
    local form = type(data.form) == 'table' and data.form or {}
    local units = unitsFor(t.units, form, true)
    if #units == 0 then cb({ ok = false, why = 'Every unit here is already registered (or skipped)' }) return end
    TriggerServerEvent('whip_core:server:propertyAdminRegister', {
        place = reg.place, templateId = t.templateId, building = form.building, units = units,
    })
    cb({ ok = true })
end)

--- The units of one template, drawn at this placement (and what is registered, in green).
RegisterNUICallback('prShow', function(data, cb)
    cb({ ok = true })
    if not (reg and reg.read) then return end
    local all = Callback('whip_core:property:adminStampTemplates') or {}
    local tpl = nil
    for _, x in ipairs(all) do if x.templateId == tonumber(data and data.templateId) then tpl = x end end
    if not tpl then return end
    local started = PropertyEditor.start({
        name = 'Show units',
        hud = { title = 'Units', sub = tpl.label or 'Interior', rows = { { label = 'Units', value = #tpl.units } },
                hints = { { key = 'Esc', text = 'Back to the panel' } } },
    })
    if not started then return end
    for i, u in ipairs(tpl.units) do
        local w = PropertyMath.unitToWorld(reg.place, { space = u.space }, tpl.rooms)
        if #w.shapes > 0 then
            ZonePreview.set('pe:unit:' .. i, w.shapes, { name = i % 2 == 0 and 'current' or 'draft', label = u.label or u.key })
        end
    end
end)

-- ============================================
-- Stamp mode
-- ============================================
--
-- THE PED GOES WITH THE CAMERA, every few hundred milliseconds, because the ped's own interior is
-- the reading the probe proved (docs/properties-probe.md §9). A copy of an interior is recognised
-- by its archetype hash against every template, and it is "done" when properties stand at its
-- placement for all of that template's units.

local STAMP_READ_MS = 300

local function registeredHere(place)
    local n = 0
    for _, p in pairs(GetPropertyDefs and GetPropertyDefs() or {}) do
        if p.place and PropertyMath.samePlacement(p.place, place) then n = n + 1 end
    end
    return n
end

function stampRows()
    local s = stamp --[[@as PropertyScaleStamp]]
    local here = s.here
    local rows = {}
    if not here then
        rows[#rows + 1] = { label = 'Here', value = 'no interior — fly into one' }
    elseif not here.tpl then
        rows[#rows + 1] = { label = 'Here', value = 'an interior whip has no template for', tone = 'warn' }
    else
        local total = #here.tpl.units
        rows[#rows + 1] = { label = 'Interior', value = here.tpl.label or ('#' .. here.tpl.templateId) }
        rows[#rows + 1] = { label = 'Registered', value = ('%d of %d'):format(here.count, total),
                            tone = here.count >= total and 'ok' or 'warn' }
        local names = unitsFor(here.tpl.units, s.form, false)
        if #names > 0 then
            rows[#rows + 1] = { label = 'Names', value = #names == 1 and names[1].name
                                or (names[1].name .. '  …  ' .. names[#names].name) }
        end
    end
    rows[#rows + 1] = { label = 'Floor', value = s.form.floor and tostring(math.floor(s.form.floor)) or '—' }
    rows[#rows + 1] = { label = 'Numbers from', value = tostring(math.floor(s.form.start)) }
    rows[#rows + 1] = { label = 'This session', value = ('%d registered'):format(s.made) }
    return rows
end

local function stopStamp()
    if not stamp then return end
    local s = stamp
    stamp = nil
    CreateThread(function()
        FreeCam.stop({ movePed = true })
        push('stampDone', { made = s.made })
        if reg and reg.active then readHere() PropertyScale.pushRegister() end
    end)
end

local function startStamp(form)
    if FreeCam.isActive() then return false, 'Leave noclip first — Stamp mode flies its own camera' end
    local all = Callback('whip_core:property:adminStampTemplates') or {}
    local byHash = {}
    for _, t in ipairs(all) do
        sortUnits(t.units)
        byHash[t.hash] = byHash[t.hash] or t   -- the first (oldest) template for an interior
    end
    if next(byHash) == nil then return false, 'No interior has a template yet — set one up first' end

    form.start = math.floor(tonumber(form.start) or 1)
    local floor = tonumber(form.floor)
    form.floor = floor and math.floor(floor) or nil
    stamp = { form = form, byHash = byHash, here = nil, made = 0, busy = false, nextRead = 0 }

    local started = PropertyEditor.start({
        name = 'Stamp mode',
        hud = {
            title = 'Stamp', sub = (form.building ~= '' and form.building or 'No building') .. ' — fly through it',
            rows = stampRows(),
            hints = {
                { key = 'WASD', text = 'Fly · Space/Ctrl up/down' },
                { key = 'E', text = 'Register this one' },
                { key = 'PgUp / PgDn', text = 'Floor' },
                { key = 'Tab / Q', text = 'Next / previous numbers (they move on after each E)' },
                { key = 'Esc', text = 'Done' },
            },
        },
        onExit = function() stopStamp() end,
        -- PgUp / PgDn (the floor) and E (register), held off for the mode by its block
        block = { controls = { 10, 11, 38 } },
        onFrame = function()
            local s = stamp
            if not s then return 'exit' end
            local now = GetGameTimer()
            if now >= s.nextRead then
                s.nextRead = now + STAMP_READ_MS
                local ped = PlayerPedId()
                local c = FreeCam.getCoord()
                SetEntityCoordsNoOffset(ped, c.x, c.y, c.z, false, false, false)
                local id = GetInteriorFromEntity(ped)
                ZonePreview.clearPrefix('pe:stamp:')
                if id and id ~= 0 then
                    local place = Interior.placementOf(id)
                    local tpl = s.byHash[place.hash]
                    s.here = { place = place, tpl = tpl, count = registeredHere(place) }
                    if tpl then
                        local done = s.here.count >= #tpl.units
                        for i, u in ipairs(tpl.units) do
                            local w = PropertyMath.unitToWorld(place, { space = u.space }, tpl.rooms)
                            if #w.shapes > 0 then
                                ZonePreview.set('pe:stamp:' .. i, w.shapes, { name = done and 'ok' or 'draft',
                                                                           label = u.label or u.key })
                            end
                        end
                    end
                else
                    s.here = nil
                end
                EditorHud.update({ rows = stampRows() })
            end

            if IsDisabledControlJustPressed(0, 10) then
                s.form.floor = (s.form.floor or 0) + 1
                EditorHud.update({ rows = stampRows() })
            elseif IsDisabledControlJustPressed(0, 11) then
                s.form.floor = (s.form.floor or 1) - 1
                EditorHud.update({ rows = stampRows() })
            end
            local step = (s.here and s.here.tpl and #s.here.tpl.units) or 1
            if IsDisabledControlJustPressed(0, 37) then
                s.form.start = s.form.start + step
                EditorHud.update({ rows = stampRows() })
            elseif IsDisabledControlJustPressed(0, 44) then
                s.form.start = math.max(0, s.form.start - step)
                EditorHud.update({ rows = stampRows() })
            end

            if IsDisabledControlJustPressed(0, 38) then
                local here = s.here
                if not (here and here.tpl) then
                    EditorHud.status('Fly into a copy of an interior whip knows first', 'warn')
                elseif here.count >= #here.tpl.units then
                    EditorHud.status('This one is registered already', 'warn')
                elseif s.busy then
                    EditorHud.status('Still registering the last one', 'warn')
                else
                    s.busy = true
                    s.pendingStep = #here.tpl.units
                    -- Every unit is sent: the server skips the ones already registered, and says so.
                    TriggerServerEvent('whip_core:server:propertyAdminRegister', {
                        place = here.place, templateId = here.tpl.templateId, building = s.form.building,
                        units = unitsFor(here.tpl.units, s.form, false),
                    })
                end
            end
        end,
    })
    if not started then stamp = nil return false, 'Could not start' end
    FreeCam.start({ hidePed = true })
    return true
end

RegisterNUICallback('prStamp', function(data, cb)
    local form = type(data and data.form) == 'table' and data.form or {}
    local ok, why = startStamp({
        building = type(form.building) == 'string' and form.building or '',
        namePattern = type(form.namePattern) == 'string' and form.namePattern or '{b} {u}',
        labelPattern = type(form.labelPattern) == 'string' and form.labelPattern or '',
        floor = form.floor, start = form.start,
    })
    cb({ ok = ok ~= false, why = why })
end)

-- ============================================
-- Verify
-- ============================================
--
-- ONE PROPERTY AT A TIME, IN ITS OWN THREAD, because every step waits on the world: teleport to
-- its stand-in point, wait for its interior to load (pinned, eight seconds at most), then check.
-- The mode's frame only reads the keys — Space pauses, Right arrow skips, Esc stops — and keeps the
-- HUD current.
--
-- WHAT IS CHECKED, standing there:
--   the interior    one is here, it is the same archetype, and it stands where the property says
--                   (within 25 cm and half a degree — further means Re-bind)
--   its rooms       the same number of rooms and doorways as when its template was made
--   its doors       an object of each managed door's model at each door's position
--   its space       resolved: a property whose space is "the whole interior" on a template with no
--                   rooms yet sends the rooms it reads, and the server keeps them
-- and the server checks the stand-in point is inside the space.

local VERIFY_LOAD_MS = 8000

local function verifyOne(info)
    ---@cast tour -nil
    local ped = PlayerPedId()
    local v = info.visit or info.anchor or info.place
    RequestCollisionAtCoord(v.x, v.y, v.z)
    -- As the panel's Go inside does (tools/panel_sections/properties.lua), and held there.
    SetEntityCoords(ped, v.x, v.y, v.z + 0.1, false, false, false, false)
    PedHold.set('propertyTour', { frozen = true })   -- client/ped_hold.lua

    local world = (info.place.hash or 0) == 0
    local deadline = GetGameTimer() + VERIFY_LOAD_MS
    local id = 0
    tour.state = 'loading'
    while GetGameTimer() < deadline do
        if tour.skip or tour.stopped then return nil end
        if world then
            if HasCollisionLoadedAroundEntity(ped) then break end
        else
            id = GetInteriorFromEntity(ped)
            if id ~= 0 then
                if IsInteriorReady(id) then break end
                PinInteriorInMemory(id)
            end
        end
        Wait(100)
    end
    tour.state = 'checking'
    Wait(500)   -- the doors stream in a moment after the interior

    local problems, extra = {}, {}
    if not world then
        id = GetInteriorFromEntity(ped)
        if id == 0 then
            problems[#problems + 1] = 'there is no interior here — is its MLO running?'
            return problems, extra
        end
        local here = Interior.placementOf(id)
        if here.hash ~= info.place.hash then
            problems[#problems + 1] = ('a different interior stands here (%d)'):format(here.hash)
            return problems, extra
        end
        local same, dist, dyaw = PropertyMath.samePlacement(here, info.place, 0.25, 0.5)
        if not same then
            problems[#problems + 1] = ('its interior has moved %.2f m and %.1f° — Re-bind it'):format(dist, dyaw)
        end
        local rooms, portals = GetInteriorRoomCount(id) or 0, GetInteriorPortalCount(id) or 0
        local fp = info.fingerprint
        if fp and ((fp.rooms and fp.rooms ~= rooms) or (fp.portals and fp.portals ~= portals)) then
            -- What to do about it, in the words: Re-bind takes the layout as it is now.
            problems[#problems + 1] = ('the MLO has changed: %d rooms and %d doorways, it had %d and %d — Re-bind it to take the new layout')
                :format(rooms, portals, fp.rooms or rooms, fp.portals or portals)
        end
        if same and info.symbolic and not info.roomsKnown then
            local read = Interior.read()
            if read and read.hash == info.place.hash then
                extra.rooms = read.rooms
                extra.fingerprint = { rooms = read.roomCount, portals = read.portalCount }
            end
        end
    end
    for _, d in ipairs(info.doors or {}) do
        local obj = GetClosestObjectOfType(d.x, d.y, d.z, 0.6, d.model, false, false, false)
        if not obj or obj == 0 then
            problems[#problems + 1] = ('door "%s" is not where it should be'):format(tostring(d.key))
        end
    end
    return problems, extra
end

local function tourRows()
    local t = tour --[[@as PropertyScaleTour]]
    local rows = {
        { label = 'OK', value = t.ok, tone = t.ok > 0 and 'ok' or nil },
        { label = 'Needs attention', value = t.attention, tone = t.attention > 0 and 'err' or nil },
        { label = 'Skipped', value = t.skipped },
        { label = 'Now', value = t.paused and 'paused' or t.state or '—' },
    }
    if t.lastProblem then rows[#rows + 1] = { label = 'Last problem', value = t.lastProblem, tone = 'err' } end
    return rows
end

local function runTour()
    local t = tour --[[@as PropertyScaleTour]]
    for i, id in ipairs(t.ids) do
        if t.stopped then break end
        while t.paused and not t.stopped do Wait(100) end
        if t.stopped then break end
        t.skip = false
        t.index = i
        local info = Callback('whip_core:property:adminVerifyInfo', id)
        if not info then
            t.skipped = t.skipped + 1
        else
            t.current = info.name
            EditorHud.update({ sub = info.name, progress = { done = i - 1, total = #t.ids }, rows = tourRows() })
            local problems, extra = verifyOne(info)
            if problems == nil then
                t.skipped = t.skipped + 1
            else
                ---@cast extra -nil
                TriggerServerEvent('whip_core:server:propertyAdminVerified', id,
                    { problems = problems, rooms = extra.rooms, fingerprint = extra.fingerprint })
                if #problems == 0 then
                    t.ok = t.ok + 1
                else
                    t.attention = t.attention + 1
                    t.lastProblem = ('%s: %s'):format(info.name, problems[1])
                end
            end
        end
        EditorHud.update({ progress = { done = i, total = #t.ids }, rows = tourRows() })
        Wait(300)
    end

    -- Back where the tour started, whether it finished or was stopped.
    local ped = PlayerPedId()
    RequestCollisionAtCoord(t.start.x, t.start.y, t.start.z)
    SetEntityCoordsNoOffset(ped, t.start.x, t.start.y, t.start.z, false, false, false)
    SetEntityHeading(ped, t.heading)
    PedHold.release('propertyTour')   -- its own hold only: a downed player stays frozen
    local summary = { checked = t.ok + t.attention, ok = t.ok, attention = t.attention, skipped = t.skipped,
                      stopped = t.stopped == true }
    tour = nil
    -- Only this tour's own mode: after an Esc it has already gone, and whatever mode is up now is
    -- somebody else's.
    if t.modeLive then PropertyEditor.stop('done') end
    push('verifyDone', summary)
end

local function startTour(ids)
    if tour then return false, 'Verify is already running' end
    if #ids == 0 then return false, 'Nothing to verify' end
    local ped = PlayerPedId()
    local c = GetEntityCoords(ped)
    tour = { ids = ids, ok = 0, attention = 0, skipped = 0, paused = false, skip = false, stopped = false,
             start = { x = c.x, y = c.y, z = c.z }, heading = GetEntityHeading(ped), index = 0, modeLive = true }

    local started = PropertyEditor.start({
        name = 'Verify',
        hud = {
            title = ('Verify %d'):format(#ids), sub = 'Starting…',
            progress = { done = 0, total = #ids },
            rows = tourRows(),
            hints = {
                { key = 'Space', text = 'Pause / go on' },
                { key = '→', text = 'Skip this one' },
                { key = 'Esc', text = 'Stop' },
            },
        },
        onExit = function()
            if tour then tour.stopped = true tour.modeLive = false end
        end,
        -- Space (pause) and the right arrow (skip), held off for the mode by its block
        block = { controls = { 22, 175 } },
        onFrame = function()
            if not tour then return 'exit' end
            if IsDisabledControlJustPressed(0, 22) then
                tour.paused = not tour.paused
                EditorHud.update({ rows = tourRows() })
            end
            if IsDisabledControlJustPressed(0, 175) then tour.skip = true end
        end,
    })
    if not started then tour = nil return false, 'Could not start' end
    CreateThread(runTour)
    return true
end

RegisterNUICallback('pvStart', function(data, cb)
    local ids = {}
    for _, v in ipairs(type(data and data.ids) == 'table' and data.ids or {}) do
        local id = tonumber(v)
        if id then ids[#ids + 1] = id end
    end
    local ok, why = startTour(ids)
    cb({ ok = ok ~= false, why = why })
end)
