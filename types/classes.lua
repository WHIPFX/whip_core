---@meta
-- ============================================
-- whip_core — LuaLS Type Definitions
-- Shared class/structure definitions used by
-- both server.lua and client.lua annotations.
-- This file contains NO runtime code.
-- ============================================

-- ============================================
-- Player
-- ============================================

-- TWO PLAYER TYPES, BECAUSE THERE ARE TWO PLAYERS.
--
-- WhipPlayer is the LIVE OBJECT, and it exists only inside whip_core. It has methods.
--
-- WhipPlayerData is what every GetPlayer* EXPORT hands back — WhipPlayer:serialize(), a plain
-- table. FiveM copies values across a resource boundary and a metatable does not survive that
-- copy, so a satellite cannot call a method on the result.
--
-- THE SHEET IS NOT A SUBSET. It carries `cash` (computed by getCash()), and it drops the four
-- identifiers — which have their own export, because this same sheet goes to the client on
-- playerLoaded.

--- A player as plain data. What every GetPlayer* export returns; no methods.
---@class WhipPlayerData
---@field source number Server ID of the player
---@field session number This character load's number — pass it to IsSessionCurrent after a wait
---@field userId number Unique user account ID (persists across characters)
---@field charId number Active character ID
---@field firstName string Character first name
---@field lastName string Character last name
---@field fullName string firstName .. ' ' .. lastName
---@field dateOfBirth string Date of birth string
---@field gender 'male'|'female'
---@field cash number Cash on hand — computed, and the one field the live object exposes only through a method
---@field position { x: number, y: number, z: number, w: number } World position + heading when the sheet was made (read live)
---@field health number Ped health (0-200)
---@field armour number Ped armour (0-100)
---@field isDead boolean Whether the character is dead
---@field metadata table<string, any> Arbitrary persistent metadata

--- The LIVE player object, with methods. Exists inside whip_core only — see the note above.
---@class WhipPlayer
---@field source number Server ID of the player
---@field userId number Unique user account ID (persists across characters)
---@field charId number Active character ID
---@field firstName string Character first name
---@field lastName string Character last name
---@field fullName string firstName .. ' ' .. lastName
---@field dateOfBirth string Date of birth string
---@field gender 'male'|'female'
---@field position vector4 Last known position + heading — call :getCoords() for the current one
---@field health number Ped health (0-200)
---@field armour number Ped armour (0-100)
---@field isDead boolean Whether the character is dead
---@field metadata table<string, any> Arbitrary persistent metadata
---@field license string Rockstar license identifier
---@field steam string|nil Steam hex identifier
---@field discord string|nil Discord identifier
---@field fivem string|nil FiveM identifier
local WhipPlayer = {}

---@param key? string Specific key, or nil to get entire metadata table
---@return any
function WhipPlayer:getMetadata(key) end

---@param key string Metadata key
---@param value any Value to set
---@return boolean ok
---@return string|nil err
function WhipPlayer:setMetadata(key, value) end

---@return vector4
function WhipPlayer:getCoords() end

--- Save character data (position, vitals, metadata) to DB.
---@param teardown? boolean The last save of this character's session (disconnect, logout)
---@param seatNoted? boolean A teardown save after the first: the seat is not noted again
---@return boolean ok
function WhipPlayer:save(teardown, seatNoted) end

---@param reason string Kick reason shown to player
function WhipPlayer:kick(reason) end

--- Log the player out (return to character select).
---@param invoker? string The resource that asked (LogoutPlayer passes it)
function WhipPlayer:logout(invoker) end

---@return table Serialized player data for client
function WhipPlayer:serialize() end

---@return number Total cash in inventory
function WhipPlayer:getCash() end

---@param amount number Amount to add
---@param why? string Reason shown in the activity log, e.g. 'ATM withdrawal'
---@param withNext? boolean|'quiet' whip_core only: saved with the bank write that follows
---@return boolean success
---@return string|nil err Why not
function WhipPlayer:addCash(amount, why, withNext) end

---@param amount number Amount to remove
---@param why? string Reason shown in the activity log, e.g. 'ATM deposit'
---@param withNext? boolean|'quiet' whip_core only: saved with the bank write that follows
---@return boolean success
---@return string|nil err Why not
function WhipPlayer:removeCash(amount, why, withNext) end

-- ============================================
-- Inventory
-- ============================================

---@class WhipInventorySlot
---@field item string Item key (matches Config.Items key)
---@field amount number Stack count
---@field metadata table|nil Optional metadata JSON

--- One table per entry in PlayerContainers. A server that adds a pocket adds a field
--- here.
---@class WhipInventoryCache
---@field player table<number, WhipInventorySlot> Player container slots (1-30)
---@field accessory table<number, WhipInventorySlot> Accessory container slots (1-5)

--- What FindItem / FindAllItems return: the item (a copy) and where it is.
---@class WhipFoundItem
---@field item string Item key
---@field amount number Stack count
---@field metadata table|nil A copy
---@field addr WhipStoreAddr Where it is — { kind = 'player', id = source, sub = pocket, slot }

-- ============================================
-- Item Definition
-- ============================================

