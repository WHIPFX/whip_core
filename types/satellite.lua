---@meta
-- ============================================
-- whip_core — the satellite helper (lib/satellite.lua)
-- ============================================
--
-- The `Whip` table your resource gets from:
--
--     shared_script '@whip_core/lib/satellite.lua'
--
-- It runs in YOUR resource (whip_core forgets everything when it restarts; this has to remember
-- across that), on the server and the client alike.

-- The stubs are declared on the class and Whip is given its type at the end of this file, so an editor that also has
-- lib/satellite.lua open (whip_core itself) reads that file as their implementation, not as second definitions.
---@class WhipSatellite
local WhipSatellite = {}

--- Run `fn` when whip_core is ready (whichever of you started first), and again every time
--- whip_core restarts. Put everything you register with whip in it, or declare it one call at a time through
--- Whip.declare. Not re-run when some other resource starts.
---@param fn fun()
function WhipSatellite.register(fn) end

--- whip_core's declaring exports, each remembered and made again whenever whip_core needs it, with no function
--- around it: `Whip.declare:RegisterItem('lemonade', { ... })` is `RegisterItem` inside Whip.register, with a
--- refusal printed in your console. Only declarations: Register…, Ensure…, On… and Watch… exports, SecureEvent,
--- SecureCallback, AddAction, AddItemOption, AddPoint and AddWeapons; anything else is refused. The arguments are
--- taken once, as you call it, and the call answers only true (taken) or false (refused): for a value that changes
--- (a Config value on your settings page) or an answer you keep (an AddAction id), use Whip.register.
---@type WhipCoreServerExports|WhipCoreClientExports
WhipSatellite.declare = {}

--- Only for a resource WITHOUT `dependency 'whip_core'` (with it, your resource is stopped first and this
--- never runs). Run `fn` when whip_core stops — to let go of something that only made sense while it ran.
--- Registrations need no cleanup. A handler still waiting in `exports.whip_core:Progress` is never
--- answered, so clear what it holds here — or make that call through Whip.call.
---@param fn fun()
function WhipSatellite.onCoreLost(fn) end

--- A registry of your own, with whip's rule: an entry is its first registrant's; the same again changes nothing;
--- a changed one replaces it; another resource's is refused (said once in your console); a resource's entries
--- go when it stops. For a resource others extend (apps, plugins, parts).
---     local Apps = Whip.registry('phoneApp', { label = 'app' })
---     exports('RegisterApp', function(id, def) return Apps:add(Whip.caller(), id, def) end)
---@param name string
---@param opts { label?: string, scoped?: boolean, sweep?: boolean, same?: function|false, validate?: function, onAdd?: function, onRemove?: function, prefixed?: boolean }|nil
---@return { add: fun(self, owner: string, id: string|number, value: any, opts?: table): boolean, any, remove: fun(self, owner: string, id: string|number): boolean, string?, get: fun(self, key: any): any, ownerOf: fun(self, key: any): string?, keysOf: fun(self, owner: string): any[], entries: table }
function WhipSatellite.registry(name, opts) end

--- The resource calling your export, or your own name when nothing did. Read it first, before anything waits.
---@return string
function WhipSatellite.caller() end

--- Run `fn` now if `resource` is running, and again each time it starts: register with another resource's
--- registry so its restart brings yours back. Each run in its own thread.
---@param resource string
---@param fn fun()
function WhipSatellite.registerWith(resource, fn) end

--- SERVER. A command behind whip's gate, as a SecureEvent is: refused while the player is down (unless
--- whileDead), rate limited (3 at once, then one a second, unless rateLimit = false), and with dev = true only the
--- console and whip.devtools with developer mode on. A refusal is said to the player. fn runs in its own thread.
---     Whip.command('ropes', { dev = true }, function(source, args, raw) ... end)
---@param name string
---@param opts { dev?: boolean, ace?: string, whileDead?: boolean, rateLimit?: false|{ burst: number, everyMs: number }, console?: boolean }|nil
---@param fn fun(source: number, args: string[], raw: string)
function WhipSatellite.command(name, opts, fn) end

--- Is this server's whip_core at least `min` ('1.2' or '1.2.0')? Says so once in the console when it is not.
--- Put the same in your fxmanifest.lua (`whip_requires '1.2'`) and the setup report checks it too.
---@param min string
---@return boolean
function WhipSatellite.requires(min) end

