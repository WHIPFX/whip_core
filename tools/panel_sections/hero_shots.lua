-- ============================================
-- /whip Config → Character screen: a hero shot made in the world
-- ============================================
--
-- "Edit in world" on the page's hero shots (html/js/wp/config.js, widget 'heroShots') comes here with the shot
-- as the page has it, unsaved edits too. The panel steps aside and the world builder (client/property_furnish.lua,
-- Furnisher.open) opens AT the shot: looking through its camera, its character on its mark (a copy of you, posed
-- as the shot poses them, standing in for each player's), its props around them, under its sky.
--
--   the character and the props    moved and turned with the builder's markers, like furniture
--   more props                     from the catalog (the one the furnisher has: every model checked)
--   the camera                     fly to the view you want and press "Use this view"; until then the shot
--                                  keeps its camera
--   the pose                       "Pose" opens the emote menu over the editor (Emotes.pickFor): each
--                                  emote clicked plays on the character at once, Stop stands
--                                  them normally, Esc goes back to the shot
--   Done                           the shot goes back to the page as an edit waiting for Apply ('heroShotEdited')
--   Exit                           leaves the shot as it was
--
-- Nothing is saved here, as with Place camera: Apply sends the whole list and the server checks it
-- (shared/settings.lua, 'heroShots'). The sky is the page's own fields; the emote is either.

local CHARACTER = 'hero'   -- the character's id among the builder's things
local MAX_PROPS = 60       -- as the setting allows (shared/config_schema.lua, maxProps)

---@class HeroShotEdit
---@field section string
---@field index integer
---@field shot table
---@field camera table
---@field held table
---@field ped integer|nil
---@field turn integer|nil
---@field posedTurn integer|nil
---@field made boolean|nil

---@type HeroShotEdit|nil
local editing = nil   -- { section, index, shot, camera, held, ped } while a shot is open

local function r2(n) return math.floor((tonumber(n) or 0.0) * 100 + 0.5) / 100 end

--- A position the page can read back: plain numbers, two places.
local function plain(v, withW)
    local out = { x = r2(v.x), y = r2(v.y), z = r2(v.z) }
    if withW then out.w = r2(v.w) end
    return out
end

--- Take away what the character holds (an emote's props).
local function dropHeld(e)
    for _, obj in ipairs(e.held or {}) do
        if DoesEntityExist(obj) then DeleteEntity(obj) end
    end
    e.held = {}
end

--- Pose the character again, as the shot now says, where they stand now (they may have been moved).
---
--- ONE POSE AT A TIME WINS. Each pick is its own NUI callback, and posing waits while a prop's
--- model and the animation load, so a second pick can start before the first is done. Each pose takes a turn;
--- one that finishes after a newer turn began deletes the props it made and leaves the ped to the newer pose.
local function repose()
    local e = editing
    local ped = e and e.ped
    if not ped or not DoesEntityExist(ped) then
        UI.Notify('The character is not in the shot: Exit and edit it again to bring them back', 'error', 4000)
        return
    end
    ---@cast e -nil   (the ped came from it)
    e.turn = (e.turn or 0) + 1
    local turn = e.turn
    dropHeld(e)
    ClearPedTasksImmediately(ped)
    local c = GetEntityCoords(ped)
    local held = CharSelect.poseShot(ped, e.shot, { x = c.x, y = c.y, z = c.z + CharSelect.TIMES.markZ, w = GetEntityHeading(ped) }) or {}
    if editing ~= e or e.turn ~= turn then
        for _, obj in ipairs(held) do
            if DoesEntityExist(obj) then DeleteEntity(obj) end
        end
        -- The newer pose finished first, and this one's animation then started over it: put the newer one back.
        if editing == e and e.posedTurn == e.turn then repose() end
        return
    end
    e.held = held
    e.posedTurn = turn
end

--- An emote picked in the menu (nil: Stop) becomes the shot's pose, the animation or scenario it had going with
--- it, and the character takes it at once.
local function poseWith(cmd)
    if not editing then return end
    editing.shot.emote = cmd
    editing.shot.anim, editing.shot.scenario = nil, nil
    repose()
end

--- Done, Exit, or a failed open: what the shot borrowed goes back, and the panel returns.
local function finish()
    local e = editing
    if not e then return end
    editing = nil
    -- The emote menu, if it was posing them (the editor closed under it: death, logout).
    if Emotes and Emotes.isPicking and Emotes.isPicking() then Emotes.closeMenu() end
    dropHeld(e)
    if WeatherLayer then WeatherLayer.set('heroedit', nil) end
    WhipPanelResume()
    -- Said once the panel is back, where it can be read.
    if e.made then WhipPanelResult(('Hero shot %d made: Apply to keep it.'):format(e.index), 'ok') end
end

RegisterNUICallback('cfgHeroEdit', function(data, cb)
    cb('ok')
    if editing or type(data) ~= 'table' then return end
    local index = math.tointeger(tonumber(data.index))
    local shot = type(data.shot) == 'table' and data.shot or nil
    local pos = shot and shot.pos
    local cam = shot and shot.camera
    if not index or not (type(pos) == 'table' and tonumber(pos.x)) or not (type(cam) == 'table' and type(cam.pos) == 'table') then
        WhipPanelResult('That shot has no place or camera to open at', 'err')
        return
    end
    ---@cast shot table   (pos came from it)
    if not Furnisher or not Furnisher.open then return end

    editing = {
        section = type(data.section) == 'string' and data.section or 'config',
        index = index,
        shot = shot,
        camera = { pos = cam.pos, rot = cam.rot, fov = tonumber(cam.fov) or 40.0 },
        held = {},
    }
    WhipPanelSuspend()
    if WeatherLayer then WeatherLayer.set('heroedit', type(shot.look) == 'table' and shot.look or nil) end

    -- The character first (a copy of you: the builder's 'hero' kind), then the scene. The model only names the
    -- body for the builder's box; the copy is your own ped.
    local female = GetEntityModel(PlayerPedId()) == GetHashKey('mp_f_freemode_01')
    local rows = {
        { model = female and 'mp_f_freemode_01' or 'mp_m_freemode_01',
          x = pos.x + 0.0, y = pos.y + 0.0, z = pos.z + 0.0, rz = (tonumber(pos.w) or 0.0) + 0.0,
          extra = { id = CHARACTER, kind = 'hero', label = 'Character' } },
    }
    for _, p in ipairs(type(shot.props) == 'table' and shot.props or {}) do
        rows[#rows + 1] = { model = p.model, x = p.x, y = p.y, z = p.z, rx = p.rx, ry = p.ry, rz = p.rz }
    end

    local ok, why = Furnisher.open({
        title = ('Hero shot %d'):format(index),
        noun = 'The hero shot editor',
        rows = rows,
        camera = editing.camera,
        page = { tabs = { 'catalog', 'placed' }, done = 'Done', byName = true,
                 actions = { { id = 'pose', label = 'Pose' }, { id = 'useView', label = 'Use this view' } } },
        -- The stand-in takes the shot's pose where it stands, and is kept to pose again (Pose).
        onSpawn = function(it, ent)
            if not editing or type(it.extra) ~= 'table' or it.extra.id ~= CHARACTER then return end
            editing.ped = ent
            local at = { x = it.x, y = it.y, z = it.z + CharSelect.TIMES.markZ, w = it.rz or 0.0 }
            editing.held = CharSelect.poseShot(ent, editing.shot, at) or {}
        end,
        onAction = function(id)
            if not editing then return end
            if id == 'pose' then
                -- The emote menu over the editor; each pick poses the character at once.
                if not (Emotes and Emotes.pickFor and Emotes.pickFor(poseWith, { current = editing.shot.emote })) then
                    UI.Notify('The emote menu is already open', 'error', 3000)
                end
                return
            end
            if id ~= 'useView' then return end
            local p, r = FreeCam.getCoord(), FreeCam.getRot()
            local f = FreeCam.getFov()
            editing.camera = { pos = plain(p), rot = { x = r2(r.x), y = 0.0, z = r2(r.z) }, fov = r2(f) }
            UI.Notify('This view is the shot\'s camera now. Done keeps it.', 'success', 3000)
        end,
        onDone = function(payload)
            if not editing then return end
            local character, props = nil, {}
            for _, p in ipairs(type(payload) == 'table' and payload or {}) do
                local x = type(p.extra) == 'table' and p.extra or {}
                if x.id == CHARACTER then
                    character = p
                elseif type(p.model) == 'string' and #props < MAX_PROPS then
                    props[#props + 1] = {
                        model = p.model, x = r2(p.x), y = r2(p.y), z = r2(p.z),
                        rx = r2(p.rx), ry = r2(p.ry), rz = r2(p.rz),
                    }
                end
            end
            local out = {}
            for k, v in pairs(editing.shot) do out[k] = v end
            out.camera = editing.camera
            -- The character removed in the builder keeps the shot's mark.
            if character then
                out.pos = { x = r2(character.x), y = r2(character.y), z = r2(character.z), w = r2((tonumber(character.rz) or 0.0) % 360.0) }
            end
            out.props = props
            WhipPanelData(editing.section, 'heroShotEdited', { index = editing.index, shot = out })
            editing.made = true
        end,
        onClose = function() finish() end,
    })
    if not ok then
        finish()
        WhipPanelResult(why or 'The hero shot editor could not open', 'err')
    end
end)