---@class WhipItemDef
---@field name string Display name
---@field desc string|nil Description text
---@field weight number Weight per unit (kg)
---@field type string|nil Category label (e.g. 'consumable', 'weapon')
---@field stack boolean|nil Whether the item can stack
---@field maxStack number|nil Maximum stack size
---@field image string|nil Icon path inside the registering resource; default 'html/img/items/<key>.png' (needs `files { 'html/img/items/*.png' }` in its fxmanifest)
---@field usable boolean|nil Whether the item can be used (right-click)
---@field cooldown number|nil Use cooldown in seconds
---@field prop string|nil GTA prop model name for ground/hand
---@field grab '1h'|'2h'|nil How it is picked up off the ground: one hand (the default) or both (a rifle, a duffel bag); also on /whip → Items
---@field playerWalk boolean|nil Held out to give or throw, the player keeps their own walk instead of the give walk (default false); also on /whip → Items and in the hand position editor
---@field metaFields table[]|nil Array of { key, label, format?, value? } for tooltip display; `value` is shown when the item's metadata has no `key`
---@field fuelCapacity number|nil Makes it a fuel can (read by whip_fuel): how much of a car's tank (100) a full one holds; metadata `fuel` is how full it is, 0-100
---@field defaultAction string|nil Context menu default action key
---@field contextOptions table[]|nil Right-click options, { action, label, order?, when?, whyNot?, require?, anywhere? }: at the top of the menu under Use, lowest `order` first (none: as listed, after those with one); Give, Place, Split and Destroy below. `when` tests the item's metadata (a test's `default` stands in for a missing field), `whyNot` is said when it fails, `require` tests the player (AddAction's words), `anywhere = true` offers it in a boot, stash or bag too (the handler gets that store's address): server/item_options.lua
---@field groundOptions table[]|nil On the ground, after Pick up, { action, label, icon? } (3 at most): `action` is one of the item's own options (contextOptions or defaultAction). Chosen, the item is picked up as Pick up does and, once it is in the pockets, that option runs on the slot it landed in. The prompt says label then the item's name ("Equip Pump Shotgun"); icon is a glyph name: server/item_options.lua
---@field images table[]|nil Pictures for states, { when?, image }: the first whose when passes is drawn, else its own. `image` is a path in the item's resource; {field} fills from metadata, {make} is a car's maker. An admin can change them on /whip → Items
---@field pictureFields table[]|nil Metadata an admin can show a picture by on /whip → Items: { key, label?, type? = 'bool' | 'number' | 'text' }
---@field settings table[]|nil Settings of this item's own, changed on /whip → Items: settings-page entries { key, type = 'int'|'number'|'bool'|'string'|'enum', default, label, min?, max?, step?, unit?, maxLen?, nullable?, options?, help? }, 20 at most; read with GetItemSetting (server/item_settings.lua)

-- ============================================
-- Bank
-- ============================================

