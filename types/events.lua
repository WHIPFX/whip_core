---@meta
-- ============================================
-- whip_core — the event catalogue
-- ============================================
--
-- Every LOCAL event whip fires for other resources, with its payload's type, so a handler can be
-- annotated:
--
--     AddEventHandler('whip_core:item:added', function(e) ---@param e WhipEvtItemChanged
--         print(e.source, e.item, e.amount, e.count)
--     end)
--
-- THE RULE: whip_core:<domain>:<pastTense>, with ONE table payload. Names with
-- client: or server: in them are whip's own network messages, not events for you.
--
-- S = fired on the server, C = fired on the client.

-- ============================================
-- Readiness
-- ============================================

--- S+C  whip_core:onReady — whip_core is ready for registrations. Prefer Whip.register
--- (lib/satellite.lua), which filters this for you.
---@class WhipEvtReady
---@field reason 'coreStarted'|'resourceStarted' coreStarted: whip_core has just (re)started and remembers nothing
---@field resources string[]|nil resourceStarted: the resources that just started

-- ============================================
-- Player & character
-- ============================================

--- S  whip_core:player:loaded — character fully loaded.
--- C  whip_core:player:loaded — the character is in the world and the picture is back. New.
--- The same table on both sides.
---@class WhipEvtPlayerLoaded
---@field source number
---@field charId number
---@field name string The character's full name
---@field newCharacter boolean true on a brand-new character's first load
---@field player WhipPlayerData The data sheet
---@field phantom boolean|nil true for whip_test's load-test players (/testload announce=1): no character in the world

--- S  whip_core:player:logout — the character is leaving.
---@class WhipEvtPlayerLogout
---@field source number
---@field charId number
---@field player WhipPlayerData
---@field why 'logout'|'disconnect'

--- C  whip_core:player:logout — the local player is logging out to character select. New.
---@class WhipEvtPlayerLogoutClient
---@field charId number|nil

--- S  whip_core:character:renamed — an admin renamed a character (Player Manager; server/character.lua
--- Character.rename). THE NAME ONLY: the charId, and everything kept by it, stay. Online or not. New (1 Nov 2026).
---@class WhipEvtCharacterRenamed
---@field charId number
---@field source number|nil Their server id when they are in, else nil
---@field firstName string
---@field lastName string
---@field name string The new full name
---@field oldName string
---@field by string|nil Who renamed them

--- C  whip_core:player:renamed — the local player's character was renamed; PlayerData's names already changed. New.
---@class WhipEvtPlayerRenamedClient
---@field charId number
---@field firstName string
---@field lastName string
---@field name string

--- C  whip_core:player:spawned — put into the world (after every load, and again when the
--- appearance creator closes).
---@class WhipEvtPlayerSpawned

--- C  whip_core:player:died — the local player died. New.
---@class WhipEvtPlayerDied
---@field reconnected boolean They loaded in already dead
---@field respawnRefused boolean The same death again: the server refused a respawn (a 'revived' was already announced)

--- S  whip_core:player:died — the server accepted a player's death. New.
---@class WhipEvtPlayerDiedServer
---@field source number
---@field charId number
---@field killer number|nil The killer's server id, when the server saw a player do it (a car's driver counts)
---@field reported string|nil The victim's own game's description of the killing blow — display only

--- C  whip_core:player:revived — alive again. New.
---@class WhipEvtPlayerRevived
---@field how 'revived'|'respawned' Where they lay, or at a hospital

--- C  whip_core:death:screenChanged — what the death screen shows now, for a resource that draws its own
--- (Config.DeathScreen = false). One of: { state = 'count', left, total } · { state = 'ready', progress, key } ·
--- { state = 'held', label } (a HoldRespawn) · { state = 'off' } · { hidden } (the hide key). New.
---@class WhipEvtDeathScreenChanged
---@field state 'count'|'ready'|'held'|'off'|nil
---@field left number|nil Seconds until a respawn is offered
---@field total number|nil The whole countdown, in seconds
---@field progress number|nil 0-100: how far E (or A) has been held
---@field key string|nil The Interact key's name on a keyboard
---@field label string|nil A hold's words
---@field hidden boolean|nil The player hid the screen (H / Y)

