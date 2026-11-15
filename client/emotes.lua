-- ============================================
-- EMOTES — /e, the cancel key, and the one path every emote plays and stops through
-- ============================================
--
-- The list is shared/emote_list.lua (EmoteList). This file plays one emote at a time:
--
--   Emotes.play(cmd, at?)   checks the player can emote, then starts it — on the spot, or at `at`
--                           ({ x, y, z, heading }, from emote placing) — and asks the server for its
--                           props (the server makes them: server/held_props.lua)
--   Emotes.stop()           THE ONLY WAY AN EMOTE ENDS. /e c, the cancel key, the watcher below,
--                           death, logout, a progress bar (client/ui.lua), a model swap
--                           (client/appearance.lua) and the give/place hooks all come here, so
--                           there is one place that can forget the props, and it doesn't.
--
-- THE WATCHER. Plenty of things take the ped away from an emote without asking: a gunny reload
-- clears the ped's tasks, a car door, a ragdoll. Nothing tells this file, and the props would be
-- left in the hand of someone no longer drinking. So while an emote runs, a thread looks every
-- 150 ms and ends it the moment it is no longer really happening. It is born with the emote and
-- ends with it.
--
-- STOP ONLY UNDOES WHAT IS STILL OURS. If a reload or a bar has already taken the ped, clearing
-- its tasks would kill that instead — so the anim is stopped, or the scenario cleared, only while
-- it is still the one playing.

Emotes = {}

--- [cmd] = the emote's entry in EmoteList.
local byCmd = {}
for _, e in ipairs(EmoteList and EmoteList.emotes or {}) do byCmd[e.cmd] = e end

--- The emote playing now: { def, props (asked the server for them), startedAt (when its task was
--- issued), froze, at }. A start still loading when it was replaced tells by `current ~= cur`.
local current = nil

--- Is the emote menu up? (Its open and close are further down; play and stop tell it what changed.)
local menuOpen = false