---@class WhipBankAccount
---@field accountId number Unique account ID
---@field accountNumber string Display account number (e.g. 'WB-123456')
---@field label string Account label
---@field type 'personal'|'savings'|'business'|'shared' Account type
---@field ownerCharId number|nil Character who owns the account (nil for a job's account)
---@field jobId number|nil Associated job ID (for job accounts)
---@field balance number Current balance
---@field isDefault boolean Whether this is the character's default account
---@field frozen boolean Whether the account is frozen
---@field createdAt number Epoch seconds
---@field closedAt number|nil Epoch seconds if closed
---@field role 'owner'|'manager'|'withdraw'|'deposit'|'view'|nil Only from GetCharacterBankAccounts: the character's role on it

--- One row of GetBankTransactions. A transaction names BOTH sides, so the same row appears in both
--- accounts' histories: compare `fromAccountId` with your account to tell money out from money in.
---@class WhipBankTransaction
---@field txId number Unique transaction ID
---@field fromAccountId number|nil Account the money left (nil for a deposit)
---@field toAccountId number|nil Account the money went to (nil for a withdrawal)
---@field type 'deposit'|'withdraw'|'transfer'|'payment' Transaction type
---@field amount number Transaction amount
---@field fromBalance number|nil The from-account's balance after this transaction
---@field toBalance number|nil The to-account's balance after this transaction
---@field actorCharId number|nil Character who made it
---@field message string|nil Description/reason
---@field createdAt number Epoch seconds

--- One row of GetBankAccessList (for the account you asked about).
---@class WhipBankAccess
---@field charId number
---@field role 'owner'|'manager'|'withdraw'|'deposit'|'view' Permission role
---@field grantedAt number Epoch seconds
---@field grantedBy number|nil charId of who granted it

-- ============================================
-- Vehicles
-- ============================================

---@class WhipVehicleDef
---@field vehicleId number Unique vehicle ID
---@field ownerCharId number Character who owns the vehicle
---@field model string Vehicle model name
---@field plate string License plate text
---@field state string 'out', 'garaged', or 'impounded'
---@field garage string|nil Garage key where stored
---@field fuel number Fuel level (0-100)
---@field properties table|nil GTA vehicle properties JSON (mods, colors, etc.)
---@field x number|nil World X position (when spawned)
---@field y number|nil World Y position
---@field z number|nil World Z position
---@field heading number|nil World heading
---@field trunkSlots number|nil Per-vehicle trunk slot override
---@field trunkMaxWeight number|nil Per-vehicle trunk weight override
---@field gloveboxSlots number|nil Per-vehicle glovebox slot override
---@field gloveboxMaxWeight number|nil Per-vehicle glovebox weight override
---@field locked boolean Whether the vehicle is locked
---@field createdAt number Epoch timestamp
---@field session boolean|nil True if this is a session-only (NPC) vehicle

---@class WhipVehicleOwnerInfo
---@field charId number Owner character ID (0 if unowned)
---@field name string|nil Owner full name (nil if offline or unowned)
---@field online boolean Whether the owner is currently online

--- What the server's GetVehicle / GetVehiclesOf / GetGarageVehicles hand back, and
--- what a `'vehicle'` SecureEvent param gives the handler: a COPY, safe to keep and change.
---@class WhipVehicleContext
---@field vehicleId number
---@field plate string
---@field model string Model name
---@field displayName string|nil Name from the vehicle catalog; nil for a model the catalog does not have
---@field class number|nil GTA vehicle class from the catalog; nil for a model the catalog does not have
---@field vehType string 'automobile', 'bike', 'boat', 'heli', ...
---@field session boolean True for a car nobody owns: street traffic whip adopted, OR a temporary car
---@field temp boolean True for a SpawnTempVehicle car (a rental, a job van) — session is true for these too
---@field secure boolean True for a SpawnTempVehicle car made with `secure = true`: no lockpicking, no ignition hacking
---@field owner WhipVehicleOwnerInfo
---@field state string|nil 'out' or 'garaged'
---@field garage string|nil Garage key it is filed under
---@field coords vector3|nil Where it is (or where it was parked)
---@field heading number|nil
---@field spawned boolean True while it is in the world
---@field entity number|nil Server entity handle while spawned
---@field netId number|nil Network id while spawned
---@field locked boolean
---@field occupants table|nil Only with `{ occupants = true }`
---@field stats table<string, number> The stats it carries
---@field data table<string, any> Data resources attached with SetVehicleData
---@field properties table|nil Its saved look (paint, mods)
---@field storage table|nil Trunk and glovebox use — only when already loaded (see storageLoaded)
---@field storageLoaded boolean

---@class WhipNearbyVehicle
---@field entity number Entity handle
---@field plate string License plate
---@field vehicleId number|nil Framework vehicle ID
---@field distance number Distance from player in meters
---@field model string|nil Model name

-- ============================================
-- Jobs
-- ============================================

---@class WhipJobDef
---@field jobId number Unique job ID
---@field key string Job key (e.g. 'police', 'mechanic') — every job has one
---@field name string Display name
---@field icon string|nil Icon name
---@field ownerCharId number|nil The owner: holds the top role and the business bank account
---@field settings table|nil Settings JSON; `permissions` (the job's own, { name = label }) and `selfClockOn` live here
---@field createdAt number Epoch timestamp
---@field createdBy number|nil Character who created the job

---@class WhipJobRole
---@field roleId number Unique role ID
---@field jobId number Parent job ID
---@field name string Role name
---@field level number Role level (1-100; 100 holds every permission)
---@field permissions WhipJobPermissions Permission flags

--- The built-ins; a job's own permissions (EnsureJob `permissions`) sit beside them as `name = true`.
---@class WhipJobPermissions
---@field canHire boolean|nil
---@field canFire boolean|nil
---@field canPromote boolean|nil
---@field canDemote boolean|nil
---@field canManage boolean|nil  the business: its roles, and its shop's stock and prices
---@field bankAccess 'none'|'view'|'deposit'|'withdraw'|'manager'|nil  access to the business bank account

--- A row of GetJobEmployees.
---@class WhipJobEmployee
---@field charId number Character ID
---@field roleId number Role ID
---@field roleName string|nil
---@field roleLevel number|nil
---@field hiredAt number Epoch timestamp
---@field hiredBy number|nil Character who hired them
---@field onDuty boolean
---@field source number|nil Their source, while online

--- An entry of GetPlayerJobs, or of GetPlayerJob (either side).
---@class WhipPlayerJobInfo
---@field jobId number Job ID
---@field key string Job key
---@field name string Job name
---@field icon string|nil
---@field roleId number Role ID
---@field roleName string
---@field roleLevel number
---@field clockedOn boolean|nil
---@field permissions table<string, boolean>|nil What they may do here

-- ============================================
-- Ground Items
-- ============================================

---@class WhipGroundItem
---@field id number Unique ground item ID
---@field item string Item key
---@field amount number Stack count
---@field metadata table|nil Item metadata
---@field x number World X
---@field y number World Y
---@field z number World Z
---@field heading number|nil World heading
---@field createdAt number Epoch timestamp
---@field createdBy number|nil Character ID who dropped it

-- ============================================
-- Containers
-- ============================================

---@class WhipContainerDef
---@field containerId number Unique container ID
---@field name string Container name/label
---@field type string|nil Container type (e.g. 'stash')
---@field slots number Number of inventory slots
---@field maxWeight number Maximum weight capacity
---@field ownerCharId number|nil Character who owns it
---@field locked boolean Whether the container is locked
---@field x number World X
---@field y number World Y
---@field z number World Z
---@field heading number|nil World heading
---@field prop string|nil GTA prop model
---@field allowedItems string[]|table<string, any>|nil Item whitelist: a list of item keys { 'food', 'drink' } (a keyed table's keys also count); nil takes anything
---@field createdAt number Epoch timestamp
---@field accessCharId number|nil The one character who may open it; nil for anyone
---@field key string|nil The key it was declared by (EnsureContainer), or given with UpdateContainer
---@field declared { by: string, decl: table }|nil EnsureContainer's record: who declared it, and the declaration
---@field requirements WhipContainerRequirements|nil Who may open it beyond the lock and accessCharId; nil for no rule

--- Who may open a container. ANY ONE of them lets a player in; `onDuty` makes `jobs`
--- mean on duty there (with no `jobs`, on duty anywhere). Stored in the one shape: jobs a list,
--- charIds a list (an empty one is nobody), items a list of { key, count }. Checked at the open and on
--- every move after it. A required item can never be put into the container it opens. `lockpick` is a door's and is refused.
---@class WhipContainerRequirements
---@field jobs string|string[]|nil Job key(s) — `job` works too
---@field onDuty boolean|nil Only while clocked on
---@field charIds number|number[]|nil Character id(s) — `charId` works too
---@field items string|table|nil An item carried (a keycard): a key, { key = 'x', count = 2 }, or a list — `item` works too
---@field ace string|nil An ACE permission
---@field property number|string|nil A propertyId or property key: its owner and keyholders may open it

-- ============================================
-- Garages
-- ============================================

---@class WhipGarageDef
---@field garageId number Unique garage ID
---@field key string Garage key identifier
---@field name string Display name
---@field x number Interaction X
---@field y number Interaction Y
---@field z number Interaction Z
---@field heading number Interaction heading
---@field spawnX number Vehicle spawn X
---@field spawnY number Vehicle spawn Y
---@field spawnZ number Vehicle spawn Z
---@field spawnHeading number Vehicle spawn heading
---@field blipSprite number|nil Map blip sprite ID
---@field blipColor number|nil Map blip color ID

-- ============================================
-- Shops
-- ============================================

---@class WhipShopDef
---@field shopId number Unique shop ID
---@field key string|nil Shop key identifier (set for shops made by EnsureShop)
---@field name string Display name
---@field mode 'infinite'|'stocked'|'npc' 'infinite' sells its catalog forever, 'stocked' sells what is on its shelf container, 'npc' is a shopkeeper
---@field npcModel string|nil Ped model for the shopkeeper
---@field prop string|nil Prop model placed at the shop
---@field x number Position
---@field y number
---@field z number
---@field heading number
---@field containerId number|nil The shelf container ('stocked' shops)
---@field catalog table<string, number>|nil What it sells: item key → whole-dollar price, e.g. { water = 5 }
---@field settings table|nil
---@field blipSprite number|nil Map blip sprite ID
---@field blipColor number Map blip color ID (default 2)
---@field jobId number|nil Owning job ID
---@field createdAt number|nil Epoch seconds
---@field createdBy number|nil charId of who made it

-- ============================================
-- Interactions and the F1 wheel
-- ============================================
--
-- All one declaration now: WhipAction, WhipActionAt, WhipActionRequire, WhipActionCtx and
-- WhipActionOption are in types/client.lua beside AddAction.

-- ============================================
-- Vehicle stats
-- ============================================

---@class WhipVehicleStatHudConfig
---@field icon string|nil SVG path data for the gauge icon; leave it out for one the dial draws itself (fuel, boost, nitro)
---@field iconCritical string|nil Alternate icon shown when the stat is nearly empty; extra paths separated with `|`
---@field color string Hex colour, e.g. '#f59e0b'
---@field order number|nil Left-to-right position in the vehicle panel (default 99)
---@field iconOnly boolean|nil Draw a lit/unlit symbol instead of a ring. Never combine with showAboveZero
---@field heartbeat boolean|nil Pulse the icon when the stat gets low
---@field hideWhenEmpty boolean|nil Hide the gauge entirely at zero
---@field noCritical boolean|nil Do not turn the ring red below 20%
---@field showAboveZero boolean|nil Only show the gauge once the stat is above zero

---@class WhipVehicleStatConfig
---@field default number|nil What a vehicle starts on (default 0)
---@field min number|nil Lowest value (default 0)
---@field max number|nil Highest value (default 100)
---@field persist boolean|'presence'|nil Save it with the vehicle (default true); 'presence': only that the car has it, written when it appears and when it goes, coming back at its default
---@field decay number|nil Points changed every decayInterval seconds; negative drains. OMIT to disable — 0 does not disable it
---@field decayInterval number|nil Seconds between decay ticks (default 10)
---@field hud WhipVehicleStatHudConfig|nil Draw a gauge in the vehicle panel and a meter on its garage card
---@field consume WhipVehicleStatConsumeConfig|nil Let the driver burn it down. The framework owns the report event, the driver check and the anti-cheat cap
---@field display WhipVehicleStatDisplay|nil How the value reads to a person: in real units (14 psi, 92°C) or as a gauge's end markers (E, F). Without it, a percentage

--- How a vehicle stat reads on its gauge and the /whip Vehicles page. The stat keeps its own min..max; this
--- only says what each point of that range reads as. Give `range` OR `points` (with a `unit`), and/or `ends`.
---
---     display = { unit = 'psi', range = { -3, 30 } }                              -- bottom and top of the range
---     display = { unit = '°C', points = { { 0, 20 }, { 50, 90 }, { 100, 130 } } } -- percent → reading, straight between
---     display = { ends = { 'E', 'F' } }                                           -- markers at the gauge's ends, no number
---@class WhipVehicleStatDisplay
---@field unit string|nil After the number, up to 8 characters: 'psi', '°C' ('°' and '%' units join the number)
---@field range number[]|nil { bottom, top }: what the stat reads at the bottom and the top of its range
---@field points number[][]|nil 2 to 16 { percent 0-100, reading } pairs, straight lines between: a curve
---@field decimals number|nil 0 (default), 1 or 2
---@field ends string[]|nil { empty, full }, up to 3 characters each: the gauge shows these at its two ends instead of a number

--- A VEHICLE REFERENCE: one way to name a car, taken by every vehicle, stat and data export on both
--- sides. Fill in ONE field. A bare number is a vehicleId everywhere, so an entity handle is
--- `{ entity = veh }`.
---
---     { id = vehicleId }   { entity = entity }   { plate = 'ABC123' }   { netId = netId }
---
--- A vehicle as GetVehicle returns it is a reference too: its `vehicleId` names it.
---@class WhipVehicleRef
---@field id number|nil The vehicle's whip id
---@field vehicleId number|nil The same, as a GetVehicle snapshot carries it
---@field entity number|nil An entity handle (on the server, a server entity)
---@field plate string|nil A licence plate (spaces ignored)
---@field netId number|nil A network id

--- What a change listener gets when registered with `{ table = true }`. The same field
--- names on both sides; each side fills in what it knows.
---@class WhipVehicleChange
---@field vehicleId number
---@field key string The stat name, or the data key
---@field value any The new value (nil when cleared)
---@field old any|nil The value before
---@field cleared boolean The stat or key is no longer on the car
---@field source string|nil Server stats only: what made the change ('direct', 'refuel:pump', 'now', …)
---@field resource string|nil Server data only: the resource that made the change
---@field entity number|nil Client only: the entity it happened on

--- Options for OnVehicleStatChanged / OnVehicleDataChanged.
---@class WhipVehicleListenOpts
---@field table boolean|nil Hand the callback one WhipVehicleChange table instead of positional arguments
---@field now boolean|'all'|nil Also call it once straight away for every car that already carries the stat or key; 'all' (OnVehicleStatChanged on the server, a named stat): every car whip has, its default included

--- Options for SpawnTempVehicle.
---@class WhipTempVehicleOpts
---@field plate string|nil Up to 8 characters; generated if left out
---@field vehType string|nil Worked out from the vehicle catalog if left out
---@field forSource number|nil The player it is for — they get a key unless giveKey = false
---@field giveKey boolean|nil Default true when forSource is given
---@field despawnAfter number|nil Seconds until it is removed — even with somebody driving it
---@field locked boolean|nil Spawns locked unless this is false
---@field keyInIgnition boolean|nil Put a key in its ignition, so whoever takes the driver's seat can start it
---@field idleDespawn boolean|nil False: never removed for sitting ten minutes with nobody near it
---@field tag string|nil One of your tags: ReleaseTag(tag) removes it, and once the tag is released no more spawn under it
---@field secure boolean|nil True: its lock cannot be picked and its ignition cannot be hacked — only its key works
---@field bucket number|nil The routing bucket it is made in, from its birth (default 0, the shared world)

---@class WhipVehicleStatConsumeConfig
---@field maxRate number Units per second, flat out. More than this per second is refused as a lie — REQUIRED
---@field driverOnly boolean|nil Only the driver may report (default true). False lets any occupant report, which is how a passenger drains a stranger's tank
---@field clearAtMin boolean|nil Take the stat OFF the vehicle at the floor rather than leaving a zero (default false). True for anything installable — a spent bottle is not a bottle
---@field slack number|nil Headroom over maxRate, for tick jitter (default 1.25)
---@field interval number|nil How often the client reports, in seconds (default 1.0). Also bounds the first report of a run

-- ============================================
-- UI Components
-- ============================================

--- A skill check difficulty: a name from Config.SkillCheckDifficulty (a server can add its own).
---@alias WhipSkillDifficulty 'easy'|'medium'|'hard'|string

--- The ring's own numbers, as one difficulty in Config.SkillCheckDifficulty has them (config.lua section 10 says what
--- each means). holdMs and mouseSpeed are every difficulty's (Config.SkillCheckHoldMs / MouseSpeed) unless given.
---@class WhipSkillLevel
---@field pieces integer How many directions the ring is cut into
---@field parts integer How many parts to fill
---@field widest number The first part's width, in pieces
---@field narrowest number The last part's width, in pieces
---@field msPerPart number The time for each part (the clock is this times the parts)
---@field holdMs number|nil How long the dot must stay on a part to fill it
---@field mouseSpeed number|nil How fast the mouse moves the dot

---@class WhipInputField
---@field label string Field label
---@field type string Input type: 'text' (default), 'number', 'textarea', 'select', 'checkbox', or 'password' | 'email' | 'tel' | 'url' | 'date' | 'time' | 'color' | 'range'
---@field placeholder string|nil Placeholder text
---@field default any|nil Default value
---@field required boolean|nil Whether the field is required
---@field min number|nil Minimum value (for 'number')
---@field max number|nil Maximum value (for 'number')
---@field options table[]|nil Options for 'select' type ({ label, value })

-- WhipContextOption is gone with UI.ContextMenu. What people mean by a context menu in whip is
-- a prompt with options: an AddAction (WhipAction, types/client.lua).

-- ============================================
-- SecureEvent / SecureCallback
-- ============================================

---@class WhipSecureSchema
---@field rateLimit number|false|nil Minimum ms between calls from same source. Omitted: 100ms with a burst of 10. `false`: not limited
---@field burst number|nil How many calls may arrive back-to-back before rateLimit applies (default 1)
---@field ace string|nil ACE permission required (e.g. 'whip.devtools')
---@field requirePlayer boolean|nil Validate player exists (default true)
---@field whileDead boolean|nil Let a DEAD player through (default false: dead players are refused unless this is true or `ace` is set)
---@field near WhipSecureNear|nil Refuse unless the caller is within `range` of `at`
---@field ownerOf string|nil The name of an 'id' param holding a netId: refuse unless the caller's game is that entity's network owner
---@field onReject fun(source: number, reason: string, rawArgs: any[])|nil SecureEvent only: called when the wrapper itself refuses the call, for a client waiting on an answer. rawArgs are unvalidated
---@field sheet 'full'|'light'|nil 'light': the handler's `player` is only source, userId, charId, names, dateOfBirth, gender, isDead — no position, cash, health or armour. For events fired many times a second
---@field params WhipSecureParam[]|nil Parameter validation rules

---@class WhipSecureNear
---@field at (fun(source: number, player: table, ...: any): number|vector3|table|nil, number?, number?)|vector3|table|'vehicle' A function returning x, y, z (or a vector3 / {x,y,z}); a fixed vector3 or {x,y,z}; or 'vehicle' — the car named by the schema's 'vehicle' param (seated in it counts as near). NO position REFUSES the call
---@field range number|(fun(): number)|nil Metres (default 5.0), or a function returning them at each call (a range that follows a setting)
---@field message string|false|nil What the player is told when too far (default 'Too far away'); false says nothing
---@field allowUnknown boolean|nil Let a call through when `at` finds no position — for a handler that reports an unknown id itself

--- Array: { name, type, ...options }. The types:
---   'int'    {name, 'int', min, max, default}    a QUANTITY — out-of-range values are CLAMPED
---   'number' {name, 'number', min, max, default} same, not floored
---   'id'     {name, 'id', min?, max?}            an ADDRESS (a slot, a player, an account) —
---                                                 out of range or not whole is REJECTED, never clamped
---   'string' {name, 'string', maxLen, default}
---   'key'    {name, 'key', maxLen}               letters, digits, _ and - only
---   'enum'   {name, 'enum', {allowed...}, default}
---   'bool'   {name, 'bool', default}             true/false, 1/0, "true"/"false"
---   'slot'   {name, 'slot', {item=key|{keys}, allowEmpty=true}?}
---                                                 a slot in the CALLER'S OWN pockets (a number, or
---                                                 {sub, slot}); refused if empty or the wrong item.
---                                                 Handler gets WhipSlotParam
---   'list'   {name, 'list', entry, max?}         a list, every entry checked against `entry` (one
---                                                 param def, or a list of defs for table entries);
---                                                 max defaults to 50; an 'addr' entry is refused
---   'addr'   {name, 'addr', {slotOptional=true}?} a store address, resolved and authorised. Your
---                                                 resource's handler gets WhipSlotParam (whip_core's
---                                                 own get the store)
---   'vehicle'{name, 'vehicle', {session=true}?}  a vehicle id the caller OWNS (resolved and
---                                                 authorised); session=true also accepts a street car
---   'player' {name, 'player', {range=3, notSelf=true}?} another player by server id: loaded, not in the
---                                                 creator, same routing bucket, within range. Handler
---                                                 gets their light sheet
---   'record' {name, 'record', { {field, type, ...}, ... }} one table of named fields, each checked as a
---                                                 list entry's; the handler gets only those fields
---   'any'    {name, 'any'}                        unchecked — validate it yourself
---@alias WhipSecureParam table