--- Has this server's whip_core the export `name` on this side? For a call newer than the oldest whip you support.
---@param name string
---@return boolean
function WhipSatellite.has(name) end

--- Is version `have` at least `want`? ('1.2' is 1.2.0.)
---@param have string
---@param want string
---@return boolean
function WhipSatellite.versionAtLeast(have, want) end

--- Call a whip_core export safely. Answers what the export answers, or (false, reason) when
--- whip_core is not running or the call threw. An export that waits (Progress, SkillCheck, a
--- database read) answers `false, 'whip_core stopped'` if whip_core stops mid-wait; called
--- straight through `exports.whip_core`, it would never answer. `Whip.core:Name(...)` is the same
--- call with the export's own types.
---@param name string The export's name, e.g. 'AddItem'
---@param ... any
---@return any ...
function WhipSatellite.call(name, ...) end

--- whip_core's exports, each through Whip.call: `Whip.core:AddItem(source, 'cookie', 1)`. The same params and
--- answers as `exports.whip_core:AddItem`, plus `false, why` when whip_core is not running, the call threw, or
--- whip_core stopped while it waited. Use it everywhere outside a handler whip_core runs (your own threads,
--- commands, timers, NUI callbacks); inside one (SecureEvent, SecureCallback, a use handler, a right-click
--- action) call exports.whip_core straight. Not for per-frame code: each call is a thread of its own.
---@type WhipCoreServerExports|WhipCoreClientExports
WhipSatellite.core = {}

--- Wait until whip_core is ready. Only inside a thread. False when it timed out.
---@param timeoutMs? number
---@return boolean ready
function WhipSatellite.ready(timeoutMs) end

--- Is whip_core running and ready right now?
---@return boolean
function WhipSatellite.isReady() end

--- Your Config as a settings page in /whip → Config: each entry's `key` is a path into `config`
--- (default: Config), its value there is the default, and an admin's change is written back into it
--- on every side. docs.html#registersettings has every entry field.
---@param def { label: string, settings?: table[], groups?: { label: string, settings: table[] }[], config?: table }
---@return boolean ok False when def is not a page (printed)
function WhipSatellite.configPage(def) end

--- fn(value, old, path) after a Config value on your page changes on this side: an admin's change, or
--- a saved value written over config.lua's as the page is declared. Hears its own path, anything under
--- it ('Shop' hears 'Shop.radius') and a change to a table it is inside. Call it at file scope.
---@param path string
---@param fn fun(value: any, old: any, path: string)
function WhipSatellite.onConfigChanged(path, fn) end

--- CLIENT. A row of yours on the pause menu's Server Settings page: a choice each player makes for
--- themselves, kept by your resource (get / set). Call it at file scope; it registers inside
--- Whip.register itself. docs.html#whip-playersetting has every field.
---@param def WhipPlayerSettingDef
---@return boolean ok False when def has no key, get or set, or on the server (printed)
function WhipSatellite.playerSetting(def) end

-- ---- The voice system ----

---@class WhipVoiceSystem
---@field resource string The voice resource running: 'whip_voice', or another's name
---@field label string Its name, as a page shows it
---@field features { lines: boolean, speaker: boolean, pickup: boolean, quality: boolean, sounds: 'full'|'basic' } What this one can do (whip_voice/docs/LINES.md)

--- The voice system running now, or false: none. Never name a voice resource; ask this.
---@return WhipVoiceSystem|false
function WhipSatellite.voiceSystem() end

--- Call one of the voice system's exports ('OpenLine', 'CloseLine', 'SetLineSpeaker', 'IsVoiceReady', ...).
--- Answers what the export answers, or false and why: no voice system, or the call threw. A line is yours
--- and goes when your resource stops.
---@param name string
---@param ... any
---@return any answer
---@return string|nil why
function WhipSatellite.voice(name, ...) end

-- ---- Director cards and scenarios (SERVER) ----