--- S  whip_core:player:revived — a dead player is alive again. New.
---@class WhipEvtPlayerRevivedServer
---@field source number
---@field charId number
---@field how 'revived'|'respawned' Where they lay, or at a hospital
---@field reason string 'revive', 'respawn', 'revive:admin' or 'revive:self'

--- C  whip_core:appearance:modelChanged — the player's ped was rebuilt with a new model (login,
--- /charedit). The new ped starts with the game's default walk and face. New, no fields.
---@class WhipEvtAppearanceModelChanged

--- C  whip_core:voice:rangeChanged — the player pressed the voice-range key (Z): the HUD's bar moved.
--- For a voice resource, which turns the level into metres. New.
---@class WhipEvtVoiceRangeChanged
---@field index number 1 whisper, 2 normal, 3 shout
---@field name string 'Whisper'|'Normal'|'Shout'
---@field level number The bar's percentage: 20, 50 or 100

--- C  whip_core:voice:systemChanged — a voice resource started or stopped being the voice system
--- (server/voice_system.lua). All nil when none runs. New.
---@class WhipEvtVoiceSystemChanged
---@field resource string|nil 'whip_voice', or another voice resource's name
---@field label string|nil
---@field features table|nil As GetVoiceSystem's

--- S  whip_core:character:created / whip_core:character:deleted
---   Any server resource can fire these: before removing anything for good on `deleted`, ask
---   exports.whip_core:IsCharacterDeleted(charId). whip's own release does not listen to the event.
---@class WhipEvtCharacter
---@field source number
---@field charId number

-- ============================================
-- Items & money
-- ============================================