--- What a 'slot' or 'addr' param hands your handler: where it is, and a COPY of what is in it.
---@class WhipSlotParam
---@field addr WhipStoreAddr The address every slot call takes (GetItemAt, StoreTake, SetItemMetadata...)
---@field item string|nil
---@field amount number|nil
---@field metadata table|nil A copy — changing it changes nothing; use SetItemMetadata

-- ============================================
-- External Panel
-- ============================================

---@class WhipExternalPanelConfig
---@field id string Panel ID
---@field label string|nil Panel header label (default 'Panel')
---@field slots number Number of panel slots (1-50)
---@field items table<number, WhipInventorySlot>|nil Initial slot contents
---@field resource string|nil Owning resource name

---@class WhipExternalPanelItemConfig
---@field slots number Number of slots
---@field label string Panel header label
---@field storageKey string Metadata key where nested inventory is stored (e.g. 'slots')
---@field allowedItems string[]|table<string, any>|nil Allowed items: a list of item keys { 'cash', 'id_card' } (a keyed table's keys also count; a per-item maxPerSlot is not enforced)


-- ============================================
-- Camera
-- ============================================

---@class WhipCameraOptions
---@field pos vector3|nil Camera position (default: where the gameplay camera is)
---@field rot vector3|nil Camera rotation (default 0,0,0)
---@field fov number|nil Field of view (default 60)
---@field filter string|nil Timecycle filter name (default 'none')
---@field canLook boolean|nil Mouse look (default false)
---@field canMove boolean|nil WASD movement (default false)
---@field exitKey boolean|nil Escape ends the camera (default true)
---@field transitionIn number|nil Ease in from the gameplay camera, ms
---@field transitionOut number|nil Ease back to the gameplay camera when it stops, ms
---@field async boolean|nil Return at once instead of waiting for the camera to end

-- ============================================
-- Progress bars and timed uses
-- ============================================

---@class WhipProgressAnim
---@field dict string|nil Animation dictionary
---@field clip string|nil Animation name
---@field flag number|nil Default 49: upper body, so the player can walk if `disable.move` allows
---@field scenario string|nil Instead of dict/clip: a GTA scenario, e.g. 'WORLD_HUMAN_VEHICLE_MECHANIC'

---@class WhipProgressProp
---@field model string|number Prop model
---@field bone number|nil Ped bone index (default 18905, right hand)
---@field offset { x: number, y: number, z: number }|number[]|nil
---@field rot { x: number, y: number, z: number }|number[]|nil

---@class WhipProgressOptions
---@field label string|nil Text above the bar
---@field icon string|nil A glyph's name (html/js/glyphs.js: 'eat', 'fuel', 'place'...) for the capsule's disc, which fills with the bar. Default: an hourglass
---@field item string|{ item: string, metadata: table|nil }|nil The item the bar is done with: its key, or a slot's data (GetItemAt's), for a picture by its state. The disc shows its picture in its bubble (as the hotbar does) instead of filling; the bar under the words still fills. No picture: `icon`. A timed use (WhipTimedUse) passes its own
---@field duration number|nil Ms to fill (client default 3000; REQUIRED for the server Progress)
---@field canCancel boolean|nil X / Escape stops it. Default false for Progress; true in a timed use (WhipTimedUse)
---@field anim WhipProgressAnim|nil Played for the length of the bar
---@field prop WhipProgressProp|nil Held for the length of the bar
---@field disable { move?: boolean|'walk', combat?: boolean, car?: boolean }|nil What is held off. Default: move and combat off, driving allowed. move = 'walk': walking only, trying to run cancels the bar
---@field cancelOnDeath boolean|nil Default true: dying, or being knocked down (ragdolled), ends it as 'cancelled', shown as interrupted (red, with why; a long fall is said as falling)
---@field cancelOnExit boolean|nil Default false: work done from a seat; getting out of the vehicle it began in ends it as 'cancelled' (the server Progress: 'not in a vehicle' to start, 'left the vehicle' to finish)
---@field notWhile ('swimming'|'underwater'|'falling')[]|nil Not in these: it does not start ('refused'), and one that begins ends it as 'cancelled', both said on the capsule ('You cannot do that while swimming'). 'swimming' covers under water too. The player's game checks it

