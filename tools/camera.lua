-- Camera Creator: a timeline of camera shots. Fly a free camera, place keys on a timeline and say how the camera gets
-- from one to the next. Each key is a shot (shared/cam_sequence.lua, client/cam_shots.lua): fixed, an orbit round a
-- subject, a chase, mounted, or tracking from one spot. Between keys the camera cuts, glides, springs or swings round.
-- Save a sequence by name for anyone to play (server/camera_sequences.lua), or copy it as code.
-- The screen is html/js/cam-editor.js; it draws, and this file decides (sequence, playhead, what is picked).
-- Mouse: the pointer works the timeline; the camera turns and flies (WASD) only while the right button is held.
-- Controller: sticks fly at all times; A adds a key, X sets the picked key to the camera, Y deletes it, D-pad left
-- and right pick the previous and next key, up and down zoom, RB plays and pauses, the view button looks through the
-- timeline (held hides the HUD), R3 changes the shot kind, menu saves, B leaves.
-- Controls (Tab, the dock's switch, LB + R3) go to the camera (nothing reaches your character) or the game.
-- Hide points (P) stops drawing camera points and the path; Hide HUD (H) leaves only the picture; Exit leaves.
-- The draft is kept for the next opening and written to this PC (a resource KVP); saving to the server is separate.

local MAX_UNDO   = 60
local DRAFT_KVP  = 'whip:cameraCreator:draft'
local KEY_STEP   = 2000     -- ms: a key added at the end moves the playhead on this far, ready for the next
local SAMPLE_MS  = 100      -- the path's drawing: one point a tenth of a second along the timeline
local MAX_SAMPLES = 900

-- The editor's state.
local S = {
    open = false,
    seq = nil,            -- the draft, as the page edits it (raw); always valid once it has a key
    clean = nil,          -- CamSequence.clean(seq)
    run = nil,            -- a run of `clean` for the picture at the playhead
    ver = 0,              -- moved on at every change (the path's drawing is worked out again)
    subjects = {},        -- { target = entity }: the thing picked to frame
    targetName = nil,     -- what it is, for the page
    sel = nil,            -- the picked key
    playhead = 0.0,       -- ms
    playing = false,
    view = false,         -- looking through the timeline (else flying)
    newKind = 'fixed',
    newSubject = 'vehicle',
    undo = {}, redo = {},
    savedAs = nil,        -- the name it was last saved or opened as
    dirty = false,        -- changed since then
    looking = false,      -- right mouse held: the camera has the mouse
    pad = false,          -- a controller is the device
    typing = false,       -- a text box on the page has focus
    filter = 'none',      -- the timecycle filter shown while looking through
    hideHud = false,      -- nothing on screen but the picture (Hide HUD)
    hidePoints = false,   -- the camera points and the path not drawn in the world
    drive = false,        -- the game has the controls (you drive and walk), not the camera
    heldVeh = nil,        -- the car held still while the camera has the controls
    -- Playing in game (below): the editor put away, the player playing, the shots ready to roll.
    game = nil,           -- nil, 'play' (the game's camera) or 'live' (a shot rolling)
    liveCam = nil,        -- the camera held live (PgUp / PgDn / Num 1-9), or nil for the timeline
    modeAt = 0,           -- when the editor last opened or closed (a key held across the change acts once)
    smooth = false,       -- this PC's choice: switching cameras glides rather than cuts
    cleanAll = true,      -- this PC's choice: a clean screen the whole time you play, not only while a shot rolls
}

local PREFS_KVP = 'whip:cameraCreator:prefs'

--- Is the Camera Creator up? client/inventory.lua's screensOpen counts it with the other in-world editors.
CameraCreatorActive = false

-- ============================================
-- The draft
-- ============================================

local function copy(t) return json.decode(json.encode(t)) end

---@return table
local function emptySeq() return { keys = {}, length = 0, ease = 'linear' } end

-- Where the anchor (Plays round) last stood, kept with the draft: when its subject is not there (the car
-- gone, or none yet after a restart), the cameras that play round it stay where they were, rather than
-- their offsets being read as places in the world (which threw them far away).
local lastAnchor = nil

local function writeDraft()
    SetResourceKvp(DRAFT_KVP, json.encode({ seq = S.seq, savedAs = S.savedAs, dirty = S.dirty, anchorAt = lastAnchor }))
end

local draftQueued = false
--- Keep the draft on this PC, a moment after the last change (a drag sends many).
local function keepDraft()
    if draftQueued then return end
    draftQueued = true
    SetTimeout(1000, function()
        draftQueued = false
        writeDraft()
    end)
end

--- A whole-timeline pace (`ease` on the sequence) bends time, so keys no longer happen where the timeline
--- shows them (the playhead between 6 and 7, the camera at 9 and 10). The editor's sequences have none:
--- each glide has its own pace. Scripts may still give one (PlayCameraPath's easing).
local function straightTime(seq)
    if seq.ease and seq.ease ~= 'linear' then
        seq.ease = 'linear'
        return true
    end
    return false
end

local function loadDraft()
    local raw = GetResourceKvpString(DRAFT_KVP)
    if not raw or raw == '' then return end
    local ok, d = pcall(json.decode, raw)
    if ok and type(d) == 'table' and type(d.seq) == 'table' then
        S.seq = d.seq
        S.savedAs = type(d.savedAs) == 'string' and d.savedAs or nil
        S.dirty = d.dirty == true
        local a = d.anchorAt
        if type(a) == 'table' and tonumber(a.x) and tonumber(a.y) and tonumber(a.z) and tonumber(a.h) then
            lastAnchor = { x = a.x + 0.0, y = a.y + 0.0, z = a.z + 0.0, h = a.h + 0.0 }
        end
        if straightTime(S.seq) then S.dirty = true end
    end
end

--- This PC's playing choices (switching, clean screen).
local function loadPrefs()
    local raw = GetResourceKvpString(PREFS_KVP)
    if not raw or raw == '' then return end
    local ok, d = pcall(json.decode, raw)
    if not ok or type(d) ~= 'table' then return end
    if type(d.smooth) == 'boolean' then S.smooth = d.smooth end
    if type(d.cleanAll) == 'boolean' then S.cleanAll = d.cleanAll end
end

local function savePrefs()
    SetResourceKvp(PREFS_KVP, json.encode({ smooth = S.smooth, cleanAll = S.cleanAll }))
end

--- Work the sequence out again after a change: its clean copy, a fresh run, the anchor as it stands now.
local function rebuild()
    S.ver = S.ver + 1
    local keys = S.seq.keys
    local last = #keys > 0 and keys[#keys].t or 0
    for _, k in ipairs(keys) do if k.t > last then last = k.t end end
    if (S.seq.length or 0) < last then S.seq.length = last end
    if #keys == 0 then
        S.clean, S.run = nil, nil
        return true
    end
    local clean, why = CamSequence.clean(S.seq)
    if not clean then return false, why end
    S.clean = clean
    -- The editor's keys are kept in time order, as clean sorts them, so a key's number is its place.
    S.seq.keys = copy(clean.keys)
    S.run = CamSequence.newRun(clean, S.subjects)
    CamSequence.captureAnchor(S.run)
    if S.run.anchor then
        lastAnchor = { x = S.run.anchor.x, y = S.run.anchor.y, z = S.run.anchor.z, h = S.run.anchor.h }
    elseif clean.anchor and lastAnchor then
        S.run.anchor = lastAnchor
    end
    return true
end

-- ============================================
-- Talking to the page
-- ============================================

local function say(text, kind)
    SendNUIMessage({ action = 'camEdSay', text = text, kind = kind or 'info' })
end

--- Everything the page draws, on any change that is not just the time.
local function sendState()
    SendNUIMessage({
        action = 'camEdState',
        seq = S.seq, sel = S.sel, playhead = S.playhead, playing = S.playing, view = S.view,
        newKind = S.newKind, newSubject = S.newSubject, savedAs = S.savedAs, dirty = S.dirty,
        canUndo = #S.undo > 0, canRedo = #S.redo > 0, looking = S.looking, pad = S.pad,
        target = S.targetName, filters = Camera.Filters, hideHud = S.hideHud, hidePoints = S.hidePoints,
        smooth = S.smooth, cleanAll = S.cleanAll, drive = S.drive,
    })
end

local function sendTime()
    SendNUIMessage({ action = 'camEdTime', playhead = S.playhead, playing = S.playing, view = S.view })
end

--- Make a change: the draft as it was goes on the undo list, `fn` changes it, and it must still be a
--- sequence the camera can play — or the change is taken back and the page told why.
local function change(fn, quiet)
    local before = copy(S.seq)
    local selBefore = S.sel
    local ok, why = fn()
    if ok == false then
        S.seq, S.sel = before, selBefore
        rebuild()
        if why then say(why, 'warn') end
        sendState()
        return false
    end
    local built, buildWhy = rebuild()
    if not built then
        S.seq, S.sel = before, selBefore
        rebuild()
        say(buildWhy or 'That would not play', 'warn')
        sendState()
        return false
    end
    S.undo[#S.undo + 1] = { seq = before, sel = selBefore }
    if #S.undo > MAX_UNDO then table.remove(S.undo, 1) end
    S.redo = {}
    S.dirty = true
    keepDraft()
    if not quiet then sendState() end
    return true
end

-- ============================================
-- The camera
-- ============================================

--- Where the free camera is now, as a pose.
local function camNow()
    local p, r = FreeCam.getCoord(), FreeCam.getRot()
    local fov = FreeCam.getFov()
    return { x = p.x, y = p.y, z = p.z, pitch = r.x, roll = r.y, yaw = r.z, fov = fov }
end

--- A subject's live state for the editor (the run's when there is one, else a probe of its own).
local probe = { subjects = S.subjects, frame = 0 }
local function subjectNow(name)
    probe.subjects = S.subjects
    probe.frame = probe.frame + 1
    return CamShots.subject(probe, name)
end

--- What a new or changed key is placed round, when the sequence plays round something: the run's anchor;
--- with no run yet (an empty timeline) where its subject is now; else where it last stood. Never the world
--- while the sequence plays round something: the first key of an empty timeline was put down in the
--- world's numbers and read back as an offset from the car — hundreds of metres away, and key 1.
local function editAnchor()
    if S.run and S.run.anchor then return S.run.anchor end
    local name = S.seq and S.seq.anchor
    if not name then return nil end
    local s = subjectNow(name)
    if s then return { x = s.x, y = s.y, z = s.z, h = s.h } end
    return lastAnchor
end

local SUBJECT_WORDS = { player = 'you', vehicle = 'your vehicle', target = 'the picked thing' }

--- A shot of `kind` where the camera is now, round `subject` (a chase starts from its usual numbers).
---@return table|nil shot, string|nil why
local function shotHere(kind, subject)
    local cam = camNow()
    local anchor = editAnchor()
    -- A fixed or roadside camera's place is kept round the anchor: with none known, it has nowhere to go.
    if (kind == 'fixed' or kind == 'track') and S.seq.anchor and not anchor then
        return nil, ('%s %s not there, and these cameras are placed round it'):format(
            SUBJECT_WORDS[S.seq.anchor] or S.seq.anchor, S.seq.anchor == 'player' and 'are' or 'is')
    end
    if kind == 'fixed' then return CamShots.fixedFromCamera(cam, anchor) end
    local s = subjectNow(subject)
    if not s then
        return nil, ('%s %s not there'):format(SUBJECT_WORDS[subject] or subject, subject == 'player' and 'are' or 'is')
    end
    local shot
    if kind == 'orbit' then shot = CamShots.orbitFromCamera(s, cam, nil, true)
    elseif kind == 'track' then shot = CamShots.trackFromCamera(s, cam, nil, anchor)
    elseif kind == 'mounted' then shot = CamShots.mountedFromCamera(s, cam)
    elseif kind == 'chase' then shot = { kind = 'chase', dist = 5.0, height = 1.8, ahead = 3.5, slip = 0.35, stiff = 7.0, fov = 50.0 }
    else return nil, 'Not a kind of shot' end
    shot.subject = subject
    return shot
end

--- A key's picture at its own time (for its marker in the world, and "look through").
local scratchMem = {}
local function keyPose(i)
    local k = S.clean and S.clean.keys[i]
    if not k or not S.run then return nil end
    S.run.frame = S.run.frame + 1
    scratchMem[i] = scratchMem[i] or {}
    return CamShots.evaluate(S.run, k.shot, 0.0, scratchMem[i], 1.0)
end

--- Fly on from where the timeline's picture is.
local function stopViewing()
    if not S.view then return end
    S.view = false
    FreeCam.hold(false)
    if S.filter ~= 'none' then ClearTimecycleModifier(); S.filter = 'none' end
    sendTime()
end

local function startViewing()
    if S.view or not S.run then return end
    S.view = true
    FreeCam.hold(true)
    sendTime()
end

local function setFilter(name)
    name = name or 'none'
    if name == S.filter then return end
    if S.filter ~= 'none' then ClearTimecycleModifier() end
    S.filter = name
    if name ~= 'none' then
        SetTimecycleModifier(name)
        SetTimecycleModifierStrength(1.0)
    end
end

--- The timeline's picture at the playhead, onto the camera.
local function showPlayhead(dt)
    if not S.run then return end
    local pose, fx = CamSequence.evaluate(S.run, S.playhead, dt)
    if not pose then return end
    local sp, sr, sy = 0.0, 0.0, 0.0
    if fx and fx.shake then sp, sr, sy = CamMath.shake(S.playhead / 1000.0, fx.shake.amount, fx.shake.freq) end
    FreeCam.setPose(pose.x, pose.y, pose.z, pose.pitch + sp, (pose.roll or 0.0) + sr, pose.yaw + sy, pose.fov)
    setFilter(fx and fx.filter)
end

-- ============================================
-- What the page (and the pad) can do
-- ============================================

local function keyCount() return S.seq and #S.seq.keys or 0 end

--- The key at the playhead's time, if one sits within `within` ms of it.
local function keyNear(t, within)
    for i, k in ipairs(S.seq.keys) do
        if math.abs(k.t - t) <= (within or 1) then return i end
    end
    return nil
end

--- After a change re-sorted the keys, find a key again by a mark set on it before.
local function findMarked()
    for i, k in ipairs(S.seq.keys) do
        if k.label == '\1mark' then return i end
    end
    return nil
end

local A = {}

--- A key of the new-key kind where the camera is, at the playhead (or at `t`).
function A.add(t)
    if S.view then stopViewing() end
    local shot, why = shotHere(S.newKind, S.newSubject)
    if not shot then say(why, 'warn') return end
    local at = math.floor((t or S.playhead) + 0.5)
    local appending = keyCount() == 0 or at >= S.seq.keys[keyCount()].t
    if keyNear(at, 1) then
        if not appending then say('There is a key at this moment already: move the playhead', 'warn') return end
        at = S.seq.keys[keyCount()].t + KEY_STEP
    end
    local ok = change(function()
        local key = { t = at, shot = shot, move = 'glide', ease = 'smooth', label = '\1mark' }
        S.seq.keys[#S.seq.keys + 1] = key
        return true
    end, true)
    if not ok then return end
    S.sel = findMarked()
    if S.sel then S.seq.keys[S.sel].label = nil; rebuild() end
    if appending then S.playhead = at + KEY_STEP end
    say(('Key %d added: %s'):format(S.sel or keyCount(), S.newKind), 'ok')
    sendState()
end

--- The picked key's shot, from where the camera is now (its kind and subject kept).
function A.setFromCamera(i)
    i = i or S.sel
    local k = i and S.seq.keys[i]
    if not k then say('Pick a key first', 'warn') return end
    if S.view then stopViewing() end
    local kind, subject = k.shot.kind, k.shot.subject
    local shot, why = shotHere(kind, subject or S.newSubject)
    if not shot then say(why, 'warn') return end
    if kind == 'chase' then say('A chase follows its subject: change its numbers on the right', 'info') return end
    -- What is not about where the camera stands is kept (an orbit's turn and clearance).
    if kind == 'orbit' then shot.turn, shot.clear = k.shot.turn, k.shot.clear end
    if change(function() S.seq.keys[i].shot = shot return true end) then
        say(('Key %d moved to the camera'):format(i), 'ok')
    end
end

function A.delete(i)
    i = i or S.sel
    if not (i and S.seq.keys[i]) then return end
    change(function()
        table.remove(S.seq.keys, i)
        if #S.seq.keys == 0 then S.sel = nil
        elseif S.sel and S.sel > #S.seq.keys then S.sel = #S.seq.keys end
        if #S.seq.keys == 0 then S.seq.length = 0 end
        return true
    end)
    if S.view and not S.run then stopViewing() end
end

function A.duplicate(i)
    i = i or S.sel
    local k = i and S.seq.keys[i]
    if not k then return end
    local nextT = S.seq.keys[i + 1] and S.seq.keys[i + 1].t or (k.t + KEY_STEP * 2)
    local at = math.floor((k.t + nextT) / 2)
    if at == k.t then at = k.t + 1 end
    change(function()
        local d = copy(k)
        d.t, d.label = at, '\1mark'
        S.seq.keys[#S.seq.keys + 1] = d
        return true
    end, true)
    S.sel = findMarked()
    if S.sel then S.seq.keys[S.sel].label = k.label; rebuild() end
    sendState()
end

--- Pick a key: the playhead goes to it and the camera looks through it.
function A.select(i)
    if not (i and S.seq.keys[i]) then S.sel = nil sendState() return end
    S.sel = i
    S.playhead = S.seq.keys[i].t
    S.playing = false
    startViewing()
    sendState()
end

function A.step(dir)
    local n = keyCount()
    if n == 0 then return end
    local i
    if dir > 0 then
        i = 1
        for j = 1, n do if S.seq.keys[j].t > S.playhead + 0.5 then i = j break end i = n end
    else
        i = n
        for j = n, 1, -1 do if S.seq.keys[j].t < S.playhead - 0.5 then i = j break end i = 1 end
    end
    A.select(i)
end

function A.play(on)
    if not S.run then say('Add a key first', 'warn') return end
    if on == nil then on = not S.playing end
    S.playing = on
    if on then
        if S.playhead >= (S.clean.length or 0) - 1 then S.playhead = 0 end
        CamSequence.captureAnchor(S.run)
        S.run.mem = {}
        startViewing()
    end
    sendTime()
end

--- The playhead anywhere on the timeline, past the last key too: a key is added where it stands.
function A.scrub(t)
    S.playhead = CamMath.clamp(tonumber(t) or 0, 0, CamSequence.MAX_LENGTH)
    S.playing = false
    startViewing()
    sendTime()
end

function A.view(on)
    if on == nil then on = not S.view end
    if on then startViewing() else stopViewing() end
end

--- Nothing on screen but the picture (the editor's panels, GTA's HUD and radar), or everything back.
function A.hud(hidden)
    if hidden == nil then hidden = not S.hideHud end
    if hidden == S.hideHud then return end
    S.hideHud = hidden
    sendState()
end

--- The camera points and the path in the world, hidden or shown.
function A.points(hidden)
    if hidden == nil then hidden = not S.hidePoints end
    S.hidePoints = hidden
    say(hidden and 'Camera points hidden' or 'Camera points shown', 'info')
    sendState()
end

--- Move a key in time (dragged on the timeline). Two keys at one moment are allowed (a cut).
function A.moveKey(i, t)
    local k = i and S.seq.keys[i]
    if not k then return end
    t = math.max(0, math.floor((tonumber(t) or k.t) + 0.5))
    if t == k.t then return end
    local label = k.label
    change(function()
        S.seq.keys[i].t = t
        S.seq.keys[i].label = '\1mark'
        return true
    end, true)
    S.sel = findMarked()
    if S.sel then S.seq.keys[S.sel].label = label; rebuild() end
    sendState()
end

-- A key's fields the page may set, and how each is checked (CamSequence.clean checks them all again).
local function setPath(tbl, path, value)
    local parts = {}
    for p in path:gmatch('[^%.]+') do parts[#parts + 1] = p end
    local t = tbl
    for n = 1, #parts - 1 do
        if type(t[parts[n]]) ~= 'table' then t[parts[n]] = {} end
        t = t[parts[n]]
    end
    t[parts[#parts]] = value
end

local KEY_FIELDS = {
    t = true, move = true, ease = true, rate = true, around = true, filter = true, label = true, coast = true,
    ['shake.amount'] = true, ['shake.freq'] = true, ['punch.fov'] = true, ['punch.decay'] = true,
}
local SHOT_FIELDS = {
    fov = true, roll = true, subject = true, yaw = true, pitch = true, fit = true, dist = true, turn = true,
    clear = true, ['aim.x'] = true, ['aim.y'] = true, ['aim.z'] = true, ['look.pitch'] = true, ['look.yaw'] = true,
    ['rot.x'] = true, ['rot.y'] = true, ['rot.z'] = true, ['pos.x'] = true, ['pos.y'] = true, ['pos.z'] = true,
    ['offset.x'] = true, ['offset.y'] = true, ['offset.z'] = true,
    height = true, ahead = true, slip = true, stiff = true, turnRate = true, fovAdd = true, distAdd = true, collision = true,
}

function A.editKey(i, field, value)
    local k = i and S.seq.keys[i]
    if not k or type(field) ~= 'string' then return end
    local isShot = field:sub(1, 5) == 'shot.'
    local f = isShot and field:sub(6) or field
    if not (isShot and SHOT_FIELDS[f] or (not isShot and KEY_FIELDS[f])) then return end
    if value == '' then value = nil end
    -- A new time re-sorts the keys: moved as a drag moves it, so the key stays the picked one.
    if f == 't' then return A.moveKey(i, value) end
    -- An orbit's distance is a fit or metres, never both: setting one takes the other away.
    change(function()
        local key = S.seq.keys[i]
        if f == 'filter' and (value == 'none' or value == nil) then key.filter = nil return true end
        if f == 'subject' then
            if value == 'target' and not S.subjects.target then return false, 'Pick a thing first: look at it and press Pick' end
        end
        if isShot then
            if f == 'fit' and value ~= nil then key.shot.dist = nil end
            if f == 'dist' and value ~= nil then key.shot.fit = nil end
            setPath(key.shot, f, value)
        else
            setPath(key, f, value)
            -- An empty shake or punch is no shake or punch.
            if key.shake and not tonumber(key.shake.amount) then key.shake = nil end
            if key.punch and not tonumber(key.punch.fov) then key.punch = nil end
        end
        return true
    end, true)
    sendState()
end

--- Change a key's kind, keeping the camera where that key had it (a fixed shot turned into an orbit round
--- the subject from the same spot, and so on).
function A.setKind(i, kind)
    local k = i and S.seq.keys[i]
    if not k or k.shot.kind == kind then return end
    local pose = keyPose(i)
    if not pose then say('That key\'s subject is not there', 'warn') return end
    local anchor = editAnchor()
    local subject = k.shot.subject or S.newSubject
    local shot
    if kind == 'fixed' then shot = CamShots.fixedFromCamera(pose, anchor)
    else
        local s = subjectNow(subject)
        if not s then say(('%s is not there'):format(SUBJECT_WORDS[subject] or subject), 'warn') return end
        if kind == 'orbit' then shot = CamShots.orbitFromCamera(s, pose, nil, true)
        elseif kind == 'track' then shot = CamShots.trackFromCamera(s, pose, nil, anchor)
        elseif kind == 'mounted' then shot = CamShots.mountedFromCamera(s, pose)
        elseif kind == 'chase' then shot = { kind = 'chase', dist = 5.0, height = 1.8, ahead = 3.5, slip = 0.35, stiff = 7.0, fov = pose.fov }
        else return end
        shot.subject = subject
    end
    change(function() S.seq.keys[i].shot = shot return true end)
end

--- The camera to a key's picture, to fly on from there.
function A.lookThrough(i)
    i = i or S.sel
    local pose = i and keyPose(i)
    if not pose then return end
    S.playing = false
    S.view = false
    FreeCam.hold(false)
    FreeCam.setPose(pose.x, pose.y, pose.z, pose.pitch, pose.roll or 0.0, pose.yaw, pose.fov)
    S.playhead = S.seq.keys[i].t
    sendTime()
end

--- The thing the camera looks at (a car, a person, a prop), as the subject 'target'.
function A.pick()
    local p, r = FreeCam.getCoord(), FreeCam.getRot()
    local fx, fy, fz = CamMath.forward(r.x, r.z)
    local h = StartExpensiveSynchronousShapeTestLosProbe(p.x, p.y, p.z, p.x + fx * 300.0, p.y + fy * 300.0, p.z + fz * 300.0,
        2 + 4 + 8 + 16, 0, 4)
    local _, hit, _, _, ent = GetShapeTestResult(h)
    if not (hit == 1 or hit == true) or not ent or ent == 0 or GetEntityType(ent) == 0 then
        say('Nothing to pick there: put a car, a person or a prop in the middle of the screen', 'warn')
        return
    end
    S.subjects.target = ent
    local what
    local kind = GetEntityType(ent)
    if kind == 2 then
        what = GetDisplayNameFromVehicleModel(GetEntityModel(ent))
        what = (what and GetLabelText(what) ~= 'NULL') and GetLabelText(what) or what or 'a vehicle'
    elseif kind == 1 then what = IsPedAPlayer(ent) and GetPlayerName(NetworkGetPlayerIndexFromPed(ent)) or 'a person'
    else what = 'a prop' end
    S.targetName = what
    if S.run then S.run.subjects = S.subjects end
    say(('Picked: %s. Shots round "the picked thing" now frame it'):format(what), 'ok')
    sendState()
end

--- The sequence's own settings.
function A.editSeq(field, value)
    if field == 'anchor' then
        local want = (value ~= nil and value ~= '' and value ~= 'none') and value or nil
        if want == S.seq.anchor then return end
        if want == 'target' and not S.subjects.target then say('Pick a thing first', 'warn') return end
        -- Fixed places move between the world and the anchor's own axes, so nothing on screen moves.
        local from = editAnchor()
        local to = nil
        if want then
            local s = subjectNow(want)
            if not s then say(('%s is not there'):format(SUBJECT_WORDS[want] or want), 'warn') return end
            to = { x = s.x, y = s.y, z = s.z, h = s.h }
        end
        change(function()
            for _, k in ipairs(S.seq.keys) do
                local sh = k.shot
                if sh.kind == 'fixed' or sh.kind == 'track' then
                    local x, y, z = sh.pos.x, sh.pos.y, sh.pos.z
                    if from then x, y, z = CamMath.localToWorld(from.x, from.y, from.z, from.h, x, y, z) end
                    sh.pos = CamShots.placeFromWorld(x, y, z, to)
                    if sh.kind == 'fixed' then
                        local yaw = sh.rot.z + (from and from.h or 0.0) - (to and to.h or 0.0)
                        sh.rot.z = CamMath.round(CamMath.wrap180(yaw), 2)
                    end
                end
            end
            S.seq.anchor = want
            return true
        end)
        return
    end
    if field == 'length' then
        change(function() S.seq.length = math.max(0, math.floor((tonumber(value) or 0) + 0.5)) return true end)
    elseif field == 'loop' or field == 'letterbox' then
        change(function() S.seq[field] = value == true return true end)
    elseif field == 'ease' then
        change(function() S.seq.ease = value return true end)
    elseif field == 'newKind' then
        for _, k in ipairs(CamSequence.KINDS) do
            if k == value then S.newKind = value end
        end
        sendState()
    elseif field == 'newSubject' then
        if value == 'player' or value == 'vehicle' or value == 'target' then S.newSubject = value end
        sendState()
    end
end

--- Space the keys so the camera keeps one speed (by the distance between their pictures).
function A.evenTiming()
    local n = keyCount()
    if n < 3 then say('Even timing needs three keys or more', 'warn') return end
    local poses = {}
    for i = 1, n do
        poses[i] = keyPose(i)
        if not poses[i] then say('A key\'s subject is not there', 'warn') return end
    end
    local first, last = S.seq.keys[1].t, S.seq.keys[n].t
    local total, at = 0.0, { 0.0 }
    for i = 2, n do
        local a, b = poses[i - 1], poses[i]
        total = total + math.max(math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2 + (b.z - a.z) ^ 2), 0.01)
        at[i] = total
    end
    change(function()
        for i = 2, n - 1 do S.seq.keys[i].t = math.floor(first + (last - first) * at[i] / total + 0.5) end
        return true
    end)
    say('Keys spaced for an even speed', 'ok')
end

function A.undo()
    local u = table.remove(S.undo)
    if not u then return end
    S.redo[#S.redo + 1] = { seq = copy(S.seq), sel = S.sel }
    S.seq, S.sel = u.seq, u.sel
    rebuild()
    S.dirty = true
    keepDraft()
    sendState()
end

function A.redo()
    local r = table.remove(S.redo)
    if not r then return end
    S.undo[#S.undo + 1] = { seq = copy(S.seq), sel = S.sel }
    S.seq, S.sel = r.seq, r.sel
    rebuild()
    S.dirty = true
    keepDraft()
    sendState()
end

function A.new()
    change(function()
        S.seq = emptySeq()
        S.sel = nil
        return true
    end)
    S.savedAs, S.dirty, S.playhead, S.playing = nil, false, 0.0, false
    stopViewing()
    keepDraft()
    sendState()
end

-- ---- the code, to paste into a script ----

local function num(v)
    local s = ('%.3f'):format(v)
    s = s:gsub('0+$', ''):gsub('%.$', '')
    if s == '-0' then s = '0' end
    return s
end

local ORDER = { 't', 'label', 'shot', 'move', 'ease', 'rate', 'around', 'coast', 'shake', 'filter', 'punch',
    'kind', 'subject', 'pos', 'rot', 'offset', 'yaw', 'pitch', 'fit', 'dist', 'aim', 'look', 'turn', 'clear',
    'height', 'ahead', 'slip', 'stiff', 'turnRate', 'fovAdd', 'distAdd', 'collision', 'fov', 'roll',
    'x', 'y', 'z', 'amount', 'freq', 'decay' }
local RANK = {}
for i, k in ipairs(ORDER) do RANK[k] = i end

local function lua(v, indent)
    local t = type(v)
    if t == 'number' then return num(v) end
    if t == 'string' then return ("'%s'"):format(v:gsub('\\', '\\\\'):gsub("'", "\\'")) end
    if t == 'boolean' then return tostring(v) end
    if t ~= 'table' then return 'nil' end
    if #v > 0 then
        local pad = indent .. '    '
        local lines = {}
        for _, x in ipairs(v) do lines[#lines + 1] = pad .. lua(x, pad) .. ',' end
        return '{\n' .. table.concat(lines, '\n') .. '\n' .. indent .. '}'
    end
    local ks = {}
    for k in pairs(v) do ks[#ks + 1] = k end
    table.sort(ks, function(a, b) return (RANK[a] or 999) < (RANK[b] or 999) or ((RANK[a] or 999) == (RANK[b] or 999) and a < b) end)
    local parts = {}
    for _, k in ipairs(ks) do parts[#parts + 1] = k .. ' = ' .. lua(v[k], indent) end
    return '{ ' .. table.concat(parts, ', ') .. ' }'
end

function A.copy()
    if not S.clean then say('Add a key first', 'warn') return end
    local c = copy(S.clean)
    c.name = nil
    local head = {}
    if S.savedAs then head[#head + 1] = ("-- Saved as '%s': exports.whip_core:PlayCameraSequence('%s') plays it too."):format(S.savedAs, S.savedAs) end
    local subs = CamSequence.subjectsOf(c)
    local opts = ''
    if subs.target then
        head[#head + 1] = '-- "target" is the thing it frames: pass yours in subjects.'
        opts = ', { subjects = { target = entity } }'
    end
    local body = {}
    for _, k in ipairs({ 'length', 'anchor', 'loop', 'letterbox', 'ease' }) do
        local v = c[k]
        if v ~= nil and v ~= false and not (k == 'ease' and v == 'linear') then body[#body + 1] = '    ' .. k .. ' = ' .. lua(v, '    ') .. ',' end
    end
    body[#body + 1] = '    keys = ' .. lua(c.keys, '    ') .. ','
    local text = (#head > 0 and (table.concat(head, '\n') .. '\n') or '')
        .. 'exports.whip_core:PlayCameraSequence({\n' .. table.concat(body, '\n') .. '\n}' .. opts .. ')'
    CopyToClipboard(text)
end

OnClipboardCopied(function()
    if S.open then say('Code copied: paste it into your script', 'ok') end
end)

-- ---- saving to the server, and opening ----

function A.list()
    CreateThread(function()
        local res, why = Callback('whip_core:camseq:list')
        if type(res) ~= 'table' then say(why or 'The list could not be read', 'err') return end
        SendNUIMessage({ action = 'camEdList', list = res.list, mayEdit = res.mayEdit })
    end)
end

function A.save(name)
    if not S.clean then say('Add a key first', 'warn') return end
    name = type(name) == 'string' and name or S.savedAs
    if not name or name == '' then SendNUIMessage({ action = 'camEdAskName' }) return end
    local data = copy(S.clean)
    CreateThread(function()
        local res, why = Callback('whip_core:camseq:save', name, data)
        if type(res) ~= 'table' then say(why or 'Not saved', 'err') return end
        S.savedAs, S.dirty = name, false
        keepDraft()
        say(('Saved as %s: anyone can play it now'):format(name), 'ok')
        sendState()
        SendNUIMessage({ action = 'camEdList', list = res.list, mayEdit = true })
    end)
end

function A.load(name)
    CreateThread(function()
        local data, why = Callback('whip_core:camseq:fetch', name)
        if type(data) ~= 'table' then say(why or 'It could not be opened', 'err') return end
        S.undo[#S.undo + 1] = { seq = copy(S.seq), sel = S.sel }
        S.redo = {}
        data.name = nil
        S.seq = data
        local bent = straightTime(S.seq)
        S.sel = nil
        S.playhead, S.playing = 0.0, false
        local ok, bad = rebuild()
        if not ok then say(bad, 'err') return end
        S.savedAs, S.dirty = name, bent
        keepDraft()
        if CamSequence.subjectsOf(S.seq).target and not S.subjects.target then
            say(('Opened %s. It frames a picked thing: pick one to see it'):format(name), 'warn')
        else
            say(('Opened %s'):format(name), 'ok')
        end
        sendState()
    end)
end

--- Asked on the page (its Open list asks "Delete it?" on the row): UI.Confirm here was refused while this screen held
--- the focus, so Delete never deleted and said nothing (audit 20, CLI-1).
function A.deleteSaved(name)
    CreateThread(function()
        local res, why = Callback('whip_core:camseq:delete', name)
        if type(res) ~= 'table' then say(why or 'Not deleted', 'err') return end
        if S.savedAs == name then S.savedAs, S.dirty = nil, true end
        say(('Deleted %s'):format(name), 'info')
        SendNUIMessage({ action = 'camEdList', list = res.list, mayEdit = true })
        sendState()
    end)
end

-- ============================================
-- Drawing the keys in the world
-- ============================================
--
-- Each key drawn as a camera (a small body behind the lens and its VIEW, a 16:9 frame as wide as its
-- lens), numbered on its back plate through a DUI atlas; the picked one green, the rest blue, and where
-- the playhead's camera is in white while flying. The path the camera takes is drawn as a line, sampled
-- along the timeline. Only what can be seen is drawn, and less of it the further away.

local GIZMO_DIST, GIZMO_MAX_H, GIZMO_ASPECT = 1.0, 0.6, 16 / 9
local GIZMO_BODY = { front = 0.06, back = 0.42, hw = 0.13, hh = 0.1 }
local GIZMO_ON, GIZMO_OFF, GIZMO_HEAD = { 74, 222, 128 }, { 96, 165, 250 }, { 255, 255, 255 }
local PATH_RGB = { 96, 165, 250 }
local GIZMO_NEAR, GIZMO_MID, GIZMO_FAR = 35.0, 120.0, 300.0
local PATH_FAR, PATH_NEAR = 600.0, 30.0

local function line(a, b, r, g, bl, al) DrawLine(a.x, a.y, a.z, b.x, b.y, b.z, r, g, bl, al) end
local function quad(a, b, c, d, r, g, bl, al)
    DrawPoly(a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z, r, g, bl, al)
    DrawPoly(a.x, a.y, a.z, c.x, c.y, c.z, d.x, d.y, d.z, r, g, bl, al)
    DrawPoly(c.x, c.y, c.z, b.x, b.y, b.z, a.x, a.y, a.z, r, g, bl, al)
    DrawPoly(d.x, d.y, d.z, c.x, c.y, c.z, a.x, a.y, a.z, r, g, bl, al)
end

-- The numbers, on a DUI atlas (html/interact3d/camgizmo.html): one cell per camera.
local GZ_PAGE, GZ_TXD, GZ_TEX = 'camgizmo', 'whip_camgizmo', 'cams'
local GZ_BACK_W, GZ_LABEL_W, GZ_CELL_H = 126, 384, 96
local GZ_COLS, GZ_ROWS = 4, 20
local GZ_CELLS = GZ_COLS * GZ_ROWS
local GZ_CELL_W = GZ_BACK_W + GZ_LABEL_W
local GZ_W, GZ_H = GZ_CELL_W * GZ_COLS, GZ_CELL_H * GZ_ROWS
local GZ_LIFT = 0.006
local gzSent, gzSentAt = nil, 0

--- Made with the creator and given back with it: a DUI renders all the time whether or not it is drawn.
local gzPage = DuiPage.new({
    name = 'camera', url = ('interact3d/%s.html'):format(GZ_PAGE), width = GZ_W, height = GZ_H,
    txd = GZ_TXD, tex = GZ_TEX, without = 'the cameras draw without their numbers',
    -- A new browser is sent its rows again.
    onGone = function() gzSent, gzSentAt = nil, 0 end,
})

local function gzEnsure() gzPage:ensure() end
local function gzRelease() gzPage:release() end

--- The atlas's rows: key i in cell i (the first GZ_CELLS keys).
local function gzSync(now, poses)
    if not gzPage:exists() then return end
    local rows = {}
    for i = 1, math.min(#poses, GZ_CELLS) do
        local p = poses[i]
        rows[i] = { back = tostring(i), fov = p and ('%.1f°'):format(p.fov or 50.0) or '', on = i == S.sel }
    end
    local key = json.encode(rows)
    if key == gzSent and now - gzSentAt < 2000 then return end
    gzSent, gzSentAt = key, now
    gzPage:send({ rows = rows }, 'rows')
end

local viewX, viewY, viewZ, viewFX, viewFY, viewFZ, viewCos = 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0

local function seenAt(x, y, z, radius, far)
    local dx, dy, dz = x - viewX, y - viewY, z - viewZ
    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
    if d - radius > far then return nil end
    if d <= radius then return d end
    if dx * viewFX + dy * viewFY + dz * viewFZ < (d - radius) * viewCos - radius then return nil end
    return d
end

local function gizmoGeom(p)
    local pitch, yaw = math.rad(p.pitch), math.rad(p.yaw)
    local cp, sp, cy, sy = math.cos(pitch), math.sin(pitch), math.cos(yaw), math.sin(yaw)
    local pos = vector3(p.x, p.y, p.z)
    local f = vector3(-sy * cp, cy * cp, sp)
    local r = vector3(cy, sy, 0.0)
    local u = vector3(sy * sp, -cy * sp, cp)
    local t = math.tan(math.rad((p.fov or 50.0) * 0.5))
    local d = math.min(GIZMO_DIST, GIZMO_MAX_H / math.max(t, 0.01))
    local hh = d * t
    local hw = hh * GIZMO_ASPECT
    local c = pos + f * d
    local nb = hw * 0.16
    local top = c + u * hh
    local bd = GIZMO_BODY
    local fr, bk = pos - f * bd.front, pos - f * bd.back
    local rw, uh = r * bd.hw, u * bd.hh
    local lh = math.max(0.045, math.min(0.11, hh * 2.0 * 0.11))
    local lw = lh * GZ_LABEL_W / GZ_CELL_H
    local m = lh * 0.4
    local down = u * (hh - m - lh * 0.5)
    local side = r * (hw - m - lw * 0.5)
    local pw = bd.hw * 2.0 * 0.94
    local half = (d + bd.back) * 0.5
    local mid = pos + f * ((d - bd.back) * 0.5)
    return {
        p = pos, f = f, r = r, u = u,
        tl = c - r * hw + u * hh, tr = c + r * hw + u * hh, br = c + r * hw - u * hh, bl = c - r * hw - u * hh,
        nl = top - r * nb, tip = top + u * (nb * 1.1), nr = top + r * nb,
        f1 = fr - rw + uh, f2 = fr + rw + uh, f3 = fr + rw - uh, f4 = fr - rw - uh,
        k1 = bk - rw + uh, k2 = bk + rw + uh, k3 = bk + rw - uh, k4 = bk - rw - uh,
        plate = bk - f * GZ_LIFT, pw = pw, ph = pw * GZ_CELL_H / GZ_BACK_W,
        pillBack = c - down - side - f * GZ_LIFT, pillFront = c - down + side + f * GZ_LIFT, lw = lw, lh = lh,
        cx = mid.x, cy = mid.y, cz = mid.z, radius = math.sqrt(half * half + hw * hw + hh * hh) + 0.1,
    }
end

local function drawGizmo(g, rgb, cell, dist)
    local R, G, B = rgb[1], rgb[2], rgb[3]
    local p = g.p
    local tl, tr, br, bl = g.tl, g.tr, g.br, g.bl
    line(tl, tr, R, G, B, 230); line(tr, br, R, G, B, 230); line(br, bl, R, G, B, 230); line(bl, tl, R, G, B, 230)
    line(p, tl, R, G, B, 130); line(p, tr, R, G, B, 130); line(p, br, R, G, B, 130); line(p, bl, R, G, B, 130)
    if dist > GIZMO_MID then return end
    local f1, f2, f3, f4, k1, k2, k3, k4 = g.f1, g.f2, g.f3, g.f4, g.k1, g.k2, g.k3, g.k4
    line(g.nl, g.tip, R, G, B, 230); line(g.tip, g.nr, R, G, B, 230)
    line(f1, f2, R, G, B, 255); line(f2, f3, R, G, B, 255); line(f3, f4, R, G, B, 255); line(f4, f1, R, G, B, 255)
    line(k1, k2, R, G, B, 255); line(k2, k3, R, G, B, 255); line(k3, k4, R, G, B, 255); line(k4, k1, R, G, B, 255)
    line(f1, k1, R, G, B, 255); line(f2, k2, R, G, B, 255); line(f3, k3, R, G, B, 255); line(f4, k4, R, G, B, 255)
    if dist > GIZMO_NEAR then return end
    quad(tl, tr, br, bl, R, G, B, 28)
    quad(k1, k2, k3, k4, R, G, B, 150)
    quad(f1, k1, k4, f4, R, G, B, 110)
    quad(f2, k2, k3, f3, R, G, B, 110)
    quad(f1, f2, k2, k1, R, G, B, 130)
    quad(f4, f3, k3, k4, R, G, B, 90)
    line(f1, p, R, G, B, 200); line(f2, p, R, G, B, 200); line(f3, p, R, G, B, 200); line(f4, p, R, G, B, 200)
    if not (cell and gzPage:exists() and cell >= 1 and cell <= GZ_CELLS) then return end
    local col, row = (cell - 1) % GZ_COLS, (cell - 1) // GZ_COLS
    local u0 = col * GZ_CELL_W / GZ_W
    local uMid = (col * GZ_CELL_W + GZ_BACK_W) / GZ_W
    local u1 = (col + 1) * GZ_CELL_W / GZ_W
    local v0, v1 = row / GZ_ROWS, (row + 1) / GZ_ROWS
    local r, u = g.r, g.u
    local pc = g.plate
    WorldQuad.draw(GZ_TXD, GZ_TEX, pc.x, pc.y, pc.z, r.x, r.y, r.z, u.x, u.y, u.z, g.pw, g.ph, u0, v0, uMid, v1, 255, 255, 255, 255)
    local b, fr = g.pillBack, g.pillFront
    WorldQuad.draw(GZ_TXD, GZ_TEX, b.x, b.y, b.z, r.x, r.y, r.z, u.x, u.y, u.z, g.lw, g.lh, uMid, v0, u1, v1, 255, 255, 255, 255)
    WorldQuad.draw(GZ_TXD, GZ_TEX, fr.x, fr.y, fr.z, -r.x, -r.y, -r.z, u.x, u.y, u.z, g.lw, g.lh, uMid, v0, u1, v1, 255, 255, 255, 255)
end

-- The path, sampled along the timeline: stretches of points with a sphere round each for seenAt. Worked out
-- again when the sequence changes, and every second while it frames something that moves.
local pathCache = { ver = -1, at = 0, segs = {} }
local function pathGeom(now)
    if not S.clean then return {} end
    local moving = false
    for _, k in ipairs(S.clean.keys) do if k.shot.kind ~= 'fixed' then moving = true break end end
    if pathCache.ver == S.ver and (not moving or now - pathCache.at < 1000) then return pathCache.segs end
    local run = CamSequence.newRun(S.clean, S.subjects)
    CamSequence.captureAnchor(run)
    local length = S.clean.length
    local step = math.max(SAMPLE_MS, length / MAX_SAMPLES)
    local pts = {}
    local t = 0.0
    while true do
        local p = CamSequence.evaluate(run, t, step / 1000.0)
        if p then pts[#pts + 1] = p end
        if t >= length then break end
        t = math.min(t + step, length)
    end
    -- Cut into stretches of 20 points for the culling.
    local segs = {}
    for s = 1, #pts - 1, 20 do
        local e = math.min(s + 20, #pts)
        local seg = { pts = {} }
        local minX, minY, minZ, maxX, maxY, maxZ = math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge
        for i = s, e do
            local p = pts[i]
            seg.pts[#seg.pts + 1] = p
            minX, minY, minZ = math.min(minX, p.x), math.min(minY, p.y), math.min(minZ, p.z)
            maxX, maxY, maxZ = math.max(maxX, p.x), math.max(maxY, p.y), math.max(maxZ, p.z)
        end
        seg.cx, seg.cy, seg.cz = (minX + maxX) * 0.5, (minY + maxY) * 0.5, (minZ + maxZ) * 0.5
        seg.radius = math.sqrt((maxX - minX) ^ 2 + (maxY - minY) ^ 2 + (maxZ - minZ) ^ 2) * 0.5 + 0.5
        segs[#segs + 1] = seg
    end
    pathCache.ver, pathCache.at, pathCache.segs = S.ver, now, segs
    return segs
end

local function drawPath(now)
    local R, G, B = PATH_RGB[1], PATH_RGB[2], PATH_RGB[3]
    for _, s in ipairs(pathGeom(now)) do
        local d = seenAt(s.cx, s.cy, s.cz, s.radius, PATH_FAR)
        if d then
            local pts = s.pts
            local thick = d - s.radius < PATH_NEAR
            for i = 1, #pts - 1 do
                local a, b = pts[i], pts[i + 1]
                DrawLine(a.x, a.y, a.z, b.x, b.y, b.z, R, G, B, 200)
                if thick then
                    DrawLine(a.x + 0.02, a.y + 0.02, a.z, b.x + 0.02, b.y + 0.02, b.z, R, G, B, 200)
                    DrawLine(a.x - 0.02, a.y - 0.02, a.z, b.x - 0.02, b.y - 0.02, b.z, R, G, B, 200)
                end
            end
        end
    end
end

-- The keys' pictures, worked out a few times a second (a subject moves; nothing else does).
local poseCache = { ver = -1, at = 0, list = {} }
local function keyPoses(now)
    if poseCache.ver == S.ver and now - poseCache.at < 250 then return poseCache.list end
    local list = {}
    for i = 1, keyCount() do list[i] = keyPose(i) or false end
    poseCache.ver, poseCache.at, poseCache.list = S.ver, now, list
    return list
end

local function drawWorld(now, cam)
    viewX, viewY, viewZ = cam.x, cam.y, cam.z
    viewFX, viewFY, viewFZ = CamMath.forward(cam.pitch, cam.yaw)
    local halfDiag = math.atan(math.tan(math.rad((cam.fov or 50.0) * 0.5)) * math.sqrt(1.0 + GIZMO_ASPECT * GIZMO_ASPECT)) + 0.1
    viewCos = halfDiag < math.pi * 0.5 and math.cos(halfDiag) or 0.0

    local poses = keyPoses(now)
    for i, p in ipairs(poses) do
        if p and not (S.view and i == S.sel) then
            local g = gizmoGeom(p)
            local d = seenAt(g.cx, g.cy, g.cz, g.radius, GIZMO_FAR)
            if d then drawGizmo(g, i == S.sel and GIZMO_ON or GIZMO_OFF, i, d) end
        end
    end
    if keyCount() >= 2 then drawPath(now) end
    -- Where the timeline's camera is at the playhead, while flying elsewhere.
    if not S.view and S.run then
        local p = CamSequence.evaluate(S.run, S.playhead, 0.0)
        if p then
            local g = gizmoGeom(p)
            local d = seenAt(g.cx, g.cy, g.cz, g.radius, GIZMO_FAR)
            if d then drawGizmo(g, GIZMO_HEAD, nil, d) end
        end
    end
    gzSync(now, poses)
end

-- ============================================
-- Input
-- ============================================

-- Held for the session: the game's pause (Esc, P), the weapon wheel and attack, and the keys the page
-- answers (so they do nothing in the world as well): G, E, R, F, V, H, the arrows, Space, Delete.
local CC_BLOCK = { controls = { 200, 199, 37, 24, 25, 47, 38, 45, 75, 0, 174, 175, 172, 173, 22, 178, 140, 141, 142, 257, 263, 264, 74 } }
-- A pad's buttons (the device in hand only).
local PAD = { a = 201, b = 202, x = 203, y = 204, rb = 206, up = 188, down = 187, left = 189, right = 190,
              menu = 199, view = 217, r3 = 210 }
local PAD_ZOOM = 30.0
local KINDS = { 'fixed', 'orbit', 'chase', 'mounted', 'track' }
local leave   -- leaving from inside (Exit, Esc, B): with Enter / Exit, below
-- ⧉ tapped looks through or flies; held this long, it hides the HUD (or shows it again).
local HOLD_HUD_MS = 600
local viewDownAt, viewHeld = nil, false
-- With the HUD hidden, these bring it back and do nothing else (RB still plays: the clean shot).
local PAD_SHOW_HUD = { PAD.a, PAD.b, PAD.x, PAD.y, PAD.menu }

local function takeFocus()
    -- No cursor on a pad. While the mouse looks, the cursor is Focus.mouseLook's (client/focus.lua).
    Focus.take('cameraCreator', { cursor = not S.pad, keepInput = true, screen = true })
end

local function setInput(pad, looking)
    local padChanged, lookChanged = pad ~= S.pad, looking ~= S.looking
    S.pad, S.looking = pad, looking
    FreeCam.setPad(pad)
    FreeCam.setInputEnabled(not S.drive and (pad or looking))
    -- The look first, then the pad's cursor: on Legacy both take the hold, and the pad's word is the last.
    if lookChanged then Focus.mouseLook('cameraCreator', looking and true or false) end
    if padChanged then takeFocus() end
    if padChanged or lookChanged then
        SendNUIMessage({ action = 'camEdInput', looking = looking, pad = pad })
    end
end

-- ============================================
-- Who has the controls: the camera, or the game
-- ============================================
--
-- THE CAMERA (as it opens): the editor has every control. Nothing reaches your character — a car you are
-- driving stops where it is and holds there, so it stays where you are framing it. The page's keys and the
-- camera's are all there is.
--
-- THE GAME (Tab, the dock's switch, LB + R3 on a pad): your character is yours again, to drive and walk while
-- the editor stays up — to put the car where the shot wants it, or to drive while looking through the
-- timeline and watch a chase or a bonnet camera follow you. The camera holds still and the editor's keys
-- stand down; Tab (or Esc) gives the controls back to the camera.

-- Every control the game has, bar none, while the camera has them (the camera and the page read the
-- keys themselves, as held-off controls). CC_BLOCK's named ones are named so Esc is the editor's, not the
-- pause menu's.
local CAMERA_BLOCK = { all = true, controls = CC_BLOCK.controls }
-- While the game has them: no pause (Esc is the editor's), no weapons (a click on the editor must not
-- fire one).
local GAME_BLOCK = { controls = { 200, 199, 37, 24, 25, 140, 141, 142, 257, 263, 264 } }

--- The car you are driving, held where it is (or let go).
local function holdVehicle(on)
    if on then
        local ped = PlayerPedId()
        local veh = GetVehiclePedIsIn(ped, false)
        if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped then
            FreezeEntityPosition(veh, true)
            S.heldVeh = veh
        end
    elseif S.heldVeh then
        if DoesEntityExist(S.heldVeh) then FreezeEntityPosition(S.heldVeh, false) end
        S.heldVeh = nil
    end
end

--- The holds for whoever has the controls now.
local function applyControls()
    if S.drive then
        ControlBlocks.hold('cameraCreator', GAME_BLOCK)
        PedHold.set('cameraCreator', { invincible = true })
        holdVehicle(false)
        FreeCam.setInputEnabled(false)
        FreeCam.holdControls(false)   -- the camera's own hold on walking and looking: you walk
    else
        FreeCam.holdControls(true)
        ControlBlocks.hold('cameraCreator', CAMERA_BLOCK)
        PedHold.set('cameraCreator', { invincible = true, frozen = true })
        holdVehicle(true)
        FreeCam.setInputEnabled((S.pad or S.looking) == true)
    end
end

--- The controls to the game (`true`), back to the camera (`false`), or the other way (nil).
function A.controls(toGame)
    if not S.open then return end
    if toGame == nil then toGame = not S.drive end
    if toGame == S.drive then return end
    S.drive = toGame
    if toGame and S.looking then
        S.looking = false
        Focus.mouseLook('cameraCreator', false)
    end
    applyControls()
    say(toGame and 'You have your character: drive and walk. Tab gives the controls back to the camera'
        or 'The camera has the controls', 'info')
    sendState()
end

local function padFrame(dt)
    local function pressed(b) return WhipKeyPressed(nil, b) end   -- the pad's button, never with LB held
    local now = GetGameTimer()
    if pressed(PAD.view) then viewDownAt, viewHeld = now, false end
    if viewDownAt then
        if IsDisabledControlPressed(0, PAD.view) then
            if not viewHeld and now - viewDownAt >= HOLD_HUD_MS then
                viewHeld = true
                A.hud()
            end
        else
            if not viewHeld then
                if S.hideHud then A.hud(false) else A.view() end
            end
            viewDownAt = nil
        end
    end
    if S.hideHud then
        for _, b in ipairs(PAD_SHOW_HUD) do
            if pressed(b) then A.hud(false) return end
        end
    end
    if pressed(PAD.a) then A.add() end
    if pressed(PAD.x) then A.setFromCamera() end
    if pressed(PAD.y) then A.delete() end
    if pressed(PAD.left) then A.step(-1) end
    if pressed(PAD.right) then A.step(1) end
    if pressed(PAD.rb) then A.play() end
    if pressed(PAD.menu) then if S.savedAs then A.save(S.savedAs) else A.copy() end end
    if pressed(PAD.r3) then
        local at = 1
        for i, k in ipairs(KINDS) do if k == S.newKind then at = i end end
        S.newKind = KINDS[at % #KINDS + 1]
        say(('New keys: %s'):format(S.newKind), 'info')
        sendState()
    end
    if pressed(PAD.b) then
        CreateThread(function() leave() end)
    end
    if not WhipPadModHeld and not S.view then
        local fov = select(2, FreeCam.getFov())
        if IsDisabledControlPressed(0, PAD.up) then FreeCam.setFov(fov - PAD_ZOOM * dt) end
        if IsDisabledControlPressed(0, PAD.down) then FreeCam.setFov(fov + PAD_ZOOM * dt) end
    end
end

-- ============================================
-- The loop
-- ============================================

local loopRunning = false

--- One frame of the editor (`frame`: how many came before).
local function step(frame)
    local dt = math.min(GetFrameTime(), 0.25)
    local now = GetGameTimer()
    local pad = WhipLastInputIsPad()
    local inert = UI.IsBusy ~= nil and UI.IsBusy() or false
    -- With the game in control, the right button and the sticks are the game's.
    local looking = (not S.drive) and (not pad) and (not inert) and IsDisabledControlPressed(0, 25)
    if pad ~= S.pad or looking ~= S.looking then setInput(pad, looking) end

    -- LB + R3 on a pad: the controls to the game, or back to the camera (Tab on a keyboard, the page's).
    if pad and not inert and WhipPadModHeld and IsDisabledControlJustPressed(0, PAD.r3) then A.controls() end

    -- Grabbing the camera flies on from the picture on screen.
    if S.view and not S.drive and (looking or (pad and (math.abs(GetDisabledControlNormal(0, 30)) + math.abs(GetDisabledControlNormal(0, 31))
        + math.abs(GetDisabledControlNormal(0, 1)) + math.abs(GetDisabledControlNormal(0, 2)) > 0.3))) then
        S.playing = false
        stopViewing()
    end

    if S.playing and S.clean then
        S.playhead = S.playhead + dt * 1000.0
        if S.playhead >= S.clean.length then
            if S.clean.loop and S.clean.length > 0 then
                S.playhead = 0.0
                S.run.mem = {}
            else
                S.playhead = S.clean.length
                S.playing = false
            end
        end
        if frame % 2 == 0 or not S.playing then sendTime() end
    end

    if S.view then showPlayhead(dt) end
    if S.clean and S.clean.letterbox and S.view then Camera.letterbox() end

    local cam = camNow()
    if not S.hidePoints then drawWorld(now, cam) end
    if S.hideHud then HideHudAndRadarThisFrame() end

    if pad and not inert and not S.drive then padFrame(dt) end

    if (frame + 1) % 6 == 0 then
        SendNUIMessage({ action = 'camEdCamera', x = cam.x, y = cam.y, z = cam.z, pitch = cam.pitch, yaw = cam.yaw,
                         fov = cam.fov, speed = FreeCam.getSpeed() })
    end
end

--- GUARDED: a frame that errors closes the editor, as the camera's own loop stops its camera (client/camera.lua
--- runLoop). Unguarded, the error ended the thread with the editor's holds still on and loopRunning still true, so
--- every later open came up frozen until a restart (audit 20, CLI-2).
local function loop()
    local frame = 0
    while S.open do
        local ok, err = pcall(step, frame)
        if not ok then
            loopRunning = false
            print(('^1[whip_core:camera] the Camera Creator failed, so it closed: %s^7'):format(tostring(err)))
            pcall(leave)   -- the editor shut and its /w switch off, as Exit does
            UI.Notify('The Camera Creator hit an error and closed (the console says what)', 'error', 8000)
            return
        end
        frame = frame + 1
        Wait(0)
    end
    loopRunning = false
end

-- ============================================
-- Enter / Exit
-- ============================================

--- THE CAMERA LEAVES, THE PLAYER STAYS: the ped stays where it stood, seen, doing whatever it was doing
--- (an emote: frame a shot round yourself), held so a far-off camera cannot drop it through unstreamed
--- ground. The free camera starts at `pose` (where it was left, coming back from playing), else where the
--- game's camera is.
local function openEditor(pose)
    if pose then
        FreeCam.start({ hidePed = false, pedFollows = false, scroll = 'fov', fov = pose.fov or 50.0,
                        coords = vector3(pose.x, pose.y, pose.z), rot = vector3(pose.pitch, pose.roll or 0.0, pose.yaw) })
    else
        FreeCam.start({ hidePed = false, pedFollows = false, scroll = 'fov', fov = 50.0,
                        coords = GetGameplayCamCoord(), rot = GetGameplayCamRot(2) })
    end
    -- The camera has the controls to start with: your character and your car hold still.
    S.drive = false
    applyControls()

    S.open = true
    S.modeAt = GetGameTimer()
    CameraCreatorActive = true
    S.view, S.playing, S.typing, S.hideHud = false, false, false, false
    viewDownAt = nil
    S.playhead = math.min(S.playhead or 0.0, S.seq.length or 0.0)
    -- The device in hand now, told to the camera and the focus (setInput acts on a change only).
    S.pad, S.looking = nil, nil
    setInput(WhipLastInputIsPad(), false)
    gzEnsure()
    SendNUIMessage({ action = 'camEdOpen' })
    sendState()

    if not loopRunning then
        loopRunning = true
        CreateThread(loop)
    end
end

--- The editor put away (leaving, or going to play): the player has their camera and themselves back.
local function closeEditor()
    if not S.open then return end
    S.open = false
    S.modeAt = GetGameTimer()
    CameraCreatorActive = false
    S.playing = false
    if S.view then FreeCam.hold(false) end
    S.view = false
    setFilter('none')
    ControlBlocks.release('cameraCreator')
    Focus.release('cameraCreator')
    SendNUIMessage({ action = 'camEdClose' })
    -- The player stays where they are: never moved by the camera, but maybe driven off with the Game controls.
    FreeCam.stop({ movePed = false, stay = true })
    PedHold.release('cameraCreator')
    holdVehicle(false)
    S.drive = false
    gzRelease()
    writeDraft()
end

-- ============================================
-- Playing in game: the shots rolled live while you play
-- ============================================
--
-- A CINEMATIC KIT. Play in game (the dock's button, or F9) puts the editor away and gives the player back:
-- walk, drive, emote, as in any game. The shots stay ready, and keys roll them while you play — record the
-- screen (OBS) and the shot is the video:
--
--   F5            ACTION: the timeline from its start, live; F5 again cuts back to the game's camera
--   Page Down/Up  the next / previous camera: a key's shot held live (an orbit spinning, a chase following,
--                 a bonnet camera riding along) — a director cutting between cameras
--   Num 1-9       straight to that camera
--   F9            back to the editor, the camera where you left it
--
-- Made the first time someone plays (GTA's Settings → Key Bindings → FiveM can move them), and dead
-- unless the Camera Creator is playing. While a shot rolls nothing is on screen but the picture
-- (CleanScreen); with "Clean screen" on (the card, kept on this PC) the whole time you play.
--
-- "Your vehicle" is the one you are in when it rolls; a sequence that plays round it (Plays round) puts its
-- fixed and trackside cameras round where it is at that moment, and a camera you switch to, round where it
-- is when you switch — so a camera set 20 m ahead of the car is always 20 m ahead to drive past.

local SWITCH_MS = 900     -- a smooth switch's glide from one camera to the next
local gameKeysMade = false
local gameStarted = 0     -- when the timeline started rolling (which camera it is on, for Page Up / Down)
local editorPose = nil    -- where the editor's camera was, for coming back

local function sendGame(text, kind)
    SendNUIMessage({ action = 'camEdGame', mode = S.game, live = S.liveCam, name = S.savedAs, cameras = keyCount(),
                     cleanAll = S.cleanAll, say = text, kind = kind })
end

--- A clean screen while a shot rolls, and the whole time you play if this PC chose so.
local function setClean()
    if S.game == 'live' or (S.game == 'play' and S.cleanAll) then CleanScreen.hold('cameraCreator')
    else CleanScreen.release('cameraCreator') end
end

local function whyNot(why)
    if why == 'busy' then return 'Another camera is up' end
    return why and (why:sub(1, 1):upper() .. why:sub(2)) or 'It would not roll'
end

--- Back to the game's camera (F5 while rolling).
local function cutToGame()
    if S.game ~= 'live' then return end
    if Camera.IsActive() then Camera.Stop() end
    S.game, S.liveCam = 'play', nil
    setClean()
    sendGame()
end

--- ACTION: the timeline from its start, live.
local function rollTimeline()
    if not S.clean then sendGame('No cameras yet: F9 back to the editor to place some', 'warn') return end
    local ok, why = Camera.PlaySequence(copy(S.seq), { subjects = S.subjects, async = true })
    if not ok then sendGame(whyNot(why), 'warn') return end
    S.game, S.liveCam, gameStarted = 'live', nil, GetGameTimer()
    setClean()
    sendGame()
end

--- The camera on screen now: the one held, or where the rolling timeline is.
local function currentCamera()
    if S.liveCam then return S.liveCam end
    if S.game ~= 'live' or not S.clean then return 0 end
    local t = GetGameTimer() - gameStarted
    if S.clean.loop and S.clean.length > 0 then t = t % S.clean.length end
    local at = 1
    for i, k in ipairs(S.clean.keys) do if k.t <= t then at = i end end
    return at
end

--- Camera `n` held live: its key's shot, its layers, until another camera or F5. Glides there from the
--- picture on screen when switching smoothly.
local function holdCamera(n)
    local keys = S.clean and S.clean.keys
    if not keys or #keys == 0 then sendGame('No cameras yet: F9 back to the editor to place some', 'warn') return end
    if n < 1 or n > #keys then sendGame(('There %s %d camera%s'):format(#keys == 1 and 'is' or 'are', #keys, #keys == 1 and '' or 's'), 'warn') return end
    local k = copy(keys[n])
    k.t, k.move = 0, 'cut'
    local seq = { keys = { k }, length = 0, anchor = S.clean.anchor, letterbox = S.clean.letterbox, ease = 'linear' }
    if S.smooth and S.game == 'live' then
        local p, r = GetFinalRenderedCamCoord(), GetFinalRenderedCamRot(2)
        local from = { x = p.x, y = p.y, z = p.z, pitch = r.x, roll = r.y, yaw = r.z, fov = GetFinalRenderedCamFov() }
        local s = S.clean.anchor and subjectNow(S.clean.anchor) or nil
        local anchor = s and { x = s.x, y = s.y, z = s.z, h = s.h } or nil
        k.t = SWITCH_MS
        seq.keys = { { t = 0, move = 'glide', ease = 'smooth', shot = CamShots.fixedFromCamera(from, anchor) }, k }
        seq.length = SWITCH_MS
    end
    local ok, why = Camera.PlaySequence(seq, { subjects = S.subjects, async = true, hold = true })
    if not ok then sendGame(whyNot(why), 'warn') return end
    S.game, S.liveCam = 'live', n
    setClean()
    sendGame()
end

--- While playing: a shot that ends by itself (the timeline's last moment) hands back to the game's camera.
local function gameLoop()
    while S.game do
        if S.game == 'live' and not Camera.IsActive() then
            S.game, S.liveCam = 'play', nil
            setClean()
            sendGame()
        end
        Wait(100)
    end
end

local function backToEditor()
    if not S.game then return end
    if S.game == 'live' and Camera.IsActive() then Camera.Stop() end
    S.game, S.liveCam = nil, nil
    CleanScreen.release('cameraCreator')
    sendGame()
    openEditor(editorPose)
    say('Back in the editor', 'info')
end

local function makeGameKeys()
    if gameKeysMade then return end
    gameKeysMade = true
    -- A key held across the change of mode acts once (the editor reads F9 itself, as the page's).
    local function gameKey(name, label, key, fn)
        RegisterCommand(name, function()
            if S.game and GetGameTimer() - S.modeAt > 400 then fn() end
        end, false)
        RegisterKeyMapping(name, 'Camera Creator: ' .. label, 'keyboard', key)
    end
    gameKey('whipcam_action', 'action (roll the shots, or cut back)', 'F5', function()
        if S.game == 'live' then cutToGame() else rollTimeline() end
    end)
    gameKey('whipcam_next', 'next camera', 'PAGEDOWN', function()
        local n = keyCount()
        if n > 0 then holdCamera(currentCamera() % n + 1) end
    end)
    gameKey('whipcam_prev', 'previous camera', 'PAGEUP', function()
        local n, c = keyCount(), currentCamera()
        if n > 0 then holdCamera(c <= 1 and n or c - 1) end
    end)
    for i = 1, 9 do
        gameKey('whipcam_' .. i, 'camera ' .. i, 'NUMPAD' .. i, function() holdCamera(i) end)
    end
    gameKey('whipcam_editor', 'back to the editor', 'F9', backToEditor)
end

--- PLAY IN GAME: the editor away, the player back, the shots ready.
function A.playInGame()
    if not S.open or GetGameTimer() - S.modeAt < 400 then return end
    if keyCount() == 0 then say('Place a camera first: G puts one where you are looking from', 'warn') return end
    makeGameKeys()
    editorPose = camNow()
    closeEditor()
    S.game, S.liveCam = 'play', nil
    setClean()
    sendGame()
    CreateThread(gameLoop)
end

--- This PC's playing choices, from the card.
function A.pref(field, value)
    if field == 'smooth' then S.smooth = value == true
    elseif field == 'cleanAll' then S.cleanAll = value == true
    else return end
    savePrefs()
    sendState()
end

function EnterCameraCreator()
    if S.open or S.game then return end
    if not S.seq then
        S.seq = emptySeq()
        loadDraft()
        loadPrefs()
    end
    if straightTime(S.seq) then S.dirty = true end
    local ok = rebuild()
    if not ok then S.seq = emptySeq(); rebuild() end
    openEditor(nil)
    say(keyCount() > 0 and 'Your draft is back where you left it' or 'Hold the right mouse button to fly, then G to add a key', 'info')
end

--- Out of Play in game, wherever it was: a live shot stopped, the clean screen let go. (No editor: who calls says.)
local function endGame()
    if not S.game then return end
    if S.game == 'live' and Camera.IsActive() then Camera.Stop() end
    S.game, S.liveCam = nil, nil
    CleanScreen.release('cameraCreator')
    sendGame()
end

--- Back to the player, who never moved (or who played on). The draft stays for next time.
function ExitCameraCreator()
    endGame()
    closeEditor()
end

--- Leaving from inside (Exit, Esc, B): the editor shut AND the /w switch off. DeactivateTool alone only
--- turns the switch off, which left the editor up.
leave = function()
    ExitCameraCreator()
    DeactivateTool('Camera Creator')
end

-- ============================================
-- The page's callbacks
-- ============================================

local function cb(name, fn)
    RegisterNUICallback(name, function(data, done)
        done('ok')
        if not S.open then return end
        fn(type(data) == 'table' and data or {})
    end)
end

cb('ceAdd', function(d) A.add(tonumber(d.t)) end)
cb('ceSetFromCamera', function(d) A.setFromCamera(tonumber(d.i)) end)
cb('ceDelete', function(d) A.delete(tonumber(d.i)) end)
cb('ceDuplicate', function(d) A.duplicate(tonumber(d.i)) end)
cb('ceSelect', function(d) A.select(tonumber(d.i)) end)
cb('ceStep', function(d) A.step(tonumber(d.dir) or 1) end)
cb('cePlay', function(d) A.play(d.on) end)
cb('ceScrub', function(d) A.scrub(d.t) end)
cb('ceView', function(d) A.view(d.on) end)
cb('ceMoveKey', function(d) A.moveKey(tonumber(d.i), d.t) end)
cb('ceEditKey', function(d) A.editKey(tonumber(d.i), d.field, d.value) end)
cb('ceSetKind', function(d) A.setKind(tonumber(d.i), d.kind) end)
cb('ceLookThrough', function(d) A.lookThrough(tonumber(d.i)) end)
cb('cePick', function() A.pick() end)
cb('ceSeq', function(d) A.editSeq(d.field, d.value) end)
cb('ceEven', function() A.evenTiming() end)
cb('ceUndo', function() A.undo() end)
cb('ceRedo', function() A.redo() end)
cb('ceNew', function() A.new() end)
cb('ceCopy', function() A.copy() end)
cb('ceList', function() A.list() end)
cb('ceSave', function(d) A.save(d.name) end)
cb('ceLoad', function(d) if type(d.name) == 'string' then A.load(d.name) end end)
cb('ceDeleteSaved', function(d) if type(d.name) == 'string' then A.deleteSaved(d.name) end end)
cb('ceTyping', function(d) S.typing = d.on == true end)
cb('ceClose', function() CreateThread(function() leave() end) end)
cb('cePlayInGame', function() A.playInGame() end)
cb('cePref', function(d) A.pref(d.field, d.value) end)
cb('ceControls', function(d) if d.game == nil then A.controls() else A.controls(d.game == true) end end)
cb('ceHud', function(d) if d.on == nil then A.hud() else A.hud(d.on == true) end end)
cb('cePoints', function(d) if d.on == nil then A.points() else A.points(d.on == true) end end)

-- ============================================
-- Register with the tool system
-- ============================================

ToolHandlers['Camera Creator'] = {
    enter = function() EnterCameraCreator() end,
    exit = function() ExitCameraCreator() end,
}

-- Dying in Play in game: its reason is over, and a clean screen would hide the death screen (its shot keys with it).
-- The draft stays, and the /w switch goes off with it, so one press there opens the editor again. Logging out: the
-- creator shut, as Exit does (character select must not come up under a clean screen).
AddEventHandler('whip_core:player:died', function()
    if not S.game then return end
    endGame()
    if not S.open then DeactivateTool('Camera Creator') end
end)
AddEventHandler('whip_core:player:logout', function()
    if S.open or S.game then CreateThread(function() leave() end) end
end)

-- A restart with the creator up hands the player back (FreeCam's own stop handler puts the camera away).
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() or not S.open then return end
    PedHold.release('cameraCreator')
    holdVehicle(false)   -- a car held still would stay frozen
    if S.filter ~= 'none' then ClearTimecycleModifier() end
end)
