-- ============================================
-- DirectorSteps — the one catalogue of task steps, on both sides
-- ============================================
--
-- Every step a placed thing's task list can hold (its page: Tasks), and every step the brain plays: what it is
-- called, which kinds can do it, its timing, its fields, and HOW IT BEHAVES, as flags on the step itself. Each file
-- that treats some steps their own way (an NPC riding a car, the world builder's preview, a standing NPC, a dead one,
-- a recorded drive) asks this file, never a list of its own: a new step says here what it does, once.
--
-- THE FLAGS (each optional; a step without one is false):
--   moves           takes it somewhere: one riding a car's deck lets go of the car first (client/npcs.lua)
--   endsRide        gets it out of a car, or on its feet somewhere: a rider's ride is over (server/npcs.lua)
--   faces           points it at its target: one riding a car turns to that (client/npcs.lua)
--   previewAtCamera in the world builder's preview "the nearest player" is the free camera (client/director_preview)
--   previewSkip     why the preview passes it over (it could hit you)
--   carPreview      a car's step the preview plays on a car of the editor's own (client/actors.lua ActorSteps)
--   standingSkip    why a STANDING NPC passes it over (no run's cars or players; it would hit whoever is near)
--   whenDead        a dead NPC's list still plays it (server/task_seq.lua)
--   flows           one followed by another of its kind walks on through its point to the next without stopping
--                   (server/task_seq.lua sends the next one with it as `ahead`; client/npcs.lua)
--   leftByDrives    car state a recorded drive sets too: a drive on a car whose list sets it leaves it alone
--   internal        played, never saved: the brain's own (an emote played as an animation, a route's look round)
--   length          its time is how long it lasts as one action (a prop's slide, a throw, the horn): 0 is at once,
--                   never no end
--   startSec        a NEW one of it is added with this time (the editor's + Task): 0, no end, for one that can go on
-- What the server works out for it as it starts (server/director/nodes_tasks.lua stepResolver) or as its list is read
-- (server/director/tasks.lua compile):
--   fights          the key of its field naming an NPC it fights: that NPC's network id
--   seesPlayers     the run's players (whom it fights, or writhes at)
--   emoteAnim       the key of its /e field: that emote's animation
--   seatsIn         the key of its field naming the run's car it gets into: that car's network id
--   playsTake       it plays one of its car's recorded drives (server/director/takes.lua): its moment and its game
--   untilWhen       { key, is }: while it holds, it waits for a card of the run (its `card` and `outs`) to give an
--                   outcome picked, not for a time; never on a prop's list (a timeline) or a standing NPC's
--   route           the key of its field naming a route: it is that route's walks and stops, once round, in its place
--   playsAs         { when, t }: while `when` holds it is played as step `t` (Play Emote set to an animation: 'anim')
--   problem(p)      what is wrong with its values beyond each field's own check (a name the game must know), or nil
--
-- THE TIMING of a step (the editor shows the rows that apply):
--   instant  done once the owner has applied it (a teleport, a health change)
--   timed    lasts `sec` seconds
--   until    waits for the owner to say it is done (it got there), giving up after `giveUp` seconds
--   either   the designer picks: `next` = 'done' (as until) or 'time' (as timed)
-- A TIME OF 0 IS NO END (Josh, 14 Nov 2026: a Shoot At shot for 3 seconds and stopped, its 3 greyed in the box as if
-- nothing were set). It goes on shooting, aiming, wandering until its list is stopped or the run ends. A NEW step that
-- can go on like that is added at 0 (`startSec`); a designer who wants it on a timer sets one. A step with no time saved
-- plays its type's `sec` (and `giveUp`), as it always did, so a scenario saved before plays as it was built. One that
-- does one thing and is over (a throw, the horn, a brake, a prop's slide: `length`) keeps a time, and its 0 is at once:
-- never no end, or nothing after it would ever start. A give-up is never 0 unless typed (0: it waits until it is done).
-- Sent as NO_END_MS (longer than any run lasts), so the server and every game play it as any time: it never runs out.
-- LASTING steps (a wander, a drive) keep going after their slot: a Wait after one keeps the NPC doing it, and a new
-- owner is sent the lasting step under a Wait so it carries on. ONCE steps (a line of speech, a throw) are never sent
-- again to a new owner: they would happen twice.
--
-- ITS WORDS on the editor's page beyond its label: doneText (when one that waits to be done is: "When it gets there";
-- false says nothing, a Wait for a card says its outcomes), secLabel (its time's row: "Takes" for one whose time is
-- how long its move takes; "For" else).
--
-- A field's kind is one of server/director/fields.lua's that a step may have (DirectorFields: refused at load else).
-- Another resource's steps (Whip.task) are the server's (server/director/tasks.lua): none of their flags are set here.

DirectorSteps = {}
local S = DirectorSteps

S.MAX_STEPS = 40
S.MAX_SEC   = 24 * 3600 - 1             -- a step's time at most: the editor's hours, minutes and seconds
S.NO_END_MS = 7 * 24 * 3600 * 1000      -- a time of 0 as it is sent: a week (THE TIMING, above)

-- ============================================
-- The fields steps share
-- ============================================

local function point(label, hint) return { key = 'at', kind = 'point', label = label or 'Where', hint = hint, required = true } end

--- Who or what a step points at: the nearest of the run's players, the one who set the card off, a placed thing, or
--- a point.
local TARGET = { key = 'target', kind = 'target', label = 'At', options = { 'nearest', 'trigger', 'thing', 'point' }, default = 'nearest' }
local WHO    = { key = 'target', kind = 'target', label = 'Who', options = { 'nearest', 'trigger', 'thing' }, default = 'nearest' }

local PACE   = { key = 'pace', kind = 'select', look = 'seg', label = 'Pace', options = { 'walk', 'run', 'sprint' }, default = 'walk' }

S.SEAT_N = { ['driver'] = -1, ['front passenger'] = 0, ['back left'] = 1, ['back right'] = 2, ['any free seat'] = -2 }
local SEAT   = { key = 'seat', kind = 'select', label = 'Seat', options = { 'driver', 'front passenger', 'back left', 'back right', 'any free seat' },
                 default = 'driver' }
local CAR    = { key = 'car', kind = 'world', worldKind = 'vehicle', label = 'Car', required = true }

-- GTA driving-style flags: normal stops for cars and lights, careful also slows round people, rushed swerves through
-- traffic and runs the lights.
S.STYLE_N = { normal = 786603, careful = 447, rushed = 1074528293 }
local STYLE   = { key = 'style', kind = 'select', look = 'seg', label = 'Driving', options = { 'normal', 'careful', 'rushed' }, default = 'normal' }

-- How it shoots and fights: how often it hits, how fast it pulls the trigger, single shots to full auto, and how good a
-- fighter it is (client/npcs.lua shooting). Shoot At's for the step's time; the Director's NPC Attacks card's (a copy of
-- each, server/director/nodes_world.lua) for its whole fight.
S.SHOOTING = {
    { key = 'accuracy', kind = 'number', slider = true, label = 'Accuracy', unit = '%', min = 0, max = 100, step = 5, default = 30 },
    { key = 'rate', kind = 'number', slider = true, label = 'Trigger finger', hint = 'how fast it fires', unit = '%', min = 10, max = 100, step = 5, default = 40 },
    { key = 'pattern', kind = 'select', look = 'seg', label = 'Fires', options = { 'single shots', 'bursts', 'full auto' }, default = 'full auto' },
    { key = 'skill', kind = 'select', look = 'seg', label = 'Fights like', options = { 'a rookie', 'a pro', 'a killer' }, default = 'a pro' },
}

-- (Whens: a field shown only while its step's Plays or Waits for says so.)
local BY_EMOTE, BY_ANIM = { key = 'by', is = 'emote' }, { key = 'by', is = 'animation' }
local BY_CARD = { key = 'by', is = 'card' }

local function kmh(default, label)
    return { key = 'speed', kind = 'number', label = label or 'Speed', hint = 'km/h', min = 5, max = 300, default = default }
end

-- ============================================
-- The catalogue
-- ============================================

S.GROUPS = {
    { key = 'move',  title = 'Move' },
    { key = 'look',  title = 'Look and aim' },
    { key = 'fight', title = 'Fight' },
    { key = 'act',   title = 'Act' },
    { key = 'car',   title = 'Car' },
    { key = 'body',  title = 'Body' },
    { key = 'wait',  title = 'Wait' },
}

local NPC, CAR_K, PROP = { npc = true }, { vehicle = true }, { prop = true }
local ALL = { npc = true, vehicle = true, prop = true }

S.TYPES = {}
S.ORDER = {}   -- the picker's order (internal ones are not in it)
local function T(t, def)
    def.t = t
    S.TYPES[t] = def
    if not def.internal then S.ORDER[#S.ORDER + 1] = t end
end

-- ---- Move ----
T('goTo', { label = 'Go To', group = 'move', kinds = NPC, timing = 'either', next = 'done', sec = 10, giveUp = 30,
    moves = true, endsRide = true, flows = true, doneText = 'When it gets there',
    fields = { point('Where'), PACE,
               { key = 'straight', kind = 'bool', label = 'In a straight line', hint = 'Ignores paths and walls', default = false } } })
-- A route of the World tab, once round from its first point (server/director/routes.lua): read as its walks and stops.
T('walkRoute', { label = 'Walk a Route', group = 'move', kinds = NPC, timing = 'instant', moves = true, endsRide = true, route = 'route',
    fields = { { key = 'route', kind = 'world', worldKind = 'route', label = 'Route', required = true },
               { key = 'loose', kind = 'bool', label = 'Loosely', hint = 'A few metres either side of each point', default = false } } })
T('wander', { label = 'Wander Nearby', group = 'move', kinds = NPC, timing = 'timed', sec = 20, startSec = 0, lasting = true,
    moves = true, endsRide = true,
    fields = { { key = 'radius', kind = 'number', label = 'Within', hint = 'metres of where it is', min = 2, max = 60, default = 8 } } })
T('teleport', { label = 'Teleport', group = 'move', kinds = ALL, timing = 'instant',
    moves = true, endsRide = true, whenDead = true, carPreview = true,
    fields = { point('To') } })
T('face', { label = 'Turn To Face', group = 'move', kinds = NPC, timing = 'timed', sec = 2, length = true, faces = true, previewAtCamera = true,
    fields = { TARGET } })
T('follow', { label = 'Follow', group = 'move', kinds = NPC, timing = 'timed', sec = 20, startSec = 0, lasting = true,
    moves = true, endsRide = true,
    fields = { WHO, PACE } })
T('flee', { label = 'Run Away From', group = 'move', kinds = NPC, timing = 'timed', sec = 10, startSec = 0, lasting = true,
    moves = true, endsRide = true, previewAtCamera = true,
    fields = { TARGET } })
-- It goes to its point and takes cover there, hiding from what the point faces (turn its marker to set that):
-- crouched behind something low, or against something tall, facing left or right along it. The next task starts
-- once it is in cover (or after a time, set so).
T('cover', { label = 'Take Cover', group = 'move', kinds = NPC, timing = 'either', next = 'done', sec = 10, giveUp = 20,
    lasting = true, moves = true, endsRide = true, doneText = 'When it is in cover',
    fields = { point('At', 'where it takes cover: turn the marker to face what it hides from'),
               { key = 'height', kind = 'select', look = 'seg', label = 'Behind', options = { 'something low', 'something tall' }, default = 'something low' },
               { key = 'side', kind = 'select', look = 'seg', label = 'Faces', hint = 'along its cover, as you look at what it hides from',
                 options = { 'left', 'right' }, default = 'right' } } })
T('slideTo', { label = 'Slide To', group = 'move', kinds = PROP, timing = 'timed', sec = 3, secLabel = 'Takes', length = true,
    fields = { point('To') } })
T('turnTo', { label = 'Turn To', group = 'move', kinds = PROP, timing = 'timed', sec = 2, secLabel = 'Takes', length = true,
    fields = { { key = 'heading', kind = 'number', slider = true, label = 'Heading', hint = 'a copy shows it as you slide',
                 unit = '°', min = 0, max = 360, step = 5, default = 0 } } })

-- ---- Look and aim ----
T('lookAt', { label = 'Look At', group = 'look', kinds = NPC, timing = 'timed', sec = 5, startSec = 0, previewAtCamera = true,
    fields = { TARGET, { key = 'eyes', kind = 'bool', label = 'Eyes only', hint = 'The head stays still', default = false } } })
-- Aim At and Shoot At use the gun it holds, else its best one, else it is handed a pistol (client/npcs.lua armed).
T('aimAt', { label = 'Aim At', group = 'look', kinds = NPC, timing = 'timed', sec = 5, startSec = 0, faces = true, previewAtCamera = true,
    fields = { TARGET } })
-- How it shoots, for the step's time (S.SHOOTING).
T('shootAt', { label = 'Shoot At', group = 'look', kinds = NPC, timing = 'timed', sec = 3, startSec = 0, faces = true, previewAtCamera = true,
    standingSkip = 'a standing NPC never shoots (it would hit whoever is near)',
    fields = { TARGET, S.SHOOTING[1], S.SHOOTING[2], S.SHOOTING[3], S.SHOOTING[4] } })
-- It is handed what it throws as the step starts (its model loaded first), throws it at a point, a placed thing or the
-- nearest player, and puts it away after.
T('throw', { label = 'Throw', group = 'look', kinds = NPC, timing = 'timed', sec = 2, length = true, once = true, faces = true, previewAtCamera = true,
    standingSkip = 'a standing NPC never throws (it would hit whoever is near)',
    fields = { { key = 'item', kind = 'select', label = 'What', options = { 'grenade', 'molotov', 'smoke grenade', 'flare', 'snowball', 'ball' },
                 default = 'grenade' },
               { key = 'target', kind = 'target', label = 'At', options = { 'point', 'thing', 'nearest', 'trigger' }, default = 'point' } } })

-- ---- Fight ----
T('fightPlayers', { label = "Fight the Scenario's Players", group = 'fight', kinds = NPC, timing = 'timed', sec = 30, startSec = 0, lasting = true,
    seesPlayers = true, previewSkip = 'it could hit you', standingSkip = 'an Always present NPC has no scenario players to fight',
    fields = {} })
T('fightNpc', { label = 'Fight an NPC', group = 'fight', kinds = NPC, timing = 'timed', sec = 30, startSec = 0, lasting = true,
    faces = true, fights = 'npc', previewSkip = 'it could hit you',
    fields = { { key = 'npc', kind = 'world', worldKind = 'npc', label = 'Who', required = true } } })

-- ---- Act ----
-- One of /e's emotes (picked from the emote menu, or typed), or any animation by its dictionary and clip: `by` says
-- which, and a field with a `when` shows (and counts) only while it holds (server/director/fields.lua). Played
-- as an animation, the step is an 'anim' one (server/director/tasks.lua compile).
T('emote', { label = 'Play Emote', group = 'act', kinds = NPC, timing = 'timed', sec = 10, startSec = 0, lasting = true,
    emoteAnim = 'emote', playsAs = { when = BY_ANIM, t = 'anim' },
    fields = { { key = 'by', kind = 'select', look = 'seg', label = 'Plays', options = { 'emote', 'animation' }, default = 'emote' },
               { key = 'emote', kind = 'emote', label = 'Emote', hint = '/e name', max = 40, when = BY_EMOTE },
               { key = 'dict', kind = 'text', label = 'Dictionary', max = 128, when = BY_ANIM },
               { key = 'clip', kind = 'text', label = 'Clip', max = 128, when = BY_ANIM },
               { key = 'loop', kind = 'bool', label = 'Over and over', default = true, when = BY_ANIM } },
    problem = function(p)
        if p.by == 'animation' then
            local function name(s) return type(s) == 'string' and s:match('^[%w_@%-/%.]+$') ~= nil end
            if not (name(p.dict) and name(p.clip)) then return 'an animation is a dictionary and a clip name' end
            return nil
        end
        if p.emote == nil or p.emote == '' then return 'has no emote picked' end
        for _, e in ipairs(EmoteList and EmoteList.emotes or {}) do
            if e.cmd == p.emote then
                if e.scenario or (e.dict and e.anim) then return nil end
                return ('"%s" has no animation to play'):format(p.emote)
            end
        end
        return ('"%s" is not an emote (see /e)'):format(tostring(p.emote))
    end })
-- The brain's own: Play Emote as an animation, and a route's stop that looks round or plays a scenario.
T('anim', { label = 'Play Animation', group = 'act', kinds = NPC, timing = 'timed', sec = 5, lasting = true, internal = true,
    fields = {} })
T('scenario', { label = 'Scenario', group = 'act', kinds = NPC, timing = 'timed', sec = 20, lasting = true, internal = true,
    fields = {} })
-- One of GTA's lines, in its own voice or another's (the page picks both from the game's list: html/js/director/
-- speech-voices.js). Not every voice has every line: one it has not got says nothing.
T('speech', { label = 'GTA Speech', group = 'act', kinds = NPC, timing = 'instant', once = true,
    fields = { { key = 'voice', kind = 'voice', label = 'Voice', hint = 'empty: its own', max = 64 },
               { key = 'line', kind = 'speechLine', label = 'Line', hint = 'GENERIC_HI', max = 64, required = true } },
    problem = function(p)
        if not tostring(p.line):match('^[%w_]+$') then return 'a speech line is a GTA name, like GENERIC_HI' end
        if p.voice ~= nil and p.voice ~= '' and not tostring(p.voice):match('^[%w_]+$') then
            return 'a voice is a GTA name, like A_M_M_BEACH_01_WHITE_FULL_01'
        end
        return nil
    end })

-- ---- Car (an NPC's) ----
T('getIn', { label = 'Get In', group = 'car', kinds = NPC, timing = 'until', giveUp = 20, moves = true, endsRide = true,
    seatsIn = 'car', standingSkip = 'getting in a car needs a car a run makes',
    fields = { CAR, SEAT } })
T('getOut', { label = 'Get Out', group = 'car', kinds = NPC, timing = 'until', giveUp = 10, moves = true, endsRide = true,
    fields = {} })
T('warpIn', { label = 'Sit In (at once)', group = 'car', kinds = NPC, timing = 'instant', moves = true, endsRide = true,
    seatsIn = 'car', standingSkip = 'sitting in a car needs a car a run makes',
    fields = { CAR, SEAT } })
T('driveTo', { label = 'Drive To', group = 'car', kinds = NPC, timing = 'either', next = 'done', sec = 30, giveUp = 120, moves = true,
    doneText = 'When it gets there',
    fields = { point('To'), kmh(60), STYLE } })
T('cruise', { label = 'Cruise Around', group = 'car', kinds = NPC, timing = 'timed', sec = 30, startSec = 0, lasting = true, moves = true,
    fields = { kmh(50), STYLE } })
T('followCar', { label = 'Follow in a Car', group = 'car', kinds = NPC, timing = 'timed', sec = 30, startSec = 0, lasting = true, moves = true,
    fields = { WHO, kmh(80) } })

-- ---- Car (the car's own) ----
-- A take: one of the car's recorded drives (its page: Scripted Driving Events), played exactly; done at its last moment.
T('take', { label = 'Play a Scripted Driving Event', group = 'car', kinds = CAR_K, timing = 'until', giveUp = 60, playsTake = true,
    fields = { { key = 'take', kind = 'take', label = 'Driving event', required = true } } })
T('brake', { label = 'Brake', group = 'car', kinds = CAR_K, timing = 'timed', sec = 3, length = true, fields = {} })
T('speedTo', { label = 'Speed Up To', group = 'car', kinds = CAR_K, timing = 'timed', sec = 3, length = true, fields = { kmh(60) } })
T('everyoneOut', { label = 'Everyone Out', group = 'car', kinds = CAR_K, timing = 'until', giveUp = 10, carPreview = true, fields = {} })
T('siren', { label = 'Siren', group = 'car', kinds = CAR_K, timing = 'instant', carPreview = true, leftByDrives = true,
    fields = { { key = 'on', kind = 'bool', label = 'On', default = true } } })
T('blowUp', { label = 'Blow Up', group = 'car', kinds = CAR_K, timing = 'instant', once = true, fields = {} })
-- Its doors, windows, lights, horn, engine and tyres, as GTA has them (client/actors.lua); locked by whip's own locks
-- (server/actors.lua, started). One of them by its place, or all of them.
local CAR_DOORS   = { 'front left', 'front right', 'back left', 'back right', 'bonnet', 'boot', 'all of them' }
local CAR_WINDOWS = { 'front left', 'front right', 'back left', 'back right', 'all of them' }
local CAR_TYRES   = { 'front left', 'front right', 'back left', 'back right', 'all of them' }
T('door', { label = 'Open or Shut a Door', group = 'car', kinds = CAR_K, timing = 'instant', carPreview = true,
    fields = { { key = 'door', kind = 'select', label = 'Which', options = CAR_DOORS, default = 'front left' },
               { key = 'how', kind = 'select', look = 'seg', label = 'It', options = { 'open', 'shut' }, default = 'open' } } })
T('windows', { label = 'Windows', group = 'car', kinds = CAR_K, timing = 'instant', carPreview = true,
    fields = { { key = 'window', kind = 'select', label = 'Which', options = CAR_WINDOWS, default = 'all of them' },
               { key = 'how', kind = 'select', look = 'seg', label = 'It', options = { 'down', 'up', 'smashed' }, default = 'down' } } })
T('lights', { label = 'Lights', group = 'car', kinds = CAR_K, timing = 'instant', carPreview = true, leftByDrives = true,
    fields = { { key = 'lights', kind = 'select', look = 'seg', label = 'Headlights', options = { 'on', 'off', 'as GTA has them' }, default = 'on' },
               { key = 'beam', kind = 'bool', label = 'Full beam', default = false },
               { key = 'inside', kind = 'bool', label = 'Light inside', default = false } } })
T('flashLights', { label = 'Flash the Lights', group = 'car', kinds = CAR_K, timing = 'timed', sec = 3, length = true, fields = {} })
T('indicators', { label = 'Indicators', group = 'car', kinds = CAR_K, timing = 'instant', carPreview = true, leftByDrives = true,
    fields = { { key = 'side', kind = 'select', look = 'seg', label = 'Which', options = { 'left', 'right', 'hazards', 'off' }, default = 'hazards' } } })
T('horn', { label = 'Sound the Horn', group = 'car', kinds = CAR_K, timing = 'timed', sec = 1, length = true, fields = {} })
T('alarm', { label = 'Set Off the Alarm', group = 'car', kinds = CAR_K, timing = 'instant', fields = {} })
T('engine', { label = 'Engine', group = 'car', kinds = CAR_K, timing = 'instant', carPreview = true, leftByDrives = true,
    fields = { { key = 'how', kind = 'select', look = 'seg', label = 'It', options = { 'on', 'off', 'smoking, stalled' }, default = 'off' } } })
T('tyres', { label = 'Tyres', group = 'car', kinds = CAR_K, timing = 'instant', carPreview = true,
    fields = { { key = 'tyre', kind = 'select', label = 'Which', options = CAR_TYRES, default = 'front left' },
               { key = 'how', kind = 'select', look = 'seg', label = 'It', options = { 'burst', 'fixed' }, default = 'burst' } } })
T('roof', { label = 'Convertible Roof', group = 'car', kinds = CAR_K, timing = 'instant', carPreview = true,
    fields = { { key = 'how', kind = 'select', look = 'seg', label = 'It', options = { 'down', 'up' }, default = 'down' } } })
-- Its engine alight: it burns, and in time it blows up.
T('fire', { label = 'Set on Fire', group = 'car', kinds = CAR_K, timing = 'instant', once = true, fields = {} })
T('dirt', { label = 'Dirt', group = 'car', kinds = CAR_K, timing = 'instant', carPreview = true,
    fields = { { key = 'pct', kind = 'number', label = 'Dirty', hint = '% (0: clean)', min = 0, max = 100, default = 100 } } })
T('lock', { label = 'Lock or Unlock', group = 'car', kinds = CAR_K, timing = 'instant',
    fields = { { key = 'on', kind = 'bool', label = 'Locked', hint = 'Off unlocks it', default = true } } })

-- ---- Body ----
T('setHealth', { label = 'Set Health', group = 'body', kinds = { npc = true, vehicle = true }, timing = 'instant', carPreview = true,
    fields = { { key = 'pct', kind = 'number', label = 'Health', hint = '%', min = 1, max = 100, default = 100 } } })
T('die', { label = 'Die', group = 'body', kinds = NPC, timing = 'instant', fields = {} })
T('revive', { label = 'Revive', group = 'body', kinds = NPC, timing = 'instant', whenDead = true, fields = {} })
T('writhe', { label = 'Writhe', group = 'body', kinds = NPC, timing = 'timed', sec = 10, startSec = 0, lasting = true,
    seesPlayers = true, standingSkip = 'a standing NPC has no run\'s players to writhe at',
    fields = {} })
T('freeze', { label = 'Freeze', group = 'body', kinds = { npc = true, vehicle = true }, timing = 'instant',
    fields = { { key = 'on', kind = 'bool', label = 'Frozen', hint = 'Off lets it move again', default = true } } })
T('weapon', { label = 'Hold a Weapon', group = 'body', kinds = NPC, timing = 'instant',
    fields = { { key = 'weapon', kind = 'weapon', label = 'Weapon', hint = 'empty: put it away', max = 64 } },
    problem = function(p)
        if p.weapon ~= '' and not tostring(p.weapon):upper():match('^WEAPON_[A-Z0-9_]+$') then
            return 'a weapon is a GTA name, like WEAPON_PISTOL'
        end
        return nil
    end })
T('fade', { label = 'Fade', group = 'body', kinds = PROP, timing = 'timed', sec = 1, secLabel = 'Takes', length = true,
    fields = { { key = 'pct', kind = 'number', label = 'Seen', hint = '% (0: gone)', min = 0, max = 100, default = 0 } } })
T('look', { label = 'Change Look', group = 'body', kinds = PROP, timing = 'instant',
    fields = { { key = 'variant', kind = 'number', label = 'Look', hint = 'its texture variation', min = 0, max = 15, default = 0 } } })

-- ---- Wait ----
-- For a time, or for a card of the run to give one of the outcomes picked (`outs`: its output pins) since the Wait
-- began (server/director/nodes_tasks.lua). `untilWhen`: that way it waits until then (giving up after its Gives up
-- after: an hour unless set), not for a time. Not a prop's: its list is a timeline every game plays from one moment.
-- (A Wait is a timer: a new one is 3 seconds, and 0 is no end, a hold until its list is stopped.)
T('wait', { label = 'Wait', group = 'wait', kinds = ALL, timing = 'timed', sec = 3, giveUp = 3600, untilWhen = BY_CARD,
    whenDead = true, doneText = false,
    fields = { { key = 'by', kind = 'select', look = 'seg', label = 'Waits for', options = { 'time', 'card' }, default = 'time' },
               { key = 'card', kind = 'card', label = 'The card', when = BY_CARD },
               { key = 'outs', kind = 'cardOuts', label = 'Goes on when it', when = BY_CARD } } })

-- ============================================
-- Asking it
-- ============================================

--- One of whip_core's steps by its type, or nil. To read: never changed.
function S.get(t) return S.TYPES[t] end

--- A flag of a step's (the header's list): its value, or false for a step without it (or another resource's).
function S.is(t, flag)
    local d = S.TYPES[t]
    return d ~= nil and d[flag] or false
end

--- Does step `t`, set as `p` (its values, saved or compiled), wait for a card of the run (its untilWhen)?
function S.waitsOnCard(t, p)
    local w = S.is(t, 'untilWhen')
    return w and type(p) == 'table' and p[w.key] == w.is or false
end

--- Of these steps ({ t }), the car state a recorded drive leaves to them: { lights = true, ... }, or nil for none.
function S.leftByDrives(list)
    local out = nil
    for _, s in ipairs(type(list) == 'table' and list or {}) do
        if type(s) == 'table' and S.is(s.t, 'leftByDrives') then
            out = out or {}
            out[s.t] = true
        end
    end
    return out
end