--- RegisterUseHandler(item, THIS) — a timed use whip runs from start to finish: canUse → the bar,
--- timed by the server → the same item still at addr → the item is taken → onComplete. onComplete
--- returning `false, 'why'` (or erroring) gives it back and shows `why`. A bare `false` ALSO gives it
--- back (a silent refusal, no cooldown) — unlike the function form, where bare `false` is a use that
--- keeps the item. To keep a tool here, set `consume = false`.
---@class WhipTimedUse : WhipProgressOptions
---@field duration number REQUIRED. The bar's length in ms
---@field consume boolean|nil Default true. false keeps the item (a timed use of a tool)
---@field reason string|nil What the item log says it was used for (default 'used')
---@field canUse (fun(source: number, player: table, slotData: table, addr: table): boolean, string?)|nil Checked before the bar; false, 'why' refuses and shows why
---@field onComplete (fun(source: number, player: table, item: table, addr: table): boolean?, string?)|nil After the item is taken; false, 'why' gives it back

---@class WhipCameraWaypoint
---@field pos vector3 Waypoint position
---@field rot vector3 Waypoint rotation
---@field fov number|nil FOV at this waypoint

-- ============================================
-- Zones
-- ============================================

---@class WhipZoneRules
---@field noWeapons boolean|nil Remove all weapons on entry, block re-equipping
---@field noPvP boolean|nil Player invincible inside zone
---@field noMelee boolean|nil Block punching/melee attacks
---@field disableFiring boolean|nil Block weapon firing but allow carrying
---@field speedLimit number|nil Vehicle speed cap in km/h
---@field noVehicles boolean|nil Force exit vehicle on entry
---@field heal boolean|nil Gradual health regen while inside
---@field healRate number|nil HP per tick, default 2 (runs every 300ms)
---@field noWantedLevel boolean|nil Clear and prevent wanted level
---@field noCollision boolean|nil Disable ped-to-ped collision
---@field noFallDamage boolean|nil No fall damage inside: the player is collision-proof, so crashes and being run over do no damage either
---@field jobWhitelist string[]|nil Array of job keys allowed in zone
---@field aceWhitelist string|nil ACE permission required to enter (e.g. 'whip.vip')
---@field charWhitelist number[]|nil Array of character IDs allowed in zone
---@field ejectUnauthorized boolean|nil Teleport unauthorized players out
---@field enterNotify string|nil|false Custom enter notification (false = disable)
---@field exitNotify string|nil|false Custom exit notification (false = disable)