--- PICKING FOR SOMEONE ELSE (e.g. a hero shot's character): { fn, onClose, cmd } while the menu
--- is open in pick mode (Emotes.pickFor). Its cards go to fn instead of playing on the player.
local picker = nil

--- Tell an open menu what is playing and what is chosen, so its highlights follow.
local function pushMenuState()
    if not menuOpen then return end
    if picker then
        SendNUIMessage({ action = 'emotesState', state = { emote = picker.cmd } })
        return
    end
    SendNUIMessage({ action = 'emotesState', state = {
        emote = current and current.def.cmd or nil,
        walk  = Emotes.walk and Emotes.walk() or nil,
        mood  = Emotes.mood and Emotes.mood() or nil,
    } })
end

local UNARMED = GetHashKey('WEAPON_UNARMED')
local GRACE_MS = 500             -- the task starts a frame late; the watcher waits this long first
local SCENARIO_GRACE_MS = 1000   -- a scenario's enter animation plays before it counts as "using"

--- The TaskPlayAnim flag an emote's switches add up to: 1 repeat, 2 hold the last frame,
--- 16 upper body only, 32 the player keeps control.
local function flagOf(def)
    local f = 0
    if def.loop then f = f + 1 end
    if def.freeze then f = f + 2 end
    if def.move then f = f + 48 end
    return f
end

--- Why the player can't emote right now, or nil when they can.
---
--- An open screen is NOT a reason: the emote menu is a screen, and its Play button has to work.
local function blockedBy()
    if not PlayerLoaded then return 'Not yet' end
    if PlayerIsDead then return "You can't do that while down" end
    local ped = PlayerPedId()
    if IsPedInAnyVehicle(ped, false) then return 'Get out of the vehicle first' end
    if LocalPlayer.state[PLAYER_ESCORTED_KEY] then return "Not while you're being escorted" end
    if UI and UI.IsBusy and UI.IsBusy() then return 'Not right now' end
    if ThrowModeActive or PlacingModeActive or FurnishModeActive then return 'Not right now' end
    if IsPedFalling(ped) or IsPedRagdoll(ped) or IsPedSwimming(ped) or IsPedInParachuteFreeFall(ped) then
        return 'Not right now'
    end
    if GetSelectedPedWeapon(ped) ~= UNARMED then return 'Put your weapon away first' end
    return nil
end

--- Is the player pushing to move? Read held, and read as DISABLED controls, which answer whether
--- or not anything has disabled them — the keys and the pad's stick alike.
local function wantsToMove()
    for c = 32, 35 do
        if IsDisabledControlPressed(0, c) then return true end
    end
    return math.abs(GetDisabledControlNormal(0, 30)) > 0.5 or math.abs(GetDisabledControlNormal(0, 31)) > 0.5
end

--- Why the emote `cur` is over, or nil while it is still really playing.
local function endedBy(cur)
    if PlayerIsDead then return 'dead' end
    local ped = PlayerPedId()
    if IsPedInAnyVehicle(ped, false) or IsPedRagdoll(ped) or IsPedFalling(ped) then return 'busy' end
    if LocalPlayer.state[PLAYER_ESCORTED_KEY] then return 'escorted' end
    if GetSelectedPedWeapon(ped) ~= UNARMED then return 'armed' end

    local age = GetGameTimer() - cur.startedAt
    local def = cur.def
    if def.scenario then
        if age > SCENARIO_GRACE_MS and not IsPedUsingScenario(ped, def.scenario) then return 'over' end
    elseif cur.dict and age > GRACE_MS and not IsEntityPlayingAnim(ped, cur.dict, def.anim, 3) then
        return 'over'   -- a one-shot finished, or something else took the ped
    end

    -- Standing up out of a full-body emote is how you leave it: push to move and it ends. (A prop-only
    -- emote has no body to stand up out of — carrying the thing IS the walking.)
    local fullBody = (def.dict ~= nil or def.scenario ~= nil) and not def.move
    if fullBody and age > GRACE_MS and wantsToMove() then return 'moved' end
    return nil
end

local function watch(cur)
    CreateThread(function()
        while current == cur do
            Wait(150)
            if current ~= cur then return end
            if endedBy(cur) then
                Emotes.stop()
                return
            end
        end
    end)
end

--- The loading half of play: the dict, the task, the props. Runs in its own thread, because
--- loading waits and play() answers straight away.
local function start(cur, at)
    local def = cur.def
    local ped = PlayerPedId()

    if def.scenario then
        TaskStartScenarioInPlace(ped, def.scenario, 0, true)
        cur.startedAt = GetGameTimer()
    elseif not def.dict then
        -- PROP ONLY: something held or worn (a backpack, a briefcase, a rose in the teeth) while the
        -- player moves as normal. No task, so nothing for the watcher's clip check to lose.
        cur.startedAt = GetGameTimer()
    else
        if not LoadAnimDict(def.dict, 2000) then
            if current == cur then
                current = nil
                UI.Notify('That emote would not load', 'error')
            end
            return
        end
        if current ~= cur then
            RemoveAnimDict(def.dict)
            return
        end
        cur.dict = def.dict
        ped = PlayerPedId()
        if at then
            -- Exactly where the ghost stood and posed the way the ghost was (client/emote_place.lua
            -- puts it there and plays the clip on the spot): moved there, held there, played there.
            -- Held, because gravity lowers a spot on a table edge and a bench pushes a seated ped
            -- off itself. Loop or hold only — placing allows no other.
            SetEntityCoordsNoOffset(ped, at.x, at.y, at.z, false, false, false)
            SetEntityHeading(ped, at.heading)
            PedHold.set('emotePlace', { frozen = true })   -- client/ped_hold.lua: one of the ped's freezes
            cur.froze = true
            TaskPlayAnim(ped, def.dict, def.anim, 8.0, -8.0, -1, def.loop and 1 or 2, 0.0, false, false, false)
        else
            TaskPlayAnim(ped, def.dict, def.anim, 8.0, -8.0, -1, flagOf(def), 0.0, false, false, false)
        end
        -- The grace period counts from the task, not from play(): the dict may have taken two
        -- seconds to load, and the clip is only "playing" from the next frame.
        cur.startedAt = GetGameTimer()
    end

    -- THE PROPS ARE THE SERVER'S. It reads them from its own emote list, makes them, and has the
    -- owning client put them in the hand (server/held_props.lua); this client only names the emote.
    if def.props then
        TriggerServerEvent('whip_core:server:emoteProps', def.cmd)
        cur.props = true
    end
end

--- Play an emote by its /e name. Answers true, or false and why. Returns at once; the emote
--- starts a moment later, once its animation has loaded.
---@param cmd string
---@param at table|nil  { x, y, z, heading } — a placed spot (client/emote_place.lua)
---@return boolean ok
---@return string|nil why
function Emotes.play(cmd, at)
    local def = byCmd[cmd]
    if not def then return false, ('There is no emote called "%s"'):format(tostring(cmd)) end
    local why = blockedBy()
    if why then return false, why end

    -- A new emote replaces one being placed (placing itself has already finished when it gets here).
    if Emotes.cancelPlace then Emotes.cancelPlace() end
    Emotes.stop()
    local cur = { def = def, props = false, startedAt = GetGameTimer(), at = at }
    current = cur
    pushMenuState()
    CreateThread(function()
        start(cur, at)
        if current == cur then watch(cur) end
    end)
    return true
end

--- End the emote playing now, if there is one. Answers whether there was.
---@return boolean
function Emotes.stop()
    local cur = current
    if not cur then return false end
    current = nil

    local ped = PlayerPedId()
    local def = cur.def
    if cur.dict then
        if IsEntityPlayingAnim(ped, cur.dict, def.anim, 3) then StopAnimTask(ped, cur.dict, def.anim, 1.0) end
        RemoveAnimDict(cur.dict)
    elseif def.scenario and IsPedUsingScenario(ped, def.scenario) then
        ClearPedTasks(ped)
    end
    -- Asked for, so given back: the server deletes them (only if they are still this emote's).
    if cur.props then TriggerServerEvent('whip_core:server:heldPropsDrop', 'emote') end
    -- This emote's freeze only: death holds its own while the player is down (client/death.lua).
    if cur.froze then PedHold.release('emotePlace') end
    pushMenuState()
    return true
end

--- Why the player can't emote right now, or nil when they can. (Placing asks before it starts.)
---@return string|nil
function Emotes.blockedBy() return blockedBy() end

--- Is the player pushing to move? (Placing cancels its walk on it.)
---@return boolean
function Emotes.wantsToMove() return wantsToMove() end

--- The /e name of the emote playing now, or nil.
---@return string|nil
function Emotes.current()
    return current and current.def.cmd or nil
end

--- An emote's entry in EmoteList, or nil.
---@param cmd string
---@return table|nil
function Emotes.get(cmd)
    return byCmd[cmd]
end

-- ============================================
-- Everything that ends an emote from outside
-- ============================================

AddEventHandler('whip_core:player:died', function() Emotes.stop() end)
AddEventHandler('whip_core:player:logout', function() Emotes.stop() end)

-- Giving an item or placing one takes the hands and the camera.
RegisterClientHook('beforeGiveMode', function() Emotes.stop() end, 'emotes')
RegisterClientHook('beforePlaceMode', function() Emotes.stop() end, 'emotes')

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then Emotes.stop() end
end)

-- ============================================
-- Walk style
-- ============================================
--
-- GTA shares a ped's walk with other players by itself, so only this client applies it. What it
-- does NOT do is keep it: a new model (login, /charedit), a respawn or a revive can come back with
-- the default walk. So it is applied again at each of those moments.
--
-- LAYERED. Something else may want the walk for a while — whip_drunk_example's stagger. It asks with
-- SetWalkOverride, which wins while it is set; when it is cleared, the walk the player chose comes
-- back, not the game's default. The latest override wins when there are several.

local walkByCmd, moodByCmd = {}, {}
for _, w in ipairs(EmoteList and EmoteList.walks or {}) do walkByCmd[w.cmd] = w end
for _, m in ipairs(EmoteList and EmoteList.moods or {}) do moodByCmd[m.cmd] = m end

local chosenWalk = nil        -- the player's own choice (a walk cmd), from the character's metadata
local overrides = {}          -- [resource] = { clipset, seq }
local overrideSeq = 0
local walkApplying = false
local walkAgain = false

--- The clipset that should be on the ped now: the newest override, else the chosen walk, else nil.
local function wantedClipset()
    local best
    for _, o in pairs(overrides) do
        if not best or o.seq > best.seq then best = o end
    end
    if best then return best.clipset end
    local w = chosenWalk and walkByCmd[chosenWalk]
    return w and w.clipset or nil
end

--- Put the wanted walk on the ped. May be called any time; never waits (the clipset loads in a
--- thread), and a call that lands while one is loading is honoured when it finishes.
local function applyWalk()
    if walkApplying then walkAgain = true return end
    walkApplying = true
    CreateThread(function()
        repeat
            walkAgain = false
            local clipset = wantedClipset()
            local ped = PlayerPedId()
            if clipset then
                if LoadAnimSet(clipset, 1000) then SetPedMovementClipset(PlayerPedId(), clipset, 0.25) end
            else
                ResetPedMovementClipset(ped, 0.25)
            end
        until not walkAgain
        walkApplying = false
    end)
end

--- Choose a walk: a /walk name, or nil for the normal one. Answers true, or false and why.
---@param cmd string|nil
function Emotes.setWalk(cmd)
    if cmd ~= nil and not walkByCmd[cmd] then return false, ('There is no walk called "%s"'):format(cmd) end
    chosenWalk = cmd
    applyWalk()
    TriggerServerEvent('whip_core:server:setWalk', cmd or 'c')
    pushMenuState()
    return true
end

--- The chosen walk's /walk name, or nil.
function Emotes.walk() return chosenWalk end

--- A walk's clipset: a /walk name from the walks list ('trash'), or a clipset as it is ('clipset@move@...').
---@param walk string
---@return string|nil
function Emotes.walkClipset(walk)
    if type(walk) ~= 'string' or walk == '' then return nil end
    local w = walkByCmd[walk]
    return w and w.clipset or walk
end

--- Take over the walk for a while under `key` (whip_core's own: give mode), or give it back with nil. The same layer
--- as the SetWalkOverride export (latest wins; the player's own walk returns when every override is gone).
---@param key string
---@param clipset string|nil
function Emotes.overrideWalk(key, clipset)
    if clipset == nil or clipset == false then
        if overrides[key] == nil then return end
        overrides[key] = nil
    else
        overrideSeq = overrideSeq + 1
        overrides[key] = { clipset = tostring(clipset), seq = overrideSeq }
    end
    applyWalk()
end

-- ============================================
-- Mood (facial expression)
-- ============================================
--
-- GTA does NOT share a face, so the server puts each player's mood on their statebag
-- (PLAYER_MOOD_KEY) and every client puts it on that player's ped — this player's own included.
--
-- A ped that goes out of range and comes back is a NEW ped, without the face. So while anyone in
-- the session has a mood, a loop looks once a second for peds it has not dressed yet. The mood is
-- read from the bag each time, never from memory: a player who leaves and a newcomer who is given
-- the same server id must not inherit the face.

local moodWatch = {}          -- [serverId] = the ped handle last given its face (or false)
local moodLoop = false

--- This player's own mood, kept here rather than read off the bag: inside the change handler the
--- bag still holds the OLD value, and the menu wants the new one.
local myMood = nil

local function myServerId() return GetPlayerServerId(PlayerId()) end

local function faceOn(ped, cmd)
    local m = cmd and moodByCmd[cmd]
    if m then SetFacialIdleAnimOverride(ped, m.anim, (nil) --[[@as string]]) else ClearFacialIdleAnimOverride(ped) end
end

local function refreshMoods()
    for id, dressed in pairs(moodWatch) do
        local cmd = Player(id).state[PLAYER_MOOD_KEY]
        local p = GetPlayerFromServerId(id)
        local ped = p ~= -1 and GetPlayerPed(p) or 0
        if cmd == nil then
            if ped ~= 0 and DoesEntityExist(ped) then ClearFacialIdleAnimOverride(ped) end
            moodWatch[id] = nil
        elseif ped ~= 0 and DoesEntityExist(ped) then
            if IsEntityDead(ped) then
                -- Dressed again once they are back up: a death keeps the same ped,
                -- so the handle test below never re-dressed it, and GTA may drop a dead ped's face.
                moodWatch[id] = false
            elseif ped ~= dressed then
                faceOn(ped, cmd)
                moodWatch[id] = ped
            end
        end
    end
end

local function startMoodLoop()
    if moodLoop then return end
    moodLoop = true
    CreateThread(function()
        while next(moodWatch) ~= nil do
            Wait(1000)
            refreshMoods()
        end
        moodLoop = false
    end)
end

AddStateBagChangeHandler(PLAYER_MOOD_KEY, nil, function(bagName, _, value)
    local id = tonumber(bagName:match('^player:(%d+)$'))
    if not id then return end
    -- The bag still holds the OLD value inside this handler; `value` is the new one.
    local p = GetPlayerFromServerId(id)
    local ped = p ~= -1 and GetPlayerPed(p) or 0
    if ped ~= 0 and DoesEntityExist(ped) then faceOn(ped, value) end
    if value == nil then
        moodWatch[id] = nil
    else
        moodWatch[id] = (ped ~= 0 and ped) or false
        startMoodLoop()
    end
    if id == myServerId() then
        myMood = value
        pushMenuState()
    end
end)

--- Choose a mood: a /mood name, or nil for none. Answers true, or false and why.
---@param cmd string|nil
function Emotes.setMood(cmd)
    if cmd ~= nil and not moodByCmd[cmd] then return false, ('There is no mood called "%s"'):format(cmd) end
    faceOn(PlayerPedId(), cmd)     -- at once here; everyone else hears it from the bag
    myMood = cmd
    TriggerServerEvent('whip_core:server:setMood', cmd or 'c')
    pushMenuState()
    return true
end

--- This player's mood's /mood name, or nil.
function Emotes.mood() return myMood end

-- ============================================
-- Putting them back
-- ============================================

--- The walk and this player's own face, again. The metadata is the record of both.
local function restyle()
    local meta = PlayerData and PlayerData.metadata or {}
    chosenWalk = walkByCmd[meta.walk] and meta.walk or nil
    applyWalk()
    local id = myServerId()
    local mood = Player(id).state[PLAYER_MOOD_KEY]
    myMood = mood
    if mood then
        faceOn(PlayerPedId(), mood)
        moodWatch[id] = PlayerPedId()
        startMoodLoop()
    end
end

AddEventHandler('whip_core:player:loaded', restyle)
AddEventHandler('whip_core:player:spawned', restyle)
AddEventHandler('whip_core:player:revived', restyle)
AddEventHandler('whip_core:appearance:modelChanged', restyle)

AddEventHandler('whip_core:player:logout', function()
    chosenWalk = nil
    myMood = nil
    applyWalk()
end)

-- A resource's override goes with it.
AddEventHandler('onResourceStop', function(res)
    if overrides[res] then
        overrides[res] = nil
        applyWalk()
    end
end)

--- Take over the walk for a while (whip_drunk_example's stagger), or give it back with nil. The player's
--- own walk returns when every override is gone. Keyed by the calling resource, and cleared when
--- that resource stops.
exports('SetWalkOverride', function(clipset)
    local owner = GetInvokingResource() or GetCurrentResourceName()
    if clipset == nil or clipset == false then
        overrides[owner] = nil
    else
        overrideSeq = overrideSeq + 1
        overrides[owner] = { clipset = tostring(clipset), seq = overrideSeq }
    end
    applyWalk()
    return true
end)

-- ============================================
-- Commands and keys
-- ============================================

local function say(ok, why)
    if not ok and why then UI.Notify(why, 'error') end
end

--- /e drink   /e c   /e place sitchair   /e (the menu)
RegisterCommand('e', function(_, args)
    local a = tostring(args[1] or ''):lower()
    if a == '' then
        if Emotes.openMenu then Emotes.openMenu() end
    elseif a == 'c' then
        Emotes.stop()
    elseif a == 'place' then
        if Emotes.place then say(Emotes.place(tostring(args[2] or ''):lower())) end
    else
        say(Emotes.play(a))
    end
end, false)

--- /walk gangster   /walk c
RegisterCommand('walk', function(_, args)
    local a = tostring(args[1] or ''):lower()
    if a == '' then
        if Emotes.openMenu then Emotes.openMenu('walks') end
        return
    end
    say(Emotes.setWalk(a ~= 'c' and a or nil))
end, false)

--- /mood angry   /mood c
RegisterCommand('mood', function(_, args)
    local a = tostring(args[1] or ''):lower()
    if a == '' then
        if Emotes.openMenu then Emotes.openMenu('moods') end
        return
    end
    say(Emotes.setMood(a ~= 'c' and a or nil))
end, false)

RegisterCommand('whip_emote_cancel', function() Emotes.stop() end, false)
RegisterKeyMapping('whip_emote_cancel', 'Emotes: Stop the current emote', 'keyboard',
    (Config.Emotes and Config.Emotes.cancelKey) or 'X')

-- Chat help. On load rather than at file scope: whip_chat starts after whip_core, and a
-- suggestion sent before it is listening is lost.
AddEventHandler('whip_core:player:loaded', function()
    TriggerEvent('chat:addSuggestion', '/e', 'Play an emote', {
        { name = 'emote', help = 'e.g. drink — "c" stops it, "place <emote>" places it where you aim' },
    })
    TriggerEvent('chat:addSuggestion', '/walk', 'Change how you walk', {
        { name = 'style', help = 'e.g. gangster — "c" goes back to normal' },
    })
    TriggerEvent('chat:addSuggestion', '/mood', 'Change your facial expression', {
        { name = 'mood', help = 'e.g. angry — "c" goes back to normal' },
    })
end)

-- ============================================
-- The menu (html/js/emotes.js)
-- ============================================
--
-- A SCREEN LIKE ANY OTHER: Emotes.isMenuOpen() is one of the screens IsAnyUIOpen counts
-- (client/inventory.lua), so prompts and the HUD stand down while it is up. It takes full NUI focus
-- — the search field is typed in, and a keystroke must never reach the game underneath.

--- What the page lists. Built once: the list does not change while the resource runs.
local menuData = nil
local function buildMenuData()
    if menuData then return menuData end
    local function plain(list)
        local out = {}
        for _, x in ipairs(list or {}) do out[#out + 1] = { cmd = x.cmd, label = x.label, video = x.video } end
        return out
    end
    local emotes = {}
    for _, e in ipairs(EmoteList and EmoteList.emotes or {}) do
        emotes[#emotes + 1] = {
            cmd = e.cmd, label = e.label, category = e.category, video = e.video,
            -- Placing is for an animation that stays — a loop or a held pose. A scenario or a
            -- one-shot has nothing to line up.
            placeable = e.dict ~= nil and (e.loop == true or e.freeze == true),
        }
    end
    menuData = {
        categories = EmoteList and EmoteList.categories or {},
        emotes     = emotes,
        walks      = plain(EmoteList and EmoteList.walks),
        moods      = plain(EmoteList and EmoteList.moods),
    }
    return menuData
end

function Emotes.isMenuOpen() return menuOpen end

--- Open the menu on a tab: 'emotes' (default), 'walks' or 'moods'.
---@param tab string|nil
function Emotes.openMenu(tab)
    if menuOpen or not PlayerLoaded or PlayerIsDead then return end
    if IsAnyUIOpen and IsAnyUIOpen() then return end
    menuOpen = true
    Focus.take('emotes', { screen = true })   -- a screen: FocusScreenUp sees it by its hold
    SendNUIMessage({
        action = 'emotesOpen',
        tab    = tab or 'emotes',
        data   = buildMenuData(),
        state  = { emote = Emotes.current(), walk = chosenWalk, mood = myMood },
    })
end

--- Open the menu to pose someone else (a hero shot's character, tools/panel_sections/hero_shots.lua): the
--- emotes tab only, no Place, and each card clicked goes to fn(cmd) instead of playing on the player; Stop
--- gives fn(nil). It stays open to try another, and opens over the caller's screen (the furnisher), which gets
--- its keys back when it closes. opts: current (the emote picked so far), onClose (fn, once it has closed).
---@param fn function
---@param opts table|nil
---@return boolean ok
function Emotes.pickFor(fn, opts)
    if menuOpen or type(fn) ~= 'function' then return false end
    opts = type(opts) == 'table' and opts or {}
    picker = { fn = fn, onClose = opts.onClose, cmd = type(opts.current) == 'string' and opts.current or nil }
    menuOpen = true
    Focus.take('emotes', { screen = true })
    SendNUIMessage({ action = 'emotesOpen', tab = 'emotes', pick = true, data = buildMenuData(),
        state = { emote = picker.cmd } })
    return true
end

--- Is the menu open for a pickFor?
function Emotes.isPicking() return picker ~= nil end

--- What a pick sends: fn(cmd), the highlight moved to it. A pick that errors is said in F8, not thrown.
local function picked(cmd)
    local p = picker
    if not p then return end
    p.cmd = cmd
    local ok, err = pcall(p.fn, cmd)
    if not ok then print('[whip_core:emotes] the pick failed: ' .. tostring(err)) end
    pushMenuState()
end

function Emotes.closeMenu()
    if not menuOpen then return end
    menuOpen = false
    Focus.release('emotes')
    SendNUIMessage({ action = 'emotesClose' })
    local p = picker
    picker = nil
    if p and p.onClose then
        local ok, err = pcall(p.onClose)
        if not ok then print('[whip_core:emotes] the pick\'s close failed: ' .. tostring(err)) end
    end
end

RegisterNUICallback('emotesClose', function(_, cb)
    cb('ok')
    Emotes.closeMenu()
end)

RegisterNUICallback('emotePlay', function(d, cb)
    cb('ok')
    local cmd = tostring(d and d.cmd or '')
    if picker then
        if byCmd[cmd] then picked(cmd) end
        return
    end
    say(Emotes.play(cmd))
end)

RegisterNUICallback('emoteStop', function(_, cb)
    cb('ok')
    if picker then picked(nil) return end
    Emotes.stop()
end)

-- Placing needs the world and the mouse, so the menu gets out of the way first. (Picking has no Place.)
RegisterNUICallback('emotePlace', function(d, cb)
    cb('ok')
    if picker then return end
    Emotes.closeMenu()
    if Emotes.place then say(Emotes.place(tostring(d and d.cmd or ''))) end
end)

RegisterNUICallback('emoteWalk', function(d, cb)
    cb('ok')
    if picker then return end
    local cmd = tostring(d and d.cmd or '')
    say(Emotes.setWalk(cmd ~= 'c' and cmd or nil))
end)

-- A preview video the menu could not play (html/js/emotes.js reports the first few). On screen a
-- missing file and a format the game's browser refuses look the same; the F8 console says which.
RegisterNUICallback('emoteVideoError', function(d, cb)
    cb('ok')
    print(('[whip_core:emotes] preview video did not play: %s (%s)'):format(
        tostring(d and d.src or '?'):sub(1, 120), tostring(d and d.why or '?'):sub(1, 80)))
end)

RegisterNUICallback('emoteMood', function(d, cb)
    cb('ok')
    if picker then return end
    local cmd = tostring(d and d.cmd or '')
    say(Emotes.setMood(cmd ~= 'c' and cmd or nil))
end)

-- No key of its own: the menu is on the F1 wheel (below) and /emotes. F3 is the phone's (whip_phone).
RegisterCommand('emotes', function() Emotes.openMenu() end, false)
RegisterCommand('whip_emotes', function() Emotes.openMenu() end, false)

-- Anything that takes the player out of the world takes the menu with it.
AddEventHandler('whip_core:player:died', function() Emotes.closeMenu() end)
AddEventHandler('whip_core:player:logout', function() Emotes.closeMenu() end)
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then Focus.release('emotes') end
end)

-- On the F1 wheel. On onReady, like core's vehicle options: it fires once every client file has
-- run, and adding the same id again replaces it, so a restart cannot stack two.
AddEventHandler('whip_core:onReady', function()
    Actions.add(GetCurrentResourceName(), {
        id       = 'emotes',
        at       = { radial = true },
        label    = 'Emotes',
        icon     = 'emote',
        description = 'Dance, wave, sit and more',
        onSelect = function() Emotes.openMenu() end,
    })
end)

-- ============================================
-- Exports
-- ============================================

exports('PlayEmote', function(cmd) return Emotes.play(tostring(cmd or ''):lower()) end)
exports('CancelEmote', function() return Emotes.stop() end)
exports('IsEmoting', function() return Emotes.current() or false end)