--- C  whip_core:hotbar:slotUsed — the player used a hotbar slot (a number key, or the pad's hotkeys wheel), just
--- before the server is asked to use it: what must not stay up through an item's use puts itself away (the camera
--- item's viewfinder). New.
---@class WhipEvtHotbarSlotUsed
---@field slot number 1-5

--- S  whip_core:inventory:changed — { source }: something in a player's pockets changed, any way —
--- a move between their own slots too, which the two below never hear. Once per change.
---
--- S  whip_core:item:added / whip_core:item:removed — a player carries more / less of an item,
--- by any route.
---@class WhipEvtItemChanged
---@field source number
---@field item string
---@field amount number How many arrived or left
---@field count number What they carry now
---@field reason string|nil The caller's own words ('rental refund'), when an export was given one
---@field by string|nil 'by <resource>' — who asked, when an export made the change

--- S  whip_core:item:used
---@class WhipEvtItemUsed
---@field source number
---@field item string
---@field slot WhipInventorySlot The slot's data
---@field addr WhipStoreAddr

--- S  whip_core:item:given — one player gave another an item.
---@class WhipEvtItemGiven
---@field source number
---@field target number
---@field item string
---@field amount number

--- S  whip_core:bank:accountChanged — an account changed with no money moving.
---@class WhipEvtBankAccountChanged
---@field accountId number
---@field what string 'label' | 'type' | 'owner' | 'frozen' | 'main' | 'closed' | 'access'

--- S  whip_core:bank:balanceChanged — any deposit, withdrawal or transfer.
---@class WhipEvtBankChanged
---@field type string 'deposit' | 'withdraw' | 'transfer' | ...
---@field accountId number
---@field amount number
---@field actorCharId number|nil
---@field newBalance number|nil
---@field message string|nil
---@field ownerCharId number|nil      deposit: whose account it is
---@field accountType string|nil      deposit: 'personal' | 'savings' | 'shared' | 'business'
---@field label string|nil            deposit: the account's name
---@field fromAccountId number|nil    transfer (and fromBalance, toBalance)
---@field toAccountId number|nil      transfer
---@field fromOwnerCharId number|nil  transfer: also fromAccountType, fromLabel
---@field toOwnerCharId number|nil    transfer: also toAccountType, toLabel

-- ============================================
-- Shops
-- ============================================

--- S  whip_core:shop:opened / whip_core:shop:closed
---@class WhipEvtShopSession
---@field shopId number
---@field source number
---@field charId number

--- S  whip_core:shop:purchased
---@class WhipEvtShopPurchased
---@field shopId number
---@field charId number
---@field source number
---@field items table[]
---@field total number
---@field paymentMethod string
---@field mode string

--- S  whip_core:shop:created / whip_core:shop:updated
---@class WhipEvtShopDef
---@field shopId number
---@field shop table The shop's definition

--- S  whip_core:shop:deleted
---@class WhipEvtShopDeleted
---@field shopId number

--- S  whip_core:shop:priceChanged
---@class WhipEvtShopPrice
---@field containerId number
---@field item string The item priced (one price per item)
---@field slot number|nil The shelf slot it was priced from, when it was (the stock view)
---@field price number
---@field forSale boolean

-- ============================================
-- Time, weather, zones, UI
-- ============================================

--- S  whip_core:time:changed
---@class WhipEvtTimeChanged
---@field hour number
---@field minute number

--- S  whip_core:time:freezeChanged — frozen OR unfrozen.
---@class WhipEvtTimeFreeze
---@field frozen boolean

--- S  whip_core:weather:changed
---@class WhipEvtWeatherChanged
---@field weather string

--- C  whip_core:weather:layerChanged — a local time/weather layer set, or removed (layer nil).
---@class WhipEvtWeatherLayer
---@field name string
---@field layer table|nil

--- C  whip_core:zone:entered / whip_core:zone:exited: the local player
---@class WhipEvtZone
---@field zoneId string
---@field key string|nil     the zone's own key, for matching on
---@field label string|nil
---@field group string|nil
---@alias WhipEvtZoneClient WhipEvtZone

--- S  whip_core:zone:entered / whip_core:zone:exited: a player, in a zone whose tracking is on (trackPlayers zones)
---@class WhipEvtZoneServer
---@field zoneId string
---@field key string|nil
---@field source number
---@field dropped boolean|nil  exited: they left the server
---@field removed boolean|nil  exited: the zone was removed

--- C  whip_core:ui:stateChanged — a screen or dialog opened, or everything closed: the
---   IsAnyScreenOpen question, so a progress bar alone does not fire it.
---@class WhipEvtUiState
---@field open boolean

--- C  whip_core:ui:cleanScreen — the screen went clean for a recording (the Camera Creator playing in
---   game: client/clean_screen.lua), or came back, or what it hides changed. Put your own UI away while `on`; your
---   things in the world (a DUI drawn over a place) only while `world` (the camera item keeps the world's things).
---@class WhipEvtUiClean
---@field on boolean
---@field world boolean

--- C  whip_core:hands:blocked — a resource blocked the player's hands (BlockHands, this game's or the server's). Put
---   away what you hold that it covers (every block covers weapons). whip_core:hands:unblocked {} when none is left.
---@class WhipEvtHandsBlocked
---@field label string the words the player is shown
---@field only 'weapons'|nil nil: everything (the freeHands moment runs too)

--- C  whip_core:pad:deviceChanged — the player went from keyboard to pad or back, once the answer has stayed put for
---   400 ms: the moment whip's own button hints swap. Swap yours here instead of asking IsControllerActive on a timer
---   (ask it once at start: this fires on changes, and once as whip_core starts).
---@class WhipEvtPadDevice
---@field pad boolean a pad is in the player's hands

--- C  whip_core:keyboard:opened / whip_core:keyboard:closed — whip's on-screen keyboard (OpenKeyboard) came up, or
---   went (typed, left, or replaced by another). The pad is the keyboard's between them: a screen reading the pad
---   itself leaves it alone (Whip.padScreen does by itself). Each opened gets one closed.
---@class WhipEvtKeyboard
---@field id number which keyboard (opened and closed match)
---@field owner string|nil opened: the resource that asked

--- C  whip_core:nui:capsDetected — whip_core's page has said what the game's browser can do
---   (FiveM's Chromium 103 or 144; html/js/caps.js), or it changed. The same table as GetNuiCaps.
---@class WhipEvtNuiCaps
---@field chrome number the browser's Chrome version (0 when it does not say)
---@field has boolean :has()
---@field colorMix boolean color-mix()
---@field relativeColor boolean relative colours
---@field textBalance boolean text-wrap: balance / pretty
---@field startingStyle boolean @starting-style + transition-behavior: allow-discrete
---@field heightAuto boolean interpolate-size: allow-keywords
---@field anchor boolean CSS anchor positioning
---@field fieldSizing boolean field-sizing: content
---@field viewTransitions boolean document.startViewTransition
---@field schedulerYield boolean scheduler.yield()
---@field webgpu boolean navigator.gpu is there
---@field zoomScreenPx boolean getBoundingClientRect inside CSS zoom is in screen pixels (false on Chromium 103)
---@field gameView boolean FiveM's new game view (CfxGameViewRenderer, gl.CFX_BIND_GAME_VIEW)

-- ============================================
-- Properties
-- ============================================

--- S  whip_core:property:ownerChanged — a property was given to someone, or made unowned. New.
---@class WhipEvtPropertyOwner
---@field propertyId number
---@field ownerCharId number|nil nil when it is now unowned
---@field previousOwnerCharId number|nil
---@field by number|nil The charId who made the change, when there was one

--- S  whip_core:property:keyGranted / whip_core:property:keyRevoked. New.
---@class WhipEvtPropertyKey
---@field propertyId number
---@field charId number The keyholder
---@field by number|nil Who gave it (keyGranted only)

--- C  whip_core:property:entered / whip_core:property:exited — the local player walked into, or
--- out of, a property's space. New.
---@class WhipEvtPropertyArea
---@field propertyId number
---@field name string

--- C  whip_core:property:furnished / whip_core:property:unfurnished — a property's furniture went up on
--- this client (count = pieces), or was taken away again. New.
---@class WhipEvtPropertyFurnished
---@field propertyId number
---@field interiorId number|nil the interior copy it was made on
---@field count number|nil furnished only

--- C  whip_core:property:furnishStateChanged — its GetInteriorFurnishState answer changed. New.
---@class WhipEvtPropertyFurnishState
---@field propertyId number
---@field interiorId number|nil the copy whip last found ready; nil before that
---@field state 'pending'|'done'|'none'|'idle'

-- ============================================
-- Jobs
-- ============================================

--- S  whip_core:job:created / :updated / :deleted, :hired, :fired, :roleChanged, :clockedOn,
--- :clockedOff. Each carries jobId and key; the ones about a person carry charId and source (nil
--- while offline). created adds name; updated adds name, icon, ownerCharId, oldOwnerCharId; hired
--- adds roleId, role, by; roleChanged adds roleId, role, oldRoleId.
---@class WhipEvtJob
---@field jobId number
---@field key string|nil
---@field charId number|nil
---@field source number|nil
---@field roleId number|nil
---@field role string|nil The role's name
---@field oldRoleId number|nil
---@field by number|nil The charId who hired them
---@field name string|nil
---@field icon string|nil
---@field ownerCharId number|nil
---@field oldOwnerCharId number|nil

--- C  whip_core:job:clockedOn / :clockedOff — the local player went on or off duty.
---@class WhipEvtJobDuty
---@field jobId number
---@field key string|nil

--- C  whip_core:job:listChanged — the local player's job list changed (hired, fired, promoted, renamed).
---@class WhipEvtJobList
---@field jobs table<number, WhipPlayerJobInfo> What GetPlayerJobs answers

-- ============================================
-- NPCs (server/npcs.lua)
-- ============================================
--
-- S: whip_core:npc:spawned { npcId, tag, owner, netId, model, coords }
--    whip_core:npc:despawned { npcId, tag, owner, reason } -- 'removed' | 'stopped' | 'released' | 'lost' | 'corpse'
--    whip_core:npc:damaged { npcId, tag, owner, amount, health, armour, attacker, group } -- attacker = server id | nil; group = its group's name | nil
--    whip_core:npc:killed { npcId, tag, owner, killer, weapon, coords } -- killer = server id | nil
-- A car's driver is the attacker / killer of a run-over. Any server resource can fire these: never
-- pay out on the event alone, ask GetNpc (its killer, killedAt and weapon are the server's reading).

-- ============================================
-- Held props (server/held_props.lua)
-- ============================================
--
-- S: whip_core:heldProps:lost { source, tag, reason, by } -- the props in a player's hand (`tag`: whip's own
--    'emote' | 'bar' | 'give' | 'take' | 'camera', or a resource's '<resource>:<tag>' from HoldProps) left it without their
--    owner asking. reason 'replaced': a set of another tag took the hand (`by`: an emote's cup, a bar's wrench, an
--    item handed to them); 'world': the player was moved to another routing bucket (a held prop cannot follow).
--    A resource whose prop it was hears it is gone (whip_fuel: the nozzle drops, or goes back on its pump). Not
--    fired for a drop the owner asked for, a new set of the same tag, a logout or a disconnect.

-- ============================================
-- Doors (server/doors.lua)
-- ============================================
--
-- S: whip_core:door:lockChanged { doorId, locked, source, cause } -- only when it really changed;
--    cause 'press' | 'lockpick' | 'autolock' | 'code' | 'released' (a hold ended) | the caller's own
--    whip_core:door:denied { doorId, source, reason } -- a press refused; the reason is the player's own
-- Any server resource can fire these: ask IsDoorLocked for the truth, not the event.

-- ============================================
-- Containers (server/containers.lua)
-- ============================================
--
-- S: whip_core:container:opened { containerId, source, charId } -- the server opened it on their screen
--    (E, OpenStore, a placed stash point); their game may still decline it. Any server resource can
--    fire it: to know they have it open now, ask Stores (StoreRead / their view), not the event.

-- ============================================
-- Permissions (server/permissions.lua)
-- ============================================
--
-- S: whip_core:permission:changed { userId, permission, granted } -- an account was given (granted
--    true) or lost a permission. To know whether someone has one, ask HasPermission, not the event.
-- C: whip_core:permission:changed { permission, granted } -- (local) on the game of every player on that account.
--    (whip_core:client:permissionChanged is whip's own network message that brings it: not for you.)
--
-- C: whip_core:ask:cancelled { token } -- (local) whip_core gave up on a question it asked this player (its timeout,
--    a run's end, a logout): a resource showing it on its own screen (RegisterAskChannel) takes that down. New.

-- ============================================
-- Player flags (server/player_flags.lua)
-- ============================================
--
-- S: whip_core:flag:changed { source, charId, name, value, was } -- a character's flag was set (value)
--    or cleared (value nil). To know a flag, ask GetPlayerFlag, not the event.

-- ============================================
-- Director runs and scenarios (server/director/main.lua; the Director API)
-- ============================================
--
-- Sent AFTER the Director's scheduler pass (never from inside it), and NEVER for a builder's Test.
-- `run` is a DirectorRunView (types/director.lua): a copy, with the run's `tag` to give anything you
-- make for it (it goes when the run ends).
-- S: whip_core:run:started { run, startedBy = { mode, by } } -- mode 'interaction' | 'press' | 'area' |
--    'item' | 'timer' | 'script' (by = the resource that asked) | 'hand' (an admin, the editor) | 'enabled' (When
--    it's switched on: started as it is switched on, and again after each run, with NOBODY in it; its job begins as
--    its first player joins: run:playerJoined, run.begunAt)
--    whip_core:run:ended { run, outcome, reason, vars, payout, faultCard, stopping } -- outcome
--    'succeeded' | 'failed' | 'calledOff' (a Call Off card) | 'aborted' (an admin, the last player
--    leaving, whip_core stopping) | 'faulted'; faultCard = { id, type } | nil; stopping = whip_core is
--    stopping
--    whip_core:run:playerLeft { run, source, charId, why, by, runEnds } -- run is without them; runEnds =
--    it ends with them (sent before its run:ended); by = the resource that took them out, if one did
--    whip_core:run:playerJoined { run, source, charId, by } -- AddPlayerToScenarioRun (by = the resource)
--    whip_core:run:signalled { run, name, data = { value }, source } -- a Send Signal card ('alarm')
--    whip_core:run:thingMade { run, world, kind, label, netId, npcId, vehicleId, containerId, groundId, doorId,
--    model, data } -- the run made something for one of its placed things (a car, an NPC, a container...); data =
--    { [resource] = what it keeps on the thing } (Director buttons: client Whip.directorButton), yours at
--    data[GetCurrentResourceName()]. model: a car's, as made (a Vehicle pool's is one of its models).
--    netId may be nil for a moment after a car is made. A builder's Test sends it
--    too (run.test). The Always present layer sends it as the scenario switches on (or a Test starts), with no
--    run: { scenario, standing = true, test?, world, kind, ... }.
--    whip_core:scenario:switchedOn { scenario, name, rev, replaced, by } -- replaced = another revision
--    of it was on; by = { source, name } (a player) | { resource } (SwitchScenario) | nil (the server)
--    whip_core:scenario:switchedOff { scenario, name, rev, why, by }
-- C (this player's own runs, from client/director_runs.lua; GetPlayerScenarioRuns): whip_core:run:joined /
--    :updated { runId, scenario, name, objective, countdown }, :left { runId, scenario, name, why },
--    :ended { runId, scenario, name, outcome, payout }
-- C (local, the world builder, client/furnish_builder.lua): whip_core:director:builderCopy { id, kind, model, entity,
--    data, driven } -- the builder made its copy of one of the scenario's cars, NPCs or props that a resource keeps
--    something on (data = { [resource] = what it keeps }, yours at data[GetCurrentResourceName()]): dress it as a run
--    makes it (a car's Whiplash look). This game's own entity, made again whenever its model or that data changes.
--    Also a take's copies (client/director_takes.lua: recording one, Watch it): driven = true on the car the player
--    drives while recording (what changes how it drives counts too); the copy goes when the recording ends.
-- C (local, client/take_copies.lua): whip_core:vehicle:copied { entity, of } -- this game made its own copy of a
--    networked car `of` (Experimental recorded drives sync: a take played on a copy, the real one hidden here): draw on
--    the copy what you draw on cars from their data (whip_autos: the stance, the engine's sound). Read `of`'s data
--    (GetVehicleData({ entity = of }, key)). The copy goes when the take is over.
-- Anything made with tag = run.tag (a blip, a point, an NPC ...), by any resource, goes when the run
-- ends; later creates under it are refused. Any server resource can fire the server events too: check
-- GetInvokingResource() == 'whip_core' in your handler before paying anything out on one (an ended run
-- is no longer there for GetScenarioRun to confirm).

--- S  whip_core:lore:changed — a lore character was made, changed or retired (server/director/lore.lua).
--- A phone resource gives each one a number on it. New.
---@class WhipEvtLoreChanged
---@field key string
---@field character table|nil  GetLoreCharacter's answer: { key, name, model, bankName, payName, notes, retired, accountId }
---@field retired boolean      retired (out of the pickers, records kept), or gone

-- ============================================
-- Vehicles (these already followed the rule)
-- ============================================
--
-- S: whip_core:vehicle:entered / :exited { vehicleId, plate, source, seat } (+ previousSeat on
--    entered: the seat moved from inside the same car; + left = 'logout' | 'dropped' on exited when
--    they left the car by leaving the game, nil when they got out), :lockChanged
--    { vehicleId, plate, locked, source }, :lockpicked, :registered,
--    :dataChanged, :spawned, :despawned, :created, :deleted, :ownerChanged,
--    :released, :claimed { vehicleId, from, ownerCharId } (ClaimVehicle: `from` is the session car it
--    was), :plateChanged { vehicleId, from, to }. C: whip_core:vehicle:entered / :exited { vehicleId,
--    entity, plate, seat }.
-- See docs.html → Server Events for each payload.

-- Refuelling is whip_fuel's: its pump nozzles announce whip_fuel:nozzleTaken / :nozzleInserted / :nozzleRemoved /
-- :nozzleDropped / :nozzlePickedUp / :nozzleTorn / :nozzleReturned (whip_fuel/server/pumps.lua says what each
-- carries). whip_core has no fuel of its own.

-- ============================================
-- Developer tools
-- ============================================
--
-- C: whip_core:cost:started { seconds } / :stopped {} — /whipcost timing every WhipCost section
--    (lib/cost.lua); a resource that loads that file answers :stopped with
--    whip_core:cost:reported { resource, ms, runs, waited, kb, kbRuns, memory } (milliseconds summed, runs counted
--    and runs that waited a frame, KB made and the runs it was read for, per section name; memory = { kb, seconds,
--    gc, capped }: what the whole resource made, its collector paused meanwhile). A satellite that loads only
--    lib/satellite.lua answers with its memory alone (empty ms and runs). Nothing to listen for: loading either does it.
-- C: whip_core:devtools:modeChanged { on } — this player's developer mode went on or off (their /w switch, or the server
--    taking dev tools away). It starts off at every join and whip_core start: exports.whip_core:HasDevTools() says
--    where it is now. For what a client shows only to developers (whip_phone's developer apps); anything the server
--    does for them, the server checks again (its HasDevTools(source)).