---@class WhipDirectorCard   what a card's run is handed: a copy, with methods that call back into whip_core
---@field callId string     Never send it to a player's game
---@field runId number
---@field cardId string
---@field scenario string
---@field name string
---@field rev number
---@field test boolean      In a builder's Test (only with test = 'run')
---@field tag string
---@field player number|nil
---@field starter number|nil
---@field players number[]
---@field trigger table|nil
---@field props table<string, any>
local WhipDirectorCard = {}
---@return any value, string|nil why
function WhipDirectorCard:var(name) end
---@return boolean ok, string|nil why
function WhipDirectorCard:setVar(name, value) end
---@return table|nil state, string|nil why
function WhipDirectorCard:state() end
---@return boolean ok, string|nil why
function WhipDirectorCard:setState(t) end
---@return table|nil where, string|nil why
function WhipDirectorCard:place(id) end
---@return DirectorRunThing|nil made, string|nil why
function WhipDirectorCard:made(id) end
---@return boolean ok, string|nil why
function WhipDirectorCard:record(kind, opts) end
---@return boolean ok, string|nil why
function WhipDirectorCard:objective(text, opts) end
---@return boolean ok, string|nil why
function WhipDirectorCard:clearObjective() end
---@return boolean ok, string|nil why
function WhipDirectorCard:clock(seconds, label) end
---@return boolean ok, string|nil why
function WhipDirectorCard:give(src, item, n, metadata, opts) end
---@return boolean ok, string|nil why
function WhipDirectorCard:pay(src, amount, opts) end
---@return boolean ok, string|nil why
function WhipDirectorCard:charge(src, amount, opts) end
---@param how 'succeeded'|'failed'|'calledOff'
---@return boolean ok, string|nil why
function WhipDirectorCard:finish(how, reason) end
---@return boolean ok, string|nil why
function WhipDirectorCard:log(fmt, ...) end

---@class WhipDirectorCardDef   docs.html#director-cards has every field, with an example
---@field title string
---@field desc? string
---@field help? string
---@field category? string
---@field categoryTitle? string
---@field color? 'blue'|'teal'|'green'|'amber'|'red'|'violet'|'slate'
---@field icon? string
---@field outputs? string[]          Its outcomes, the pins it leaves by
---@field labels? table<string, string>
---@field bad? string[]              Outcomes drawn as going wrong
---@field props? table[]             { key, kind, label, default?, required?, options?, min?, max?, maxLength?, hint?, unit?, lines?, worldKind?, group?, showIf?, button?, add? } (worldKind: a 'world' field's kind of placed thing: 'spot', 'npc', 'vehicle'...; showIf: a bool field's key, shown only while it is on; kind 'entries': a list your Director button `button` (kinds { 'card' }) fills, `add` its words, max 1-12)
---@field testSays? string           What a builder's Test says it would do ("{message}" fills in)
---@field test? 'run'                It runs in a Test too (card.test: sandbox yourself)
---@field instant? boolean           Answers at once, never waits
---@field timeout? number            Seconds before Took Too Long (30)
---@field v? number                  Bumped when its fields change
---@field permission? string
---@field renamed? table             What it was called before: { ['old.type'] = { pins = { old = 'new' } } }
---@field run? fun(card: WhipDirectorCard): string|nil, table|nil   An outcome, or nothing and Whip.answerCard later
---@field event? { name: string, match?: 'player'|'run'|'any', once?: boolean, filter?: fun(card: WhipDirectorCard, event: table): string|nil, table|nil }
---@field fail? { event: string, match?: 'player'|'run'|'any', ends?: 'everyone'|'them', reason?: string, filter?: fun(card: WhipDirectorCard, event: table): boolean|string|nil }   A fail condition of your own: no outputs or run; your event breaks it (true or words from filter: broken)
---@field check? fun(props: table, doc: table): string|nil, 'warning'|nil
---@field onEnd? fun(callId: string, why: string)

--- SERVER. Add (or change) a Director card of yours: type '<your namespace>.<name>'. Sent again whenever
--- whip_core restarts; a refusal is printed with why.
---@param t string
---@param def WhipDirectorCardDef
---@return boolean ok False when it is not a card (printed)
function WhipSatellite.card(t, def) end

--- SERVER. Take one of your cards away (it goes by itself when your resource stops).
---@param t string
---@return boolean ok
---@return string|nil why
function WhipSatellite.removeCard(t) end