---@class WhipZoneBoxData
---@field type 'box'
---@field id string|nil Custom ID (auto-generated if nil)
---@field pos vector3 Center position
---@field size vector3 Width (X), length (Y), height (Z)
---@field heading number|nil Rotation in degrees (default 0)
---@field onEnter (fun(zone: WhipZoneBoxData))|nil Called when player enters
---@field onExit (fun(zone: WhipZoneBoxData))|nil Called when player exits
---@field inside (fun(zone: WhipZoneBoxData))|nil Called every tick while inside
---@field condition (fun(): boolean)|nil Zone only active when returns true
---@field priority number|nil Higher priority fires first on enter (default 0)
---@field group string|nil Group name for batch removal
---@field label string|nil Display name
---@field debug boolean|nil Render zone outline (default false)
---@field trackVehicles boolean|nil Enable vehicle enter/exit detection (default false)
---@field rules WhipZoneRules|nil Declarative zone rules (framework-enforced)
---@field onVehicleEnter (fun(entity: number, plate: string, zone: WhipZoneBoxData))|nil
---@field onVehicleExit (fun(entity: number, plate: string, zone: WhipZoneBoxData))|nil

---@class WhipZoneSphereData
---@field type 'sphere'
---@field id string|nil Custom ID (auto-generated if nil)
---@field pos vector3 Center position
---@field radius number Radius in meters
---@field onEnter (fun(zone: WhipZoneSphereData))|nil
---@field onExit (fun(zone: WhipZoneSphereData))|nil
---@field inside (fun(zone: WhipZoneSphereData))|nil
---@field condition (fun(): boolean)|nil
---@field priority number|nil
---@field group string|nil
---@field label string|nil
---@field debug boolean|nil
---@field trackVehicles boolean|nil
---@field onVehicleEnter (fun(entity: number, plate: string, zone: WhipZoneSphereData))|nil
---@field onVehicleExit (fun(entity: number, plate: string, zone: WhipZoneSphereData))|nil
---@field rules WhipZoneRules|nil Declarative zone rules (framework-enforced)