--- SERVER. A Director scenario built in code, offered to the server's Director admins (pending until one
--- accepts it, unless they trust your resource), then read-only there.
---@param key string
---@param doc table A scenario document, as the editor saves it (format 1)
function WhipSatellite.scenario(key, doc) end

--- SERVER. A starting point in the Director editor's New list: a builder's copy is theirs.
---@param name string
---@param doc table
function WhipSatellite.template(name, doc) end

--- SERVER. A thread card's answer, later: card.callId, the outcome (one of its outputs), and data
--- (data.source: which of the run's players what follows acts for).
---@param callId string
---@param outcome string
---@param data? table
---@return boolean ok
---@return string|nil why
function WhipSatellite.answerCard(callId, outcome, data) end

---@class WhipDirectorTaskField
---@field key string                  'at' for a point, 'target' for a target
---@field kind 'number'|'slider'|'bool'|'seg'|'select'|'text'|'point'|'world'|'target'
---@field label? string
---@field hint? string
---@field unit? string
---@field default? any
---@field required? boolean
---@field min? number
---@field max? number                 a text field's: its length (64)
---@field step? number                a slider's
---@field options? string[]           seg 2-4, select 1-200; a target's: nearest, trigger, thing, point
---@field worldKind? string           a world field's: npc, vehicle, prop, spot...

---@class WhipDirectorTaskDef
---@field label string
---@field desc? string
---@field group? string               one of the Director's (move, look, fight, act, car, body, wait) or yours
---@field groupTitle? string
---@field kinds ('npc'|'vehicle')[]
---@field timing? 'instant'|'timed'|'until'|'either'   'timed' unless given
---@field sec? number                 a timed step's seconds (3)
---@field giveUp? number              an until step's seconds before it gives up (30)
---@field next? 'done'|'time'         an either step's default
---@field lasting? boolean
---@field once? boolean
---@field standing? boolean           false: a standing NPC passes it over
---@field fields? WhipDirectorTaskField[]   8 at most
---@field run fun(entity: number, args: table, info: { type: string, kind: string, timing: string, ms: number, preview: boolean }): boolean|nil
---@field done? fun(entity: number, args: table): true|'failed'|nil

--- BOTH SIDES (one call in a file both load). Add (or change) a Director task of yours: type
--- '<your namespace>.<name>'. The server sends it as data; each game keeps run/done, which play a step on
--- the game that owns the thing. A refusal is printed with why.
---@param t string
---@param def WhipDirectorTaskDef
---@return boolean ok
function WhipSatellite.task(t, def) end

--- BOTH SIDES. Take one of your tasks away on this side (they go by themselves when your resource stops).
---@param t string
---@return boolean ok
---@return string|nil why
function WhipSatellite.removeTask(t) end

---@alias WhipWeaponGroup 'pistol'|'smg'|'rifle'|'machine gun'|'shotgun'|'sniper'|'heavy'|'thrown'|'stun gun'|'melee'

---@class WhipWeaponDef   one of your own weapons in whip's weapon lists (Whip.weapons)
---@field name string             'WEAPON_' then capitals, digits or _ (64 at most); never one of GTA's own
---@field label string            what the lists show (40 at most)
---@field group WhipWeaponGroup   exactly one of these (spaces as written)
---@field model? string           its world model, a firearm's only: with one it can be a Fixed Weapon

--- BOTH SIDES (one call in a file both load). Your own weapons beside GTA's in every weapon list whip has: the
--- Director's NPC weapons and Hold a Weapon step, its Fixed Weapons, Dungeon Mode, the Object Viewer's Give a weapon.
--- Called again, the new list replaces the old; they go when your resource stops. ONE bad entry refuses the WHOLE
--- list (printed with why). An NPC given one carries the gun itself, never your item: your ammo and reload code is
--- not on it. Through the exports AddWeapons / RemoveWeapons.
---
---     Whip.weapons({
---         { name = 'WEAPON_MY_PUMP', label = 'Pump Shotgun', group = 'shotgun', model = 'w_sg_my_pump' },
---         { name = 'WEAPON_MY_KNIFE', label = 'Knife', group = 'melee' },
---     }, { tag = 'mine' })
---@param list WhipWeaponDef[]
---@param opts? { tag?: string }   tag (16 at most): shown beside each label, "Pump Shotgun (mine)"; your resource's name unless given
---@return boolean ok   false when `list` is not a list (printed); whip_core's own refusal is printed too
function WhipSatellite.weapons(list, opts) end

--- BOTH SIDES. Take all of your weapons away on this side (they go by themselves when your resource stops).
---@return boolean ok
---@return string|nil why
function WhipSatellite.removeWeapons() end

---@class WhipDirectorThing   what a button's press is handed
---@field id string
---@field kind string
---@field label string
---@field model string|number|nil
---@field models string[]|nil       a random vehicle's every model (pressed for one of them: model)
---@field card table|nil            kind 'card' (a card's list): { type, field, entry?, value?, props, world }
---@field coords { x: number, y: number, z: number, heading: number }|nil
---@field scenario string
---@field data table|nil            what you keep on it
---@field entity number|nil         the world builder's copy (never for a button that takes over)
---@field builder boolean           pressed in the world builder
local WhipDirectorThing = {}
--- Keep `data` on the thing (plain data, 4 KB of JSON at most; nil takes it away): an edit of the open scenario.
---@param data table|nil
---@return boolean ok
---@return string|nil why
function WhipDirectorThing:save(data) end
--- A button that takes over: the Director comes back (the world builder on the thing), `data` kept first if given.
---@param data? table
---@return boolean ok
---@return string|nil why
function WhipDirectorThing:back(data) end

---@class WhipDirectorButtonDef
---@field label string               24 at most
---@field kinds string[]             npc, vehicle, prop, spot, groundItem, container, door, route
---@field where? 'both'|'page'|'bubble'
---@field takesOver? boolean         the Director steps aside until thing:back()
---@field icon? string               one of whip's icons by key (as AddAction's)
---@field hint? string               its tooltip
---@field press fun(thing: WhipDirectorThing)

--- CLIENT. Add (or change) a button of yours for a kind of placed thing: on its page in the Director, in the
--- world builder's bubble, or both. id '<your namespace>.<name>'. A refusal is printed with why.
---@param id string
---@param def WhipDirectorButtonDef
---@return boolean ok
function WhipSatellite.directorButton(id, def) end

--- CLIENT. Take one of your buttons away (they go by themselves when your resource stops).
---@param id string
---@return boolean ok
---@return string|nil why
function WhipSatellite.removeDirectorButton(id) end

---@class WhipObjectViewerTarget
---@field kind 'vehicle'|'player'|'npc'|'object'
---@field entity number
---@field netId number|nil
---@field whip boolean        one of whip's own (a saved car, a player) or the game's (a street car, an NPC)
---@field vehicleId number|nil
---@field serverId number|nil
---@field model number|string|nil
---@field name string|nil
---@field coords { x: number, y: number, z: number, heading: number }

---@class WhipObjectViewerOptionDef
---@field label string
---@field group string|nil      the list's heading
---@field tint 'blue'|'teal'|'green'|'amber'|'red'|'violet'|'slate'|nil
---@field hint string|nil       the line under the list (160)
---@field kinds ('vehicle'|'player'|'npc'|'object')[]
---@field whip boolean|nil      true: only whip's own; false: only the game's; nil: both
---@field select fun(target: WhipObjectViewerTarget)  in a thread of its own (it may wait); the list has closed

--- CLIENT. An option of yours in the object viewer's list (the /w dev tool: G on what it has picked out). id
--- '<your namespace>.<name>'; called again, it changes it; it goes when your resource stops. Shown to someone with dev
--- tools on, and to a Dungeon Master in Dungeon Mode, so whatever select does on the server checks for itself
--- (HasDevTools, or the permission it needs).
---@param id string
---@param def WhipObjectViewerOptionDef
---@return boolean ok
function WhipSatellite.objectViewerOption(id, def) end

--- CLIENT. Take one of your object viewer options away.
---@param id string
---@return boolean ok
---@return string|nil why
function WhipSatellite.removeObjectViewerOption(id) end

---@class WhipSkillCheckGameLevel
---@field minMs number       faster than this cannot be honest (it fails as 'too fast')
---@field timeoutMs number   the server gives up after this

---@class WhipSkillCheckGameDef
---@field label string|nil   (server) its name in the Director's Game field
---@field desc string|nil    (server) one line about it
---@field levels table<string, WhipSkillCheckGameLevel>|nil  (server, needed there) its levels by name (lowercase, up to 8)
---@field canStart (fun(source: number|nil): boolean, string|nil)|nil  (either side, optional) may they play it at all: true,
---or false and the words they are told. Server: given the source. Client (a client script's SkillCheck({ game })): no
---source, and it must not wait
---@field run (fun(difficulty: string, token: number): boolean, string|nil)|nil  (client, needed there) play it, in a thread of
---its own (it may wait): passed, and with false 'failed' | 'cancelled' | 'timeout' | 'busy'
---@field cancel fun(token: number)|nil  (client, optional) called off (the server gave up): make run return

--- BOTH SIDES. A skill check game of yours: what SkillCheck's `{ game = id }` (either side's) and the Director's Skill
--- Check card play instead of the ring. id '<yours>.<name>'; one call in a file both sides load (each reads its own
--- fields), or one on each side with the same id. Sent again whenever whip_core restarts; it goes when your resource
--- stops. Someone canStart refuses is told its words, nothing starts, and the check answers false, 'not started'.
---@param id string
---@param def WhipSkillCheckGameDef
---@return boolean ok  false when it is not a game (printed)
function WhipSatellite.skillCheckGame(id, def) end

--- BOTH SIDES. Take one of your skill check games away (a check playing it now ends, cancelled).
---@param id string
---@return boolean ok
function WhipSatellite.removeSkillCheckGame(id) end

--- CLIENT. This game's player index for a server id, or nil when that player is not in this game. Never
--- GetPlayerFromServerId's answer alone: it is -1 on Legacy but 0 on Enhanced for a player this game lacks, and 0 can
--- be a real player (often you).
---@param serverId number
---@return number|nil
function WhipSatellite.playerIndex(serverId) end

---@class WhipPadScreen
local WhipPadScreen = {}
--- Take your NUI focus (no cursor on a pad) and start reading the pad. Answers whether a pad is in the
--- player's hands, for your page's hints.
---@return boolean pad
function WhipPadScreen:open() end
--- Give the focus back and stop reading.
function WhipPadScreen:close() end
--- A text field on your page has the keyboard: the pad is left alone and the game gets no input.
---@param on boolean
function WhipPadScreen:typing(on) end
--- Another screen of yours has the pad: left alone, your focus untouched. false: yours again. Not needed for whip's
--- OpenKeyboard: while it is up the screen leaves the pad to it by itself.
---@param on boolean
function WhipPadScreen:pause(on) end
---@return boolean
function WhipPadScreen:isPad() end

--- CLIENT. A controller on your NUI screen: reads the pad while it is open and sends your page
--- { action = 'pad', cmd, down, rep } per press and { action = 'padDevice', pad } on a swap between pad
--- and mouse; owns your NUI focus; holds the pad's world actions off; leaves whip's LB combos alone.
--- Call it once at file scope. docs.html#whip-padscreen has every field.
---@param def? { buttons?: ('up'|'down'|'left'|'right'|'a'|'b'|'x'|'y'|'lb'|'rb'|'menu')[], stick?: boolean, releases?: table<string, boolean>, keepInput?: 'pad'|'always', block?: table|false, onButton?: fun(cmd: string, down: boolean, rep?: integer), onDevice?: fun(pad: boolean), onFrame?: fun() }
---@return WhipPadScreen
function WhipSatellite.padScreen(def) end

-- ============================================
-- WhipCost (lib/cost.lua): client_script '@whip_core/lib/cost.lua'
-- ============================================

--- Times sections of your client loops for /whipcost, and the memory each makes. Off unless /whipcost is running.
---@class WhipCostLib
---@field on boolean True while /whipcost runs
local WhipCostLib = {}

--- The start of a section: a reading for stop(), or nil while nothing is timing.
---@return number|nil
function WhipCostLib.start() end

--- The end of a section. Never a Wait() in between: a run that waited a frame is left out.
---@param name string Its line in the table, as 'area: what'
---@param started number|nil What start() returned
function WhipCostLib.stop(name, started) end

--- CLIENT. The end of the timing in this resource: its totals handed to whip_core. /whipcost's stop calls it; your
--- resource never needs to.
function WhipCostLib.finish() end

---@type WhipSatellite
Whip = WhipSatellite

---@type WhipCostLib
WhipCost = WhipCostLib