---@class WhipZonePolyData
---@field type 'poly'
---@field id string|nil Custom ID (auto-generated if nil)
---@field points vector2[] Array of polygon vertices
---@field minZ number|nil Minimum Z height
---@field maxZ number|nil Maximum Z height
---@field onEnter (fun(zone: WhipZonePolyData))|nil
---@field onExit (fun(zone: WhipZonePolyData))|nil
---@field inside (fun(zone: WhipZonePolyData))|nil
---@field condition (fun(): boolean)|nil
---@field priority number|nil
---@field group string|nil
---@field label string|nil
---@field debug boolean|nil
---@field trackVehicles boolean|nil
---@field onVehicleEnter (fun(entity: number, plate: string, zone: WhipZonePolyData))|nil
---@field onVehicleExit (fun(entity: number, plate: string, zone: WhipZonePolyData))|nil
---@field rules WhipZoneRules|nil Declarative zone rules (framework-enforced)

-- ============================================
-- Store addresses
-- ============================================

--- Where a stack is, in the one shape whip uses for it everywhere — THE handle for a slot. Every slot
--- call takes one (GetItemAt, SetItemMetadata, StoreGive, StoreTake, StoreMove, LogActivity), and
--- whip hands you one wherever it knows where an item is (a use handler, a context action, FindItem,
--- FindItemByUid, GetOpenStores).
---
--- THE POINT OF THIS TYPE EXISTING is that the address was already a parameter — the note on the
--- 'addr' param type in server/secure.lua records that it had been "declared 21 times across four
--- files in four different shapes", one of which validated nothing at all.
---
--- WHICH FIELDS MATTER DEPENDS ON THE KIND:
---   player     id = server id, sub = the pocket ('player' | 'accessory', default 'player')
---   container  id = container id (loaded on demand)
---   vehicle    id = vehicle id or a vehicle reference ({ plate = 'X' }), sub = 'trunk' | 'glovebox'
---              | 'key' (loaded on demand)
---   panel      id = panel id; owner = a player who has it open (optional)
---   your kind  id / sub, handed to its resolve({ id, sub })
---   shop, basket — CLIENT ONLY. They exist relative to a player who has one open, so there is no
---                  server-side address for them and StoreMove refuses one.
--- The slot is left out where a call can choose one (StoreGive, StoreRead, StoreMove's destination).
---@class WhipStoreAddr
---@field kind string Store kind
---@field id number|string|table|nil Which one, where the kind needs it
---@field sub string|nil Sub-store (a player's pocket, a vehicle storage type)
---@field slot number|nil Slot number, 1-based
---@field owner number|nil panel only: the player whose session to go through
---@field label string|nil Filled in on addresses whip hands you (hooks, GetOpenStores); ignored on the way in

--- The one table every panel hook is handed — onValidate(ctx) and onChange(ctx), for a panel a
--- resource opened (OpenPanel) and for a RegisterPanelItem panel alike.
---@class WhipPanelHookCtx
---@field source number The player whose move it is
---@field panel string|number The panel's id
---@field host table|nil A RegisterPanelItem panel's item: { source, container, slot, addr, item, amount, metadata } — addr is its whip address
---@field direction 'in'|'out'|'within' From the panel's point of view: 'in' is into the panel
---@field slot number The panel's slot
---@field otherSlot number|nil The other end's slot
---@field other WhipStoreAddr|nil The other end, as an address. nil when the item is being destroyed
---@field item string What is moving
---@field amount number
---@field metadata table|nil
---@field swap boolean|nil onValidate: true for the returning half of a swap (inside one panel too)
---@field replacing { item: string, amount: number, metadata: table|nil }|nil onValidate: on the FORWARD half of a swap, what is in the slot now and leaves as this arrives
---@field destroyed boolean|nil true when the player is destroying the item (direction 'out', no other end)
---@field items table<number, WhipInventorySlot>|nil onChange: what the panel holds now (a copy)

--- What StoreRead returns. A copy.
---@class WhipStoreContents
---@field kind string
---@field id number|string|nil
---@field sub string|nil
---@field label string
---@field slots number
---@field maxWeight number
---@field weight number
---@field items table<number, WhipInventorySlot> keyed by slot number

--- AddItem's options (its last argument may also be just a reason string).
---@class WhipAddItemOpts
---@field reason string|nil For the activity log, beside your resource's name
---@field noDrop boolean|nil Refuse instead of dropping at their feet when it will not fit
---@field pocket string|nil 'player' | 'accessory' — only that pocket
---@field coords vector3|nil Where to drop it when it will not fit, instead of at their feet
