-- whip_core configuration. Edit a value, save, then run `ensure whip_core` in the server console.
-- A mistake in this file (a missing comma, bracket or quote) stops whip_core from starting; the console names the line.
-- Most settings can also be changed in game (/whip > Settings > Config). A value changed there wins over this file
-- until you press Reset on its row, so edit a setting in one place only.
-- Garages and Shops are seeds: read only the first time the server runs, then edited in the /whip panel.
--
-- Contents: 1 New characters, 2 Inventory, 3 Items, 4 Player stats and HUD, 5 Jobs, 6 Time and weather,
-- 7 Vehicles, 8 Garages, 9 Shops, 10 World interaction, 11 Character select, 12 Performance, 13 Advanced.
--
-- Most servers change first: DefaultSpawn, DefaultCash, StartingBalance, ContainerSlots, MaxWeight, Items,
-- Hunger, Thirst, RespawnTime, RespawnLocations, TimeScale, StartTime, StartWeather, Garages, Shops, Theme.

Config = {}


-- 1. New characters

Config.MaxCharacters = 4      -- Characters per player, up to 30. Each has a hero shot (Config.CharSelect.slots);
                              -- one with no shot of its own shows another until it has one.

-- Where a brand new character wakes up. vector4 is x, y, z, heading.
Config.DefaultSpawn = vector4(-1023.03, -1660.96, 4.62, 44.92)

Config.DefaultCash     = 500    -- Cash placed in their pockets
Config.StartingBalance = 1000   -- Money in their bank account

Config.DefaultAccountLabel = 'Personal Account'   -- Name shown in the bank app (the account is always a personal one)

-- How many savings and shared accounts one character may open (the phone's Bank app, or any
-- resource). Their personal account and job accounts don't count. 0 = none.
Config.MaxExtraAccounts = 5

-- Stops a player's own characters moving money between each other through the bank (transfer, pay in, take
-- out, shared accounts). Cash handed over in the world is not followed.
--   true  = blocked (the safe default)
--   false = a player's characters may move money between them like anyone else
Config.BlockOwnCharacterTransfers = true


-- 2. Inventory

Config.ContainerSlots = {
    -- Main inventory: five columns, four rows showing, then it scrolls. Any number works.
    player    = 30,
    accessory = 5,    -- The small strip: Phone, Money and three Keys (Config.AccessoryStrip below).
}

Config.MaxWeight = {   -- Kilograms
    player    = 80.0,   -- everything a character carries, the accessory strip included
    accessory = 10.0,   -- the strip on its own, inside the 80
}

-- What the inventory and shops show weights in, until a player picks their own (Server Settings → Map & HUD).
--   'kg' = grams under a kilo, kilograms from one up
--   'lb' = ounces under a pound, pounds from one up
-- Weights in this file and in RegisterItem are kilograms either way.
Config.WeightUnit = 'kg'

-- The small strip beside the inventory: slot 1 Phone, slot 2 Money (cash or a wallet), slots 3 to 5 Key. A car key
-- in a Key slot goes into the ignition by itself when its holder takes the driver's seat, and back when they get
-- out, so they can carry three cars' keys. whip_phone looks for a phone in the Phone slot first.
--   true  = every character has it
--   false = no strip: everything goes in the inventory, and keys go in the ignition by hand.
--           What was in the strip moves into the inventory at next login.
-- A resource adds or replaces a slot with exports.whip_core:RegisterAccessorySlot{ slot = 4, accepts = 'badge', label = 'Badge' }.
Config.AccessoryStrip = true

-- What happens when someone is given an item and has no room for it.
--   true  = the item drops at their feet, where anyone nearby can pick it up
--   false = the item is refused and whatever was giving it is told no
-- Either way whip never destroys the item.
Config.DropOnFullInventory = true

-- Dropped items land in proper stacks (20 magazines are 20 piles). This caps the piles one drop can make;
-- past it, the items are shared out evenly across this many piles.
Config.MaxGroundPilesPerDrop = 50

-- false = no inventory screen at all (weight, stacking, bags, storage and saving keep working).
-- For a different look use a theme (Config.Theme); for your own screen name your resource in Config.InventoryRenderer.
Config.EnableInventoryUI = true


-- 3. Items
--
-- Add an item here and it works on the next restart. Other resources add theirs with exports.whip_core:RegisterItem(key, definition).
-- Making an item do something is code (server/items/); `usable = true` only makes the button work.
-- An item's icon is html/img/items/<key>.png unless `image` names another.
--
-- Fields
--    name           Display name shown in the inventory
--    desc           Tooltip text
--    weight         Kilograms, for one of them
--    type           Category label shown on the tooltip
--    stack          true if several can share one slot
--    maxStack       How many fit in that slot (1 when stack = false)
--    usable         true to let the player use it from the hotbar or right-click
--    cooldown       Seconds before it can be used again (0 = no wait)
--    prop           World model shown when the item is dropped on the ground
--
-- Optional
--    metaFields     Extra tooltip lines read from the item itself, e.g. a number plate; one with a
--                   `value` shows that fixed text when the item has none (e.g. an ammo type)
--    defaultAction  What double-clicking it does
--    contextOptions Extra right-click entries, { action, label, order, when, require }, under Use, lowest
--                   `order` first. An option can show only some of the time:
--                     when    = { ammo = { above = 0 } }           the item's metadata says so
--                     require = { job = 'police', onDuty = true }   the player's state says so
--                   It shows only on items you carry unless `anywhere = true` (then also in a boot, glovebox, stash or bag).
--    images         Pictures that depend on the item, first match wins, else its own picture:
--                     { when = { slots = { empty = false } }, image = 'html/img/items/duffle_bag_full.webp' }
--                     { image = 'html/img/items/keys/{make}.webp' }   {field} = a metadata field; {make} = its car's maker
--                     { amount = { atLeast = 1000 }, image = ... }   by how many are in the slot (cash)
--
-- `when` tests, one per metadata field (all must pass): ammo = 0 (equal), model = { 'adder', 't20' } (one of),
-- ammo = { above = 0 } (also below, atLeast, atMost), slots = { empty = false }. `default` beside a test is what a
-- missing field counts as. An option's `whyNot` is what a player told no by its `when` hears.

Config.Items = {
    food = {
        name     = 'Burger',
        desc     = 'A greasy fast-food burger. Restores hunger.',
        weight   = 0.3,
        type     = 'consumable',
        stack    = true,
        maxStack = 20,
        usable   = true,
        cooldown = 3,
        prop     = 'prop_cs_burger_01',
    },
    drink = {
        name     = 'Water Bottle',
        desc     = 'A bottle of clean water. Restores thirst.',
        weight   = 0.4,
        type     = 'consumable',
        stack    = true,
        maxStack = 15,
        usable   = true,
        cooldown = 3,
        prop     = 'prop_ld_flow_bottle',
    },
    bandage = {
        name     = 'Bandage',
        desc     = 'A basic medical bandage. Restores some health.',
        weight   = 0.2,
        type     = 'medical',
        stack    = true,
        maxStack = 10,
        usable   = true,
        cooldown = 5,
        prop     = 'prop_med_bag_01',
    },
    package = {
        name     = 'Package',
        desc     = 'A sealed parcel. Someone is waiting for it.',
        weight   = 1.0,
        type     = 'misc',
        stack    = false,
        maxStack = 1,
        usable   = false,
        cooldown = 0,
        prop     = 'prop_cs_cardbox_01',
    },
    id_card = {
        name     = 'ID Card',
        desc     = 'Personal identification card.',
        weight   = 0.1,
        type     = 'document',
        stack    = false,
        maxStack = 1,
        usable   = false,
        cooldown = 0,
        prop     = 'prop_cs_business_card',
    },
    cash = {
        name     = 'Cash',
        desc     = 'The American Dream.',
        weight   = 0.0001,  -- tiny on purpose: 800,000 notes fills an 80kg inventory
        type     = 'currency',
        stack    = true,
        maxStack = 999999,
        usable   = false,
        cooldown = 0,
        prop     = 'prop_cash_pile_01',
        -- The picture by how much is in the slot (dollars); with no slot to count, the stack picture.
        image   = '@whip_core/html/img/items/cash_3_stack.webp',
        images   = {
            { amount = { below = 100 },       image = 'html/img/items/cash_0_broke.webp' },
            { amount = { below = 1000 },      image = 'html/img/items/cash_1_notes.webp' },
            { amount = { below = 10000 },     image = 'html/img/items/cash_2_fan.webp' },
            { amount = { below = 50000 },     image = 'html/img/items/cash_3_stack.webp' },
            { amount = { below = 100000 },    image = 'html/img/items/cash_4_stacks.webp' },
            { amount = { below = 500000 },    image = 'html/img/items/cash_5_tower.webp' },
            { amount = { atLeast = 500000 },  image = 'html/img/items/cash_6_pile.webp' },
        },
    },
    vehicle_key = {
        name     = 'Vehicle Key',
        desc     = 'A key fob for a specific vehicle.',
        weight   = 0.1,
        type     = 'key',
        stack    = false,
        maxStack = 1,
        usable   = false,
        cooldown = 0,
        prop     = 'prop_cuff_keys_01',
        -- Reads the model and plate off the key itself.
        metaFields = {
            { key = 'model', label = 'Vehicle', format = 'uppercase' },
            { key = 'plate', label = 'Plate' },
        },
        -- Looks like its car maker's key (html/img/items/keys/pegassi.webp); a maker with no picture shows the plain key.
        images = {
            { image = 'html/img/items/keys/{make}.webp' },
        },
    },
    lockpick = {
        name     = 'Lockpick',
        desc     = 'A set of lockpicking tools.',
        weight   = 0.3,
        type     = 'tool',
        stack    = false,
        maxStack = 1,
        usable   = false,
        cooldown = 0,
        -- A prop the game does not have falls back to Config.DefaultGroundProp.
        prop     = 'prop_tool_screwdvr02',
    },
    -- Used, it comes up to the eye as a viewfinder (wheel to zoom); used again or Esc puts it away.
    camera = {
        name     = 'Camera',
        desc     = 'The perfect tool for documenting illegal parking.',
        weight   = 1.2,
        type     = 'tool',
        stack    = false,
        maxStack = 1,
        usable   = true,
        cooldown = 0,
        prop     = 'prop_pap_camera_01',
    },
    hacked_vehicle_key = {
        name     = 'Hacked Vehicle Key',
        desc     = 'A strange electronic device attached to a pair of vehicle keys...',
        weight   = 0.1,
        type     = 'key',
        stack    = false,
        maxStack = 1,
        usable   = false,
        cooldown = 0,
        -- A swipe card, so a hacked key does not look like a real one on the ground.
        prop     = 'prop_cs_swipe_card',
        metaFields = {
            { key = 'model',  label = 'Vehicle', format = 'uppercase' },
            { key = 'plate',  label = 'Plate' },
            { key = 'status', label = 'Status' },
        },
    },
    -- A bag: 25 slots, takes anything. The 1.5kg is the empty bag; its contents weigh on top.
    duffle_bag = {
        name     = 'Duffle Bag',
        desc     = 'A heavy canvas holdall. Twenty-five slots, and it weighs what you put in it.',
        weight   = 1.5,
        type     = 'accessory',
        stack    = false,
        maxStack = 1,
        usable   = false,
        cooldown = 0,
        prop     = 'prop_cs_heist_bag_01',
        defaultAction  = 'open_duffle',
        contextOptions = {
            { action = 'open_duffle', label = 'Open' },
        },
        -- Zipped and full while anything is in it; flat when empty.
        images = {
            { when = { slots = { empty = false } }, image = 'html/img/items/duffle_bag_full.webp' },
        },
    },
    wallet = {
        name     = 'Wallet',
        desc     = 'A leather wallet for cash and cards.',
        weight   = 0.2,
        type     = 'accessory',
        stack    = false,
        maxStack = 1,
        usable   = false,
        cooldown = 0,
        prop     = 'prop_ld_wallet_02',
        defaultAction  = 'open_wallet',
        contextOptions = {
            { action = 'open_wallet', label = 'Open', icon = '&#128188;' },
        },
    },
    -- (jerry_can is whip_gunny's item.)
    armour = {
        name     = 'Body Armour',
        desc     = 'A kevlar vest. Use to equip and gain 100 armour.',
        weight   = 3.0,
        type     = 'equipment',
        stack    = true,
        maxStack = 3,
        usable   = true,
        cooldown = 10,
        prop     = 'prop_armour_pickup',
    },
    damage_reducer = {
        name     = 'Damage Reducer',
        desc     = 'A combat stim. Reduces incoming weapon damage by 95% for 20 seconds.',
        weight   = 0.2,
        type     = 'consumable',
        stack    = true,
        maxStack = 5,
        usable   = true,
        cooldown = 25,
        prop     = 'prop_cs_pills',
    },
}


-- Shape the minimap is cut to, which also makes it opaque with no edge fade:
--   'square'   a rectangle
--   'rounded'  a rectangle with rounded corners
--   'circle'   an ellipse filling the frame (re-tune the SetMinimapComponentPosition calls in client/hud.lua if you use it)
--   false      leave the game's own mask alone
Config.MinimapMask = 'rounded'

-- How the player HUD looks: the gauges at the bottom left and the minimap (not the vehicle dial).
--   'black'    black discs in a white rim that drains as the stat does, no capsule behind them (it shows only for a
--              notification or chat), a white frame and whip's dark map on the minimap, the waypoint route in blue
--   'classic'  the gauges as discs that fill white, inside the capsule
Config.HudSkin = 'black'

-- true: while a player aims, GTA's reticle is replaced by a small dot where the weapon points (red against a wall).
-- Not for melee weapons or the petrol can. false: GTA's own reticle.
Config.AimDot = true

-- true: a player in developer mode (/w switch) has its gauge on the HUD, the terminal prompt in amber.
-- false: no mark (for filming); developer mode works the same.
Config.HudDeveloperMark = true

-- The HUD and whip's screens always go while a player looks through the camera item.
-- false: whip's things in the world stay, so the camera sees them (/me bubbles, NPC conversations, parking guide,
-- Director marks). true: they are hidden too.
Config.CameraHidesDui = false

-- Map options (/whip > Config > Map options). Each player sets their own minimap in the pause menu's Server
-- Settings; these let the server decide instead. A setting the server decides shows greyed there.
--   onFoot        the minimap on foot: 'player' (each player chooses), 'on' (always shown) or 'off' (never)
--   inVehicle     the same, in a vehicle
--   forceMinimap  true: every player gets the minimap set in `minimap`, and their own settings are locked
--   minimap       the minimap everyone gets when forceMinimap is true: frame rate, border (true = white frame,
--                 'outline', false = none; black HUD look only), north always up, player in the centre, marker size (%),
--                 upright markers, metres shown on foot / in a vehicle when slow / at top speed, the speeds the zoom
--                 runs between (the dial's unit), and the tilts (degrees)
Config.MapOptions = {
    onFoot = 'player',
    inVehicle = 'player',
    forceMinimap = false,
    minimap = {
        fps = 60, border = true, northUp = false, centre = false, markerSize = 100, markersUpright = true,
        viewFoot = 230, viewSlow = 290, viewFast = 800, speedFrom = 0, speedTo = 100,
        tiltFoot = 0, tiltVehicle = 38, tiltWithSpeed = false, tiltFast = 50,
    },
}

-- GTA's own guns (a dead NPC's gun, the shotgun in a police car): whip stops them being picked up and takes away any
-- that arrive. Guns come from whip_gunny's items.
--   Enabled   false lets GTA's guns through
--   Allow     GTA weapons a player may keep anyway (the parachute lets them bail out of an aircraft)
--   SweepMs   how often to check for one that slipped through (milliseconds)
Config.WeaponGuard = {
    Enabled = true,
    Allow   = { 'GADGET_PARACHUTE' },
    SweepMs = 5000,
}

-- GTA's combat stance after you fire or are shot at; whip keeps it off.
--   Disable   false keeps GTA's action mode
Config.ActionMode = {
    Disable = true,
}

-- GTA's slow cinematic pan after about 30 seconds with no input; whip turns it off.
--   Disable   false keeps GTA's idle camera
--   ResetMs   in a car, how often the driver's idle timer is reset (milliseconds)
Config.IdleCam = {
    Disable = true,
    ResetMs = 10000,
}

-- A chase camera each player can switch on for themselves (pause menu: Server Settings → Vehicles): it follows the
-- car on a spring, leans into slides, widens with speed and shakes a little. C looks behind; first person stays GTA's.
--   Enabled   false: nobody can switch it on
--   Default   what a player who never chose gets
--   Shake     how much it shakes (0 never, 1 normal, up to 3)
Config.DrivingCamera = {
    Enabled = true,
    Default = false,
    Shake = 1.0,
}

-- What a gamepad's buttons do outside menus. Players change their own in the pause menu (Controller).
--   Layout      what each of whip's buttons does. whip's own actions:
--                 'radial'     the radial menu, after holding RadialHoldMs
--                 'engine'     engine on/off, in the driver's seat
--                 'inventory'  the inventory
--                 'sprint'     one press jogs, two sprint, until the stick goes back to the middle
--               Other resources add their own: 'phone' (whip_phone), 'talk' and 'radio' (whip_voice), 'nitrous'
--               (whip_autos), 'gunny_check_ammo' (whip_gunny). An action named here keeps that button; another
--               resource's action that asks for it gets none and players put it on a button themselves.
--               A button set to false is open for a resource's action that asks for it.
--               Each action goes on one button. lb_ buttons are pressed with LB held. veh_a is A in a vehicle.
--   RadialHoldMs        how long to hold the radial's button (milliseconds)
--   SprintDoubleClickMs the most time between the two presses (milliseconds)
--   SprintOnA           true lets A sprint as well, as GTA has it
--   VehicleControls     taking a driver's seat shows the vehicle's buttons (engine, headlights, nitrous) over the
--                       rev dial for a few seconds. false: off for everyone who has not turned it on themselves
--   VehicleControlsMs   how long they stay before they fade (milliseconds)
Config.Controller = {
    RadialHoldMs        = 500,
    SprintDoubleClickMs = 300,
    SprintOnA           = false,
    VehicleControls     = true,
    VehicleControlsMs   = 5000,
    Layout = {
        dpad_up       = 'phone',       -- whip_phone
        dpad_down     = 'radial',
        dpad_left     = 'engine',
        dpad_right    = 'inventory',
        l3            = 'sprint',      -- pressing the left stick in
        veh_a         = 'nitrous',     -- whip_autos
        foot_b        = 'gunny_reload',       -- whip_gunny
        lb_a          = 'talk',        -- whip_voice
        lb_b          = 'gunny_check_ammo',   -- whip_gunny
        lb_x          = 'radio',       -- whip_voice
        lb_y          = false,
        lb_dpad_up    = false,
        lb_dpad_down  = false,
        lb_dpad_left  = false,
        lb_dpad_right = false,
    },
}

-- The on-screen keyboard controller players type on. It suggests how to finish the word, in the player's language.
-- Each language is a pack in html/keyboard/.
--   Languages  the languages players may type in, by code: { 'en' }, { 'en', 'fr' }. With more than one the keyboard
--              has a switch key and players pick theirs in the pause menu; until then they get GTA's language if listed.
--   Default    the language for a player whose GTA language is not in the list
Config.Keyboard = {
    Languages = { 'en' },
    Default   = 'en',
}

-- 4. Player stats and HUD

-- Hunger and thirst, on or off.
--   true  = it drains over time (see the minutes below), is saved with the character, has a gauge, and costs
--           health once it falls under 10%. Food (or drink) fills it back up.
--   false = no gauge, no drain, no damage. Food and drink can still be used.
Config.Hunger = true
Config.Thirst = true

-- How long each takes to drain from full to empty, in minutes, while it is on. Health starts going at 10%: about
-- an hour and 50 minutes after a full meal, an hour and 20 after a full drink.
Config.HungerMinutes = 120
Config.ThirstMinutes = 90

-- What an empty one costs: health lost every 10 seconds while hunger or thirst is at 10 or below
-- (health runs to 200). 0 = they never hurt.
Config.NeedDamage = 1

-- Seconds a dead player waits before they can hold E to respawn at a hospital. A resource can hold it longer
-- for one player (HoldRespawn).
Config.RespawnTime = 10

-- The hospitals a respawn wakes up at, one at random: vector4(x, y, z, heading).
Config.RespawnLocations = {
    vector4(360.83, -585.28, 28.83, 250.38),    -- Pillbox Hill
    vector4(341.54, -1395.75, 32.51, 51.94),    -- Central Los Santos
    vector4(-449.10, -333.17, 34.50, 51.93),    -- Mount Zonah
}

-- whip's death screen (the red band: the countdown, then "Hold E to respawn"). false = a resource of yours draws
-- its own from the client event whip_core:death:screenChanged; whip still counts down and reads E held.
Config.DeathScreen = true

-- The gauges' order, left to right, by stat name. A stat not listed (one another resource adds) goes after these.
-- Easiest in /whip > Settings > Config > Stats, where the gauges are dragged into place.
Config.StatOrder = { 'health', 'armour', 'hunger', 'thirst', 'oxygen' }

-- A big drop brings the gauge back on screen while chat or a notification has the capsule: how big, as a
-- percent of the gauge (10 = a tenth). nil = never. Only health and armour have it.
Config.StatHitFlash = { health = 10, armour = 10 }

-- Seconds a player can hold their breath under water, from a full breath, before they start to drown. Up to 45.
Config.OxygenSeconds = 20

-- How much of the breath (out of 100) comes back each second above water. 6 refills it in about 17 seconds.
Config.OxygenRecoverPerSecond = 6

-- Seconds a player under water with no breath left has before they start to drown. 0 drowns them at once.
Config.OxygenGraceSeconds = 1

-- Your own stats. whip's own are in server/stats.lua; an entry here adds one, registered when whip_core starts.
-- Other resources add theirs at runtime with exports.whip_core:RegisterStat.
--   type        'need' or 'custom'
--   default     What a new character starts on
--   min / max   The range this stat lives in
--   persist     true to remember it between sessions
--   decay       Points changed every decayInterval seconds (negative drains it)
--   thresholds  What happens at a value: { value = 10, below = true, stat = 'health', delta = -1 }
--   hud         Its gauge: icon (an SVG path) and color ('#rrggbb'); Config.StatOrder places it
--
--   Config.Stats = {
--       stress = { type = 'need', default = 0, min = 0, max = 100, persist = true,
--                  hud = { icon = 'M12 2a10 10 0 1 0 0 20a10 10 0 1 0 0-20z', color = '#f472b6' } },
--   }
Config.Stats = {}


-- 5. Jobs

-- The ranks every new job starts with. `level` decides who outranks who: a role can only hire, fire or promote
-- someone on a lower level. bankAccess is 'manager' (full control), 'withdraw' or 'view'.
Config.JobDefaultRoles = {
    { name = 'Owner',    level = 100, permissions = { canHire = true, canFire = true, canPromote = true, canDemote = true, canManage = true,  bankAccess = 'manager'  } },
    { name = 'Manager',  level = 50,  permissions = { canHire = true, canFire = true, canPromote = true, canDemote = true, canManage = false, bankAccess = 'withdraw' } },
    { name = 'Employee', level = 1,   permissions = { bankAccess = 'view' } },
}

-- Can a player be on duty at more than one job at the same time?
--   false = yes. Their "current" job is the one they clocked on at most recently.
--   true  = no. Clocking on at a job clocks them off every other one first.
Config.JobDutyOneAtATime = false

-- One character per player account at each job: hiring is refused when another character of the same account
-- already works there (the owner included).
--   true  = refused (the safe default)
--   false = any character may be hired
Config.JobOneCharacterPerAccount = true


-- 6. Time and weather

Config.TimeScale = 1.0   -- 1.0 is GTA's own speed: a full day passes in 48 real minutes

Config.StartTime    = { hour = 12, minute = 0 }   -- Clock when the server boots
Config.StartWeather = 'CLEAR'

-- The weather choices offered in the /w admin menu. Any GTA weather name works.
Config.WeatherTypes = {
    'CLEAR', 'EXTRASUNNY', 'CLOUDS', 'OVERCAST', 'RAIN',
    'CLEARING', 'THUNDER', 'SMOG', 'FOGGY', 'XMAS',
    'SNOWLIGHT', 'BLIZZARD', 'HALLOWEEN', 'NEUTRAL',
}


-- 7. Vehicles

-- The 3D rev dial at the bottom right while in a vehicle, with up to five small gauges around it.
--   the gauges   every vehicle stat with a `hud` block (Config.VehicleStats below, or a script's own). Server-owned,
--                saved with the car and shared with everyone sitting in it.
--   the dial     rpm, speed, gear and four lights, read off the car by the player's own game; never saved or shared.
-- No dial on bicycles or trains. Helicopters and planes get flight instruments, boats read engine power.
-- A player can switch the HUD off with /vehiclehud.
-- The dial goes by the engine, not the body: GTA has no readable rev counter, so the top of the dial is the engine's
-- model in rpmByModel, else rpmElectric for an electric motor, else its kind in rpmByClass.
Config.VehicleHud = {
    -- 'mph' or 'kmh'. The number on the dial and the label under it.
    speedUnit = 'mph',

    -- The top of the dial, in thousands of rpm (2 to 20), for an engine nothing else covers.
    rpmMax = 8,

    -- Where the red zone starts, as a share of the dial. 0.87 is 87%: 7 on an 8 dial.
    redline = 0.87,

    -- The top of the dial for an electric motor, in thousands. Its needle rests at 0.
    rpmElectric = 20,

    -- Where the needle rests when the engine idles, in thousands of rpm: 0.8 is 800, the same for
    -- every engine (an electric motor's rests at 0).
    idleRpm = 0.8,

    -- true: each engine rests at its own idle instead, measured from the game's engine recordings.
    -- Most come out between 1,000 and 1,400, so the needle sits higher than a real car's would.
    idleMeasured = false,

    -- The top of the dial for each kind of engine, in thousands. A top of 3.5 or under counts in halves,
    -- 4 and up in whole thousands. Aircraft and boats have no rev scale.
    rpmByClass = {
        compacts       = 7,
        sedans         = 7,
        suvs           = 6,
        coupes         = 7.5,
        muscle         = 6.5,
        sportsclassics = 6.5,
        sports         = 8,
        super          = 9,
        motorcycles    = 12,     -- sport and dirt bikes rev higher than their recordings do
        offroad        = 6,
        industrial     = 4,
        utility        = 4,
        vans           = 5.5,
        service        = 4,
        emergency      = 6.5,
        military       = 4,
        commercial     = 4,
        openwheel      = 15,
    },

    -- The top of the dial for one model's engine, in thousands, by its spawn name: { sultan = 8.5 }.
    -- Beats everything else, and follows the engine: a car with a sultan engine swapped in gets it.
    rpmByModel = {},

    -- Helicopters and planes get flight instruments in the dial: an attitude indicator, airspeed
    -- and altitude. 'ball' draws the horizon as a 3D ball, 'flat' as a flat disc.
    attitude = 'ball',

    -- If the horizon tips the wrong way when an aircraft banks, set this to true.
    flipBank = false,

    -- Each car's dial wears that car's own GTA dashboard look (its face colour, fonts and needle).
    -- false: every car gets the dial as designed. Cars with no dashboard art in GTA, and every
    -- aircraft, keep the dial as designed either way.
    dashSkins = true,
}

-- Vehicle stats: anything a vehicle can carry a number for (nitrous, engine wear, whatever you invent). Every stat
-- exists on every vehicle, is saved with it, and is sent live to everyone sitting in it.
--   default   What a vehicle starts on
--   min/max   The range it lives in
--   persist   true to remember it between restarts
--   decay     Points changed every decayInterval seconds (negative drains it). Leave the line out to disable.
--   hud       Draws a gauge around the rev dial (up to five). icon is an SVG path, order is its place (lowest first,
--             at the bottom). iconOnly = true: no gauge (the engine shows as the dial's engine light).
-- A script adds its own with exports.whip_core:RegisterVehicleStat('nos', { ... }). Fuel is whip_fuel's.
-- `engine` belongs to whip and cannot be replaced.
Config.VehicleStats = {
    -- Is the engine running? 1 or 0. Not saved: a vehicle comes back switched off.
    engine = {
        default = 0, min = 0, max = 1,
        persist = false,
        hud = {
            icon     = 'M13 3h-2v8h2V3zm4.83 2.17l-1.42 1.42A6.92 6.92 0 0 1 19 12c0 3.87-3.13 7-7 7s-7-3.13-7-7c0-2.27 1.08-4.28 2.76-5.56L6.34 5.02A8.94 8.94 0 0 0 3 12a9 9 0 1 0 14.83-6.83z',
            color    = '#3fb950',
            order    = 90,
            iconOnly = true,   -- no gauge: the rev dial's engine light shows it
        },
    },
}

Config.VehicleStatsTickInterval  = 1    -- Seconds between stat updates
Config.VehicleStatsSaveInterval  = 15   -- Seconds between saving changed stats to the database

-- How often the server writes down where its vehicles are. Only vehicles that have moved are written. This is
-- crash insurance: garaging, despawning and stopping the resource save the position themselves.
Config.VehiclePositionSaveInterval = 30   -- Seconds
Config.VehiclePositionEpsilon      = 2.0  -- Metres of movement before a write is worth doing

-- An owned car remembers the damage it took (engine and body health, torn-off doors, burst tyres) and gets it back
-- when it leaves a garage or after a restart. Dents are not kept. Health is GTA's 0 to 1000 scale: below 400 the
-- engine smokes, at 0 it is dead. Every repair whip has clears it.
Config.VehicleDamage = {
    -- false: every car comes back like new.
    remember = true,

    -- The lowest an engine comes back at, so a wreck never spawns on fire and can still limp to a mechanic.
    engineFloor = 100,
}

-- Fuel, petrol pumps and jerry cans are whip_fuel's: its own config.lua, and /whip > Settings > Fuel.

-- ATMs
--
-- There is no list of locations: client/atm.lua looks for these models near the player and puts a prompt on what it
-- finds, so an MLO that adds a bank works with no edit here.
Config.AtmProps = {
    'prop_atm_01',
    'prop_atm_02',
    'prop_atm_03',
    'prop_fleeca_atm',
}

-- How far out ATMs are looked for, in metres. Larger than the prompt range so a row of ATMs is found as you walk along it.
Config.AtmSearchRange = 30.0

-- How close you must be for the prompt to appear, and to use it.
Config.AtmVisibleRange = 3.0
Config.AtmActiveRange  = 1.4

-- Where the badge sits on a machine, relative to the machine itself:
--     out    metres away from the screen face (negative: an ATM's +Y points into the wall)
--     up     metres toward the top of the machine
--     side   metres across the face, left/right as you look at it
--     yaw    degrees the sign is turned from the machine's facing; the prompt is not drawn from behind, so a wrong yaw hides it
Config.AtmBadgeOffset = {
    -- For an ATM model not listed (an add-on, or one an MLO brings). If one looks wrong, give it a line of its own.
    default         = { side = -0.10, out = -0.22, up = 1.20, yaw = 180.0 },

    prop_atm_01     = { side = -0.05, out = -0.20, up = 1.10, yaw = 180.0 },
    prop_atm_02     = { side = -0.13, out = -0.22, up = 1.23, yaw = 180.0 },
    prop_atm_03     = { side = -0.18, out = -0.21, up = 1.23, yaw = 180.0 },
    prop_fleeca_atm = { side = -0.06, out = -0.24, up = 1.24, yaw = 179.8 },
}

-- The most digits an amount may have. 9 is $999,999,999.
Config.AtmMaxDigits = 9

-- Logs every vehicle storage open (trunk, glovebox, ignition) on both sides, one line per keypress, to find out
-- whether the server refused or the client never sent the request. Off by default: turn it on while finding out why
-- a boot, glovebox or ignition will not open.
Config.LogVehicleStorage = false

Config.VehicleLockRange  = 8.0   -- How far away you can still lock/unlock with L

-- Getting out of a locked car unlocks it. false = it stays locked behind them. Leaving the game in a locked car
-- never unlocks it either way.
Config.UnlockOnExit = true

-- Who sits where. Players change seat with Seats on the F1 wheel (or /seats).
--   NoAutoShuffle   true keeps a passenger in their seat: GTA no longer slides them into an empty driver's seat.
--                   false is GTA's own way.
Config.Seats = {
    NoAutoShuffle = true,
}

-- The server's gate for opening a boot (this + 3.0 metres); the circle you walk up to is tuned separately below.
Config.VehicleTrunkRange = 2.5   -- How close to the back you must stand to open the boot

-- How far you may stray from a vehicle and still move things in its boot or glovebox. Checked on every move.
-- Nothing below VehicleTrunkRange + 3.0 has any effect, because the boot opens at that distance.
Config.VehicleStorageKeepRange = 5.5   -- metres

-- A helmet on a bike. true: GTA puts a helmet on a character when they get on a motorbike. false: they ride in
-- what they have on.
Config.BikeAutoHelmet = false

-- Experimental. A Director car playing a recorded drive is driven by one player's game and others see it a little
-- late and smoothed. true: every other player's game plays the drive itself on a copy of the car, so it is smooth
-- and in the same place on every screen. Hits on a copy are passed on to the real car, but what each player sees of
-- its state can differ a little. A car people can stand on while it moves is never copied.
Config.ExperimentalDriveSync = false

-- World prompts on parts of a car: the circles on the back and front of a car and on its doors.
--   drop         Metres from the panel's hinge to its free edge, the end you lift. whip works out which way the
--                panel hangs per model. Bigger moves the circle further from the hinge.
--   rise         Metres up from the bone. Zero for the boot and bonnet; a door's bone sits at its pivot, below the handle.
--   clearance    Metres out from that face of the car. Negative insets it, and usually is right.
--   range        Metres at which the plain circle fades in. Cannot exceed InteractVisibleRange.
--   activeRange  Metres at which [E] and the label appear and the key works. Measured from the player's feet to the
--                badge: much below 1.0 and the prompt never turns on.
--   scale        How big the circle and its text are drawn, as a multiplier. 1.0 is the same as every other prompt.
Config.VehiclePartPrompts = {
    trunk = {
        enabled     = true,
        drop        = 0.30,
        clearance   = -0.15,
        range       = 1.8,
        activeRange = 1.1,
        scale       = 1.32,
    },
    hood = {
        enabled     = true,
        drop        = 0.30,
        clearance   = -0.15,
        range       = 1.8,
        activeRange = 1.1,
        scale       = 1.32,
    },

    -- All four passenger doors read this one entry. Doors anchor to the car's handle bones, so `drop` and `rise`
    -- only matter for an add-on without them. `inset` places the second circle an open door gets, on its inside:
    -- how far in from the handle (the door's thickness).
    door = {
        enabled     = true,
        drop        = 0.62,
        rise        = 0.18,
        clearance   = 0.0,
        inset       = 0.12,
        range       = 1.8,
        activeRange = 1.1,
        scale       = 1.32,
    },

    -- A motorbike's, bicycle's and boat's one prompt (board, refuel, store), placed by the vehicle's own parts
    -- (/vehpoints shows where). A boat's reaches further, because you board from a jetty or the water.
    bike   = { enabled = true, range = 1.8, activeRange = 1.1, scale = 1.32 },
    bicycle = { enabled = true, range = 1.8, activeRange = 1.1, scale = 1.32 },
    boat    = { enabled = true, range = 3.0, activeRange = 2.2, scale = 1.32 },
}

-- How far out a car gets a point in the interaction grid, so its circle is ready before it should appear.
-- Not the range they draw at: that is each part's own `range`.
Config.VehiclePartPromptScan = 15.0

-- How far a door swings when fully open, in degrees: how much further an open door's circles reach.
Config.VehiclePartOpenAngle = 70.0

-- Which side of a boot panel the hinge is on, guessed from where the hinge sits within the car's height: above this
-- fraction the panel hangs below its hinge (a boot lid), below it stands above (a tailgate).
Config.VehiclePartHingeTopFrac = 0.52

-- Overrides for models the guess gets wrong, keyed by model hash, one line per model and part.
-- Modes: down (hangs below the hinge), up (stands above it), aft (edge behind the hinge, an ordinary door),
-- fore (rear-hinged door), mirror (hinged down one side of an opening).
--     Config.VehiclePartHinges = {
--         [GetHashKey('hellion')] = { trunk = 'up' },
--     }
Config.VehiclePartHinges = {}

-- Which side of a car its fuel goes in, keyed by model hash. Few models mark their filler, so whip guesses a side
-- above a rear wheel. Set the side for a model it guesses wrong; 'rear' puts it on the back. /vehpoints next to the
-- car shows where the nozzle goes.
--     Config.VehicleFillers = {
--         [GetHashKey('sultan')] = { side = 'right' },
--         [GetHashKey('tornado')] = { side = 'rear' },
--     }
Config.VehicleFillers = {}

-- Manufacturer logos on the garage list. The brand comes from the model (html/img/manufacturers/<make>.png). This
-- maps a make whose name and logo file disagree, keyed by the lowercased label. A make with no logo shows a generic
-- car icon and is printed to the console once.
--     Config.VehicleMakeLogos = {
--         ['emperor'] = 'emporer',       -- the game's own file is misspelled
--         ['western'] = 'westernmotorcycle',
--     }
Config.VehicleMakeLogos = {}

-- Keeps NPC traffic locked, so players must lockpick a car that isn't theirs. 0 turns the rule off.
-- Cars whip owns (including a lockpicked one) and cars only your game has are skipped.
Config.NpcVehicleLockRange = 10.0  -- Metres. Cars closer than this get locked if they aren't yours

-- Storage built into every vehicle. These are the defaults: a vehicle, a model or a category can be given its own
-- figures, or no trunk at all, in /whip > Vehicles > Vehicle Adjustments.
Config.VehicleTrunkSlots        = 40
Config.VehicleTrunkMaxWeight    = 200.0
Config.VehicleGloveboxSlots     = 10
Config.VehicleGloveboxMaxWeight = 20.0

-- A motorbike's glovebox is smaller, unless the bike, its model or the Motorcycles category has its own figure.
-- A bicycle has no glovebox and no ignition.
Config.MotorbikeGloveboxSlots   = 1

-- The ignition: the slot a key sits in to start the vehicle. Always one slot; not overridable per vehicle.
Config.VehicleKeySlots     = 1
Config.VehicleKeyMaxWeight = 1.0


-- 8. Garages

-- How close a car must be to a parking bay's middle to be "in" it, for the Store option on its doors.
-- A garage can have any number of bays. Whether a bay is occupied is decided by the car's body overlapping the
-- bay's outline (GaragePositionHelper's length x width). Too small and a crooked park reads as in no bay.
Config.GarageSpotRadius = 3.5

-- How high a bay's 3D prompt floats above the bay's floor, in metres. 1.22 is 4 feet.
Config.GarageSpotPromptHeight = 1.22

-- The outline a driver sees. Prompts are hidden inside a vehicle, so a driver gets the bay laid on the tarmac: a
-- glass slab with a white ring, complete over a blue wash when the car is in the bay. A hint only.
-- Tune it live with /garagehelper, which prints this block back.
Config.GaragePositionHelper = {
    enabled = true,

    -- How far away a bay starts drawing, in metres.
    showRange = 30.0,

    -- On foot, the bays of garages you may use show too, but only this close (metres). 0 = drivers only.
    onFootRange = 10.0,

    -- The bay's size in metres: `length` along the bay's heading, `width` across it. Keep the 2:1 ratio or the
    -- ring and icon go oval (html/interact3d/garagebay.html draws at 1:2). Change both or neither.
    length = 5.20,
    width  = 2.60,

    -- Lift off the road surface, in metres: enough to avoid flicker on tarmac.
    zOffset = 0.02,

    -- How straight counts as parked, in degrees off the bay's line, either way round (nose in or reversed in).
    -- A car sitting diagonally across two bays is not parked. Slightly stricter than the server's own store check.
    alignDeg = 25.0,

    -- Fade in and out, in milliseconds.
    fadeMs = 180,

    -- Only draw for a car this player owns. Off by default: a car the server would store but this client holds
    -- no definition for would get no outline.
    requireStorable = false,

    -- Destroy the browser after this long with nothing drawn (milliseconds); recreated on the next approach.
    idleReleaseMs = 60000,
}

-- How far from the admin a garage's bays may be saved, in metres. The server refuses a save if any new or moved
-- bay, or a new garage's map marker, is further than this from the admin at that moment.
Config.GarageWizardReach = 250.0

-- Seed data, read once on the very first server start, then kept in the database. Manage garages in game with
-- /whip > Garages; editing this list later has no effect on a server that has already run.
Config.Garages = {
    legion_square = {
        name        = 'Public Garage',
        pos         = vector4(819.95, -821.92, 26.18, 123.63),   -- Where the player stands
        spawnPos    = vector4(822.0, -818.0, 26.18, 123.63),     -- Where the car appears
        blipPos     = vector2(819.95, -821.92),                  -- Map marker
        blipSprite  = 357,
        blipColor   = 3,
        markerType  = 1,
        markerSize  = vector3(2.0, 2.0, 0.5),
        markerColor = { r = 0, g = 80, b = 200, a = 180 },
    },
}

-- The fuel stations' map icons are whip_fuel's (its config.lua).


-- 9. Shops

-- Starting shops: none. Set them up in game with /whip > Shops > + New Shop.
-- A shop listed here is made at start-up whenever no shop has its key, then managed in /whip like any other
-- (deleting it there brings it back at the next restart while it is listed). An example, left switched off:
--
--   convenience_1 = {
--       name       = '24/7 Store',
--       mode       = 'npc',                 -- 'npc' (the server's), 'infinite' or 'stocked' (a job's)
--       npcModel   = 'mp_m_shopkeep_01',    -- who stands there; or prop = 'model' for an object
--       pos        = vector4(25.7, -1347.3, 29.5, 271.0),
--       blipSprite = 52,
--       blipColor  = 2,
--       catalog    = { food = 50, drink = 30, bandage = 100 },   -- item key = price in cash
--   },
--
--   settings.categories   the tabs along the top of the shop, in order: { 'Food', 'Drinks' }
--   settings.layout       where each item sits: { water = { category = 'Drinks', order = 1 } }.
--                         Lower `order` comes first; items left out go after, A to Z.
--                         Both can also be set in game by the shop's managers (Edit Shelf).
Config.Shops = {
}

-- How many lines a shopping basket has (1 to 50). A line is one kind of item, as many as stack in a pocket slot.
Config.ShopBasketSlots = 10

-- Shop talk. The shopper's character says what they are doing in a /me bubble everyone nearby sees ("I'll take
-- x3 Water"), and the shopkeeper answers. Each line is picked at random from its list: add, change or remove as you like.
--   {n} how many   {item} the item's name   {total} what a sale cost ("$1,170")   {items} what it bought
--   ({total} and {items} work in paid and keeperPaid only)
-- Nothing is said until the basket has been left alone for batchSeconds, then each item is said once.
-- A shop with a prop instead of a shopkeeper has nobody to answer, so only the shopper talks.
Config.ShopTalk = {
    enabled      = true,   -- false: nobody says anything at shops
    batchSeconds = 1,      -- Seconds with no basket change before the changes are said (each change waits again)
    keeperDelay  = 1.2,    -- Seconds before the shopkeeper answers

    -- What the shopper says
    open = {               -- opening the shop
        'What do you got?',
        'Can I please get a...',
        'Do you have...?',
        'Show me your goods.',
        "Let's see what you have.",
    },
    add = {                -- putting an item in the basket
        'Give me x{n} {item}',
        "I'll take x{n} {item}",
        'I want x{n} {item}',
        'Please give me x{n} {item}',
    },
    change = {             -- a new amount of an item already in the basket; {n} is the new amount
        'Actually, I want x{n} {item} instead',
        'Make that x{n} {item} instead',
        'Change that to x{n} {item}',
        'On second thought, x{n} {item}',
    },
    remove = {             -- taking an item out of the basket altogether; {n} is how many it had
        'I changed my mind on x{n} {item}',
        'Actually, put the x{n} {item} back',
        'Scratch the x{n} {item}',
        'On second thought, no {item}',
    },
    paid = {               -- a sale went through: said as one, what was paid and what for
        'Paid {total} for {items}',
        'Hands over {total} for {items}',
        'Here you go, {total} for {items}',
        "That's {total} for {items}. Done deal",
    },
    broke = {              -- the till said there is not enough money
        'Uh... can I owe you?',
        'Hold on, my card is acting up...',
        'I swear I had it a second ago',
        'Do you take IOUs?',
    },
    leave = {              -- closing the shop without buying anything
        "Nevermind, I'll shop elsewhere",
        'Just looking, thanks',
        'Maybe next time',
        'Nothing for me today',
    },

    -- What the shopkeeper says back
    keeperOpen = {
        'Hey, take a look.',
        'What can I get you?',
        'Welcome in.',
        "What'll it be?",
    },
    keeperAdd = {
        'Sure thing.',
        'Coming right up.',
        'Good choice.',
        'You got it.',
    },
    keeperChange = {
        'No problem, changed.',
        'Sure, I can do that.',
        "Alright, I'll sort that.",
        'Easy enough.',
    },
    keeperRemove = {
        'No worries.',
        "Alright, I'll put it back.",
        'Your call.',
        'Fair enough.',
    },
    keeperPaid = {
        "{total} received. Enjoy your {items}!",
        "That's {total}, all paid. Thanks for buying!",
        'Sold! {items}, all yours.',
        'Pleasure doing business. {total}, paid in full.',
    },
    keeperBroke = {        -- after `broke`: the keeper makes fun of them
        'Come back when you can afford it, cheapskate.',
        'Do I look like a charity to you?',
        "Your wallet's emptier than your head.",
        "No money, no goods. Window shopping's free.",
        'Nice try. Go rob a bank first.',
        "I've seen beggars with more cash than you.",
    },
    keeperLeave = {
        'No problem, come back anytime.',
        'Suit yourself.',
        'Alright, take care.',
    },
}


-- 10. World interaction

Config.InteractVisibleRange = 5.0   -- Distance the circle marker fades in
Config.InteractActiveRange  = 2.0   -- Distance the [E] prompt appears and the action works

-- Which prompt you mean when several are in reach: a cone out of the middle of the screen, half-angle in degrees.
-- Anything outside it cannot be focused; inside it, whatever is nearest dead centre wins. Range still decides what is
-- reachable. Below about 20 you must look almost exactly at a thing; above about 60 the cone stops discriminating.
Config.InteractFocusCone = 40.0

-- The same for things you walk up to rather than aim at (focusMode = 'near', used by doors): a generous cone, so
-- something directly behind you is still not openable. The weight is how far toward pure proximity it goes: 1.0
-- ignores aim entirely; the remainder only decides between two doors at almost the same distance.
Config.InteractFocusConeNear   = 100.0
Config.InteractFocusNearWeight = 0.85

-- Default weights of the scoring helper the object viewer uses. They should add up to 1.0.
Config.InteractDistWeight   = 0.6
Config.InteractCameraWeight = 0.4

-- How the prompt is drawn:
--   'nui'    the browser moves a div to the projected point; always a frame or two behind, and never hidden by a wall
--   'world'  textured triangles in world space, projected in the same frame as the camera, hidden by walls
-- Doors only exist in 'world'. Swap live with /interactrenderer to compare.
Config.InteractRenderer = 'world'

-- Settings for the 'world' renderer only.
Config.Interact3D = {
    -- The badge's height on screen, in pixels, at InteractActiveRange; its size in metres follows from the real FOV
    -- and resolution. Past that range it shrinks like any object. /i3d <px> retunes it live. This is the baseline
    -- for every prompt: to enlarge one family (vehicles, say) use the per-point `scale` instead.
    badgePx = 68,

    -- The label row's height on screen, same units and distance. The width follows the atlas row's proportions.
    labelPx = 98,

    -- State the badge size in metres outright, for hand-tuning. nil = work it out.
    badgeMetres = nil,

    -- Space between badge and label, as a fraction of badge height.
    gap = 0.35,

    -- How long every transition takes, in milliseconds (fading in and out, moving up and down the stack, the
    -- crossfade between prompts). About 100 is the floor; much above 300 and the prompt lags behind the camera.
    fadeMs = 100,

    -- How many of the focused prompt's option labels are painted ready at once. A prompt can have any number of
    -- options; the rows roll along as you scroll. More rows only paint further ahead; 8 is plenty.
    labelRows = 8,

    -- A prompt registered with a `heading` is a sign: true hides its back, false draws it from behind, mirrored.
    cullBehind = true,

    -- How long the answer-flash lasts, in milliseconds. Doors use it: green for an unlock, red for a lock, amber for
    -- a refusal. It blinks twice, so it needs most of a second.
    flashMs = 900,

    -- How far the prompt is pulled toward you, in metres, so the object it labels does not cover it. Raise it if
    -- prompts clip into big props; lower it if one pokes through something it should be behind. Capped at half the
    -- distance to you.
    depthBias = 0.30,

    -- Multi-choice: a prompt with more than one option draws them as a column, the selected one at the anchor.
    -- Gap between stacked circles, as a fraction of a circle's height.
    stackGap = 0.25,

    -- How visible an unselected option is, as a fraction of the prompt's opacity.
    stackAlpha = 0.45,

    -- The picture above the text (an option's `image`, shown for the highlighted one): its height as a multiple of
    -- the label's, width from the picture's 16:9. Past about 5 it covers what the prompt is attached to.
    previewScale = 3.4,

    -- The prompt's shape: 'keycap' is a rounded square (the default), 'classic' is a round disc. Players can pick
    -- their own in the pause menu (Server Settings > Map & HUD > Prompt shape).
    theme = 'keycap',

    -- Dark prompts: black with a white outline and symbol, black words with a white outline. Players can switch it
    -- in the pause menu (Server Settings > Map & HUD > Dark prompts).
    dark = false,

    -- Styles: a set of looks a prompt can wear. Everything above is the 'default' style; another style changes
    -- only what it names, the rest comes from 'default' (or its `base`). A prompt asks for one by name
    -- (AddAction({ ..., style = 'subtle' })) or a family of prompts wears one through groupStyles below.
    -- What a style can set (all optional):
    --   badgeScale = 1.0      the circle's size (1.2 is a fifth bigger)
    --   labelScale = 1.0      the label's size
    --   opacity = { seen = 0.35, inReach = 0.85, focused = 1.0 }
    --                         how visible it is: in sight but too far / close enough to use / the one E acts on
    --   tint = '#ffffff'      the circle's colour ('#ffc850' amber)
    --   labelTint = '#ffffff' the label's colour
    --   fadeMs = 100          how long fading in and out takes, in milliseconds
    --   crossfadeMs = 100     how long the ring takes to turn into the key
    --   slideMs = 100         how long the option stack takes to slide
    --   flash = 'blink'       an answer flash: 'blink' twice, or 'fade' once
    --   flashMs = 900         how long that flash lasts
    --   gap, stackGap, stackAlpha, previewScale, cullBehind   as above, for this style only
    --   easing = 'smooth'     'smooth', 'linear', 'out' (fast, then settles), 'inOut', 'back' (small overshoot);
    --                         fadeEasing, crossfadeEasing, slideEasing set one movement each
    --   appear = 'fade'       how it arrives: 'fade', 'pop' (grows in), 'slide' (rises into place) or 'none';
    --                         appearMs = 220 is how long that takes
    --   focus = 'none'        when it becomes the one E acts on: 'none', 'pop' or 'pulse'
    --   idle = 'none'         while it is not: 'none', 'pulse' or 'bob' (floats)
    --   press = 'none'        when it is used: 'none' or 'pop'
    --   base = 'subtle'       start from another style
    -- A field set in `default` changes every prompt that does not say otherwise.
    styles = {
        -- Smaller, and nothing at all until you are close enough to use it.
        subtle = {
            badgeScale = 0.85,
            labelScale = 0.9,
            opacity = { seen = 0.0, inReach = 0.6, focused = 0.95 },
        },
        -- Grows in, pops when it becomes the one E acts on and again when it is used.
        lively = {
            appear = 'pop',
            focus = 'pop',
            press = 'pop',
            easing = 'out',
        },
    },

    -- Which style each family of whip's own prompts wears, by the group it was made in. A prompt that names its
    -- own style keeps it. The groups:
    --   doors          door locks              vehicles       car doors, bonnets, boots, seats
    --   ground_items   things on the ground    garages        garage bays
    --   containers     stashes and boxes       properties     property doors
    --   conversation   an NPC's answers        atm            cash machines
    --   actions        every AddAction prompt and every AddPoint (other resources' prompts: whip_fuel's pumps)
    -- For example `ground_items = 'subtle'`.
    groupStyles = {
    },
}

-- The hand press (car doors, boot, bonnet, ATMs, fuel pumps, any prompt marked `press`): when the player uses one,
-- it happens at once and their hand reaches out towards it and comes straight back. Only how it looks: it never
-- moves or turns the player or takes control from them. Picking things up off the ground is not a press. Also in
-- /whip > Config.
Config.InteractPress = {
    enabled = true,       -- false: no presses; the doors, ATMs, pumps... happen at once on E (ground pickups still grab)
    maxDistance = 2.5,    -- further than this from the player, metres: no press, it just happens
    -- The hand keeps reaching for the thing while the player moves, as long as it stays in a natural range in front
    -- or to the side; past that it lets go. false: the press plays as made.
    followHand = true,
}

Config.DoorInteractRange = 3.0   -- How close to stand to lock or unlock a door

-- Where the circle sits on a door: one prompt per face, anchored to the door, derived from the model's bounding box
-- (an ordinary hinged door has its origin at the hinge).
--   DoorHandleAlong   how far toward the free edge, as a fraction of the door's width (1.0 is the very edge)
--   DoorHandleHeight  metres up from the bottom of the model, not from its origin
Config.DoorHandleAlong  = 0.85
Config.DoorHandleHeight = 1.05

-- Overrides for doors the derivation gets wrong (double gates, shutters, anything whose origin is not its hinge),
-- keyed by model hash. x runs along the door from its origin, y is half the panel thickness (the sign is mirrored
-- onto both faces), z is height from the origin.
--     Config.DoorPromptOffsets = {
--         [GetHashKey('v_ilev_ph_gendoor004')] = { x = 0.5, y = 0.06, z = 1.1 },
--     }
Config.DoorPromptOffsets = {}

-- Diagnostics

-- Prints every refused secure event and every dropped callback to the server console. Successes are never printed.
-- Without it a refused event vanishes with no line anywhere. The callback side prints one line per player per five
-- seconds, with a count.
Config.LogSecureRejections = true

-- Properties

-- Houses and apartments. Set them up in /whip > Properties; these are the server-wide defaults.

-- The most furniture one property may hold, unless its own settings say otherwise.
Config.PropertyMaxObjects = 150

-- How close someone must stand for the owner to hand them a key. Keys are given in person.
Config.PropertyKeyGrantRange = 5.0

-- How close you must be for a property's sign to appear, in metres.
Config.PropertyStreamRange = 60.0

-- How close you must be to a property's walls for its furniture to appear, in metres (being inside
-- counts). It goes again when you are 2 m further away. 0 = only while you are inside.
Config.PropertyFurnitureDistance = 20.0

-- How many properties show their furniture at once: the one you are in, then the nearest.
-- In an apartment tower several flats can be that close, and this stops all of them being furnished.
Config.PropertyFurnitureRooms = 4

-- How far away an admin can aim a property's sign from, when placing it.
Config.PropertySignPlaceRange = 12.0

-- Sign posts: the outside sign can stand on a for-sale sign post in the garden instead of floating (/whip >
-- Properties > Signs step > Put up a sign post). It shows while the property is for sale. The listing (name, garage
-- bays, rooms, price) is printed on the board's blank panel, with a "More..." control under it.
-- Each line is a prop and its board's blank panel: where its middle is, in metres from the bottom of the prop
-- (x right, y forward, z up), and how wide (w) and tall (h) it is. The panel's printed side must face the prop's back (-y).
--   ink, accent   the listing's colours: its words, and the line under its price
--   back = true   the board is printed on its back too
Config.PropertySignPosts = {
    { model = 'whip_forsale_timber',  label = 'Dynasty 8 (timber frame)',
      panel = { x = -0.2792, y = -0.0072, z = 1.2756, w = 1.2795, h = 0.7132 },
      ink = '#11461f', accent = '#e9b33a' },
    { model = 'whip_forsale_hanging', label = 'Lenny Avery (hanging board)',
      panel = { x = 0.6582, y = -0.0107, z = 1.5160, w = 1.0544, h = 0.5756 },
      ink = '#33256e', accent = '#e39a3b', back = true },
}

-- Stashes: furniture that becomes a stash of its property when placed; only the owner and keyholders can open it.
-- Each line is   ['model'] = { label = 'what players see', slots = how many slots, weight = most kg }
-- The model must be in the furnisher's catalog. Leave this empty for no stashes. A stash with anything in it
-- cannot be removed (or Cleared) until it is emptied.
Config.PropertyStashProps = {
    ['v_res_tre_wardrobe']    = { label = 'Wardrobe',          slots = 40, weight = 150.0 },
    ['v_res_mdchest']         = { label = 'Chest of drawers',  slots = 25, weight = 80.0 },
    ['v_res_tre_storageunit'] = { label = 'Storage unit',      slots = 30, weight = 120.0 },
    ['prop_ld_int_safe_01']   = { label = 'Safe',              slots = 10, weight = 40.0 },
}

-- The most stashes one property may have.
Config.PropertyStashLimit = 6

-- Furnisher: the editor a property's owner uses to place furniture.

-- A picked prop appears on whatever you are looking at if it is this close (metres); further away it appears 3 m
-- in front of you.
Config.FurnishPlaceRange = 8.0

-- Snap steps: hold Shift while dragging a marker to snap. G (or the step button) goes to the next step in each
-- list; the first entry is the one a fresh session starts on.
Config.FurnishMoveSteps = { 0.05, 0.25, 1.0 }   -- metres per snap, dragging an arrow
Config.FurnishTurnSteps = { 15.0, 45.0, 1.0 }   -- degrees per snap, dragging a ring

-- The most props one scene prop set may hold (a Director Show Prop group, or a script's ShowPropSet). Each prop is
-- about 100 bytes sent to every player when the set appears, so 256 is about 25 KB. Much higher makes a big message.
Config.PropSetMaxProps = 256

-- Profile pictures for lore characters and players' phones (Settings > My card). Only a link starting with one of
-- these is accepted, and every player's game loads the picture from that site, so keep it to an image host you
-- trust. To accept only your own account's pictures, use your account's address, such as
-- 'https://r2.fivemanage.com/abc123/'.
Config.LorePictureLinks = { 'https://r2.fivemanage.com/' }

-- A lore character can speak out loud in the world from its NPC (Director > Lore characters > Voice lines: a
-- recording's link, an .mp3, for each line). It is heard like a player's voice by the players near it. Needs
-- whip_voice and its voice bot running. Only links starting with one of Links are taken.
Config.LoreVoice = {
    Enabled = true,
    Links = { 'https://r2.fivemanage.com/' },
    Range = 15,              -- metres its voice carries
    GreetRange = 4,          -- a player walking this close hears its Hello line
    ByeRange = 10,           -- a player it said hello to walking this far away hears its Goodbye line
    GreetAgainMinutes = 3,   -- after this long (and having walked off), a player is greeted again
    ReactAgainSeconds = 6,   -- the same reaction again only after this long
    Gestures = true,         -- it moves its hands as it talks (GTA's own talking gestures, without GTA's voice)
}

-- Prop catalog: every prop in the game is placeable in the furnisher, filed under the categories below. To add more
-- to the catalog, list them in Config.PropSeeds, or look at a prop in game and type /prop add <category>. To take
-- one out, place it, look at it and type /prop remove. Pictures come from whip_media_props (img/props/<model>.webp).
-- Categories are listed in the order written here. Clusters are the rail's top row: pick a group and only that
-- group's categories show. A category with no cluster, or an unknown one, falls into the first.
Config.PropClusters = {
    { key = 'furniture', label = 'Furniture', glyph = 'sofa' },
    { key = 'fittings',  label = 'Fittings',  glyph = 'tap' },
    { key = 'dressing',  label = 'Dressing',  glyph = 'plant' },
    { key = 'scenes',    label = 'Scenes',    glyph = 'barrier' },   -- crates, barriers, loot: the Director's too
    { key = 'everyday',  label = 'Everyday',  glyph = 'food' },
    { key = 'leisure',   label = 'Leisure',   glyph = 'ball' },
    { key = 'outside',   label = 'Outside',   glyph = 'tree' },
}

Config.PropCategories = {
    { key = 'seating',   label = 'Seating',     cluster = 'furniture', glyph = 'sofa' },
    { key = 'tables',    label = 'Tables',      cluster = 'furniture', glyph = 'table' },
    { key = 'storage',   label = 'Storage',     cluster = 'furniture', glyph = 'cabinet' },
    { key = 'beds',      label = 'Beds',        cluster = 'furniture', glyph = 'bed' },
    { key = 'kitchen',   label = 'Kitchen',     cluster = 'fittings',  glyph = 'pan' },
    { key = 'bathroom',  label = 'Bathroom',    cluster = 'fittings',  glyph = 'tap' },
    { key = 'lighting',  label = 'Lighting',    cluster = 'fittings',  glyph = 'lamp' },
    { key = 'electrics', label = 'Electronics', cluster = 'fittings',  glyph = 'tv' },
    { key = 'decor',     label = 'Decor',       cluster = 'dressing',  glyph = 'frame' },
    { key = 'plants',    label = 'Plants',      cluster = 'dressing',  glyph = 'plant' },
    { key = 'rugs',      label = 'Rugs',        cluster = 'dressing',  glyph = 'rug' },
    { key = 'misc',      label = 'Misc',        cluster = 'dressing',  glyph = 'box' },
    { key = 'crates',    label = 'Crates & barrels',  cluster = 'scenes', glyph = 'box' },
    { key = 'barriers',  label = 'Barriers & street', cluster = 'scenes', glyph = 'barrier' },
    { key = 'loot',      label = 'Loot & cash',       cluster = 'scenes', glyph = 'cash' },
    { key = 'bags',      label = 'Bags & cases',      cluster = 'scenes', glyph = 'bag' },
    { key = 'tools',     label = 'Tools & tech',      cluster = 'scenes', glyph = 'wrench' },
    { key = 'camp',      label = 'Camp',              cluster = 'scenes', glyph = 'tent' },
    { key = 'firearms',  label = 'Firearms & ammo',   cluster = 'scenes', glyph = 'gun' },
    { key = 'drugs',     label = 'Drugs',             cluster = 'scenes', glyph = 'pill' },
    { key = 'food',      label = 'Food & drink',  cluster = 'everyday', glyph = 'food' },
    { key = 'office',    label = 'Office',        cluster = 'everyday', glyph = 'briefcase' },
    { key = 'clothing',  label = 'Clothing',      cluster = 'everyday', glyph = 'shirt' },
    { key = 'medical',   label = 'Medical',       cluster = 'everyday', glyph = 'medkit' },
    { key = 'rubbish',   label = 'Rubbish',       cluster = 'everyday', glyph = 'bin' },
    { key = 'games',     label = 'Games',         cluster = 'leisure',  glyph = 'dice' },
    { key = 'sports',    label = 'Sports',        cluster = 'leisure',  glyph = 'ball' },
    { key = 'music',     label = 'Music',         cluster = 'leisure',  glyph = 'note' },
    { key = 'stunt',     label = 'Stunt',         cluster = 'leisure',  glyph = 'ramp' },
    { key = 'signs',     label = 'Signs',         cluster = 'outside',  glyph = 'sign' },
    { key = 'doors',     label = 'Doors & gates', cluster = 'outside',  glyph = 'door' },
    { key = 'structures', label = 'Structures',   cluster = 'outside',  glyph = 'building' },
    { key = 'vehicle',   label = 'Vehicle parts', cluster = 'outside',  glyph = 'wheel' },
    { key = 'nature',    label = 'Nature',        cluster = 'outside',  glyph = 'tree' },
    { key = 'animals',   label = 'Animals',       cluster = 'outside',  glyph = 'paw' },
}

-- Your own props, on top of the ones whip ships with. One line each: the model name, then its category (a key
-- above), or the category and the name the furnisher shows:
--     ['prop_wall_vent_02'] = 'decor',
--     ['prop_wall_vent_02'] = { category = 'decor', name = 'Air vent' },
-- Each is added the first time the server sees it, so a prop you later /prop remove stays out. A model the game
-- does not have is hidden, not an error.
Config.PropSeeds = {
}

Config.ShopInteractRange = 2.5     -- How close to stand to use a shop's prompt (Browse, Manage Stock)
Config.ShopStreamRange   = 100.0   -- How far away a shop's prop still appears (a shopkeeper is an NPC)

-- How far a player's network range reaches (metres). Messages about something happening at a place (a chat line, a
-- throw, a car's new look) go only to players this close. 424 is what a player's game has in scope. Chat's /global
-- still reaches everyone.
Config.NetworkRange      = 424.0

-- Items dropped on the ground
Config.DefaultGroundProp    = 'prop_cs_cardbox_01'   -- Model for items with no prop of their own
Config.GroundItemPickupRange = 2.0     -- How close before dropped items show in the Ground panel
Config.GroundItemStreamRange = 100.0   -- How far away dropped items still appear in the world (door lock changes ride this too: keep it 50 or more)
Config.PlaceItemRange        = 10.5    -- How far away you can set an item down (metres, from the camera)

-- How the player moves while holding an item out to give it: `walk` is a /walk name ('trash'), or nil for their own
-- walk; `speed` is 'jog' (no sprint), 'walk' (no running) or nil (as fast as they like). A resource can set its own
-- with SetGiveModeStyle. One item can keep the player's own walk: "Allow player walk animation" on its /whip Items page.
Config.GiveModeStyle = { walk = 'trash', speed = 'jog' }

-- A thrown item knocks the person it hits over, and bounces off. Not someone in a no-PvP zone or with god mode on;
-- once up, nobody can be knocked down again for a second and a half.
Config.ThrowKnockdown = {
    Enabled   = true,
    MinSpeed  = 8.0,    -- m/s it must still be flying at when it hits (it leaves the hand at 18): not one that has bounced or rolls
    RagdollMs = 2500,   -- how long they stay down (milliseconds)
    Npcs      = true,   -- people of the street fall too (false: players only)
}

Config.ActivityLogDays = 30    -- How long player/item timelines are kept before pruning at boot

-- Player Manager: two game clients on one PC share a license, so whip sees one account with two characters in.
-- true: the Player Manager warns too ("2 SESSIONS" on the rows, "ALSO IN: name #id" on the player's page).
-- false: no warning.
Config.PlayerManagerSessionWarn = false

Config.ContainerInteractRange = 2.5     -- How close to stand to open a stash or other container
Config.ContainerStreamRange   = 100.0   -- How far away its prop still appears
-- Where a stash's E prompt sits on its prop, for a player who has not picked their own (pause menu, Settings,
-- Server, Map & HUD, Stash prompt):
--   'middle'  over the middle of the prop, seen through it from every side
--   'side'    flat on the middle of the side you are nearest, like a sign at eye level; snaps to another side as you walk round
--   'face'    the same sign sliding round the prop with you, wrapping round corners
Config.ContainerPrompt        = 'face'

-- Used for any stash that does not specify its own.
Config.ContainerDefaultSlots  = 20
Config.ContainerDefaultWeight = 100.0
Config.ContainerDefaultProp   = 'prop_cs_cardbox_01'

-- Emotes (/e, /walk, /mood); the emotes themselves are in shared/emote_list.lua. The emote menu opens from the F1
-- wheel and /emotes.
Config.Emotes = {
    cancelKey  = 'X',     -- Stops the current emote
    placeRange = 6.0,     -- How far away you can place an emote (metres)
}

-- /me bubbles: "/me eats an apple" shows in a capsule above the player's head for everyone nearby.
Config.Bubbles = {
    range      = 20.0,   -- Metres: players further away do not see it
    duration   = 5000,   -- How long it stays up (ms) before folding away
    maxLength  = 120,    -- Characters (two lines); a longer /me is cut and the player told
    maxStack   = 3,      -- Bubbles one player can have up at once; a new one pushes the oldest off
    height     = 0.3,    -- Metres above the head where the line starts
    size       = 1.0,    -- 1.5 is half as big again
    maxPlayers = 6,      -- Players with bubbles up on one screen at once (more pushes the oldest off)
}

-- Conversations (the dialog capsule): what an NPC says and your answers float beside it and swing round as you move.
Config.Conversations = {
    size   = 1.0,    -- Width in metres (it is half as tall)
    height = 0.375,  -- Metres above the NPC's hips, where its middle hangs (negative = lower). 0.375 sits it
                     -- from the chest up to the shoulders
    minSizeFrom = 4.0, -- Further than this many metres from your camera, it grows so it never looks smaller
                       -- than it does from here (0 = it never grows)
    maxGrow = 1.75,  -- ...but never more than this many times its size
    margin = 0.12,   -- Metres between the NPC and the capsule
    swing  = 10.0,   -- How quickly it swings round to your side (higher = snappier)
    range  = 6.0,    -- Metres: walk further than this from the NPC and the conversation ends

    -- What other players see on an NPC's Talk while it cannot be talked to (pressing it only shows this).
    -- Keep each under about 40 letters: longer ones are set smaller to fit the prompt.
    speakingText = 'Someone is speaking with this person.',   -- while someone else is talking to it
    busyText     = "They're busy right now.",                 -- while its Talk is switched off (a job is under way)

    -- Players standing nearby see the conversation as /me bubbles (the NPC's line, then the chosen answer). false = not shown.
    watcherBubbles = true,
    npcLines       = 4,   -- 1 to 4: lines an NPC's conversation bubble may wrap to

    -- A Director talk card that gives up when nobody answers: what the NPC says over its head half way to giving
    -- up and as it does. '' = says nothing then.
    noAnswerHalfText = 'Are you gonna respond? If not, get lost.',
    noAnswerText     = "I don't talk to mutes, get lost.",
}

-- Skill checks (lockpicks, hotwiring, anything a script asks for): a ring with a dot in the middle. Part of the ring
-- lights up; the mouse (or a controller's right stick) pushes the dot onto it and holds it until it fills, then again
-- on a smaller part elsewhere. Touching the ring outside the lit part, or running out of time (the thin outer line
-- is the clock), fails the check.
--   pieces     How many directions the ring is cut into; the lit part is centred on one of them.
--   parts      How many parts the player must fill.
--   widest     How wide the first part is, in pieces: on a 4-piece ring 3 is three quarters, 2 a half.
--   narrowest  How wide the last part is, in pieces; the parts between narrow evenly.
--   msPerPart  The time allowed for each part, in milliseconds. The clock is this times the number of parts.
--              A skilled player needs about 0.5 s a part; raise it to make a check kinder.
-- A script picks one by name: exports.whip_core:SkillCheck('hard'). Add your own name here and scripts can use it.
Config.SkillCheckHoldMs      = 196    -- How long the dot must stay on the lit part to fill it (ms)
Config.SkillCheckMouseSpeed  = 1.0    -- How fast the mouse moves the dot: 2.0 is twice as fast.
                                      -- The player's own GTA mouse sensitivity counts too.

Config.SkillCheckDifficulty = {
    -- 6 parts, three quarters down to a quarter: 3.9 s
    easy   = { pieces = 4,  parts = 6,  widest = 3, narrowest = 1, msPerPart = 650 },
    -- 12 parts, a half down to an eighth: 7.2 s
    medium = { pieces = 8,  parts = 12, widest = 4, narrowest = 1, msPerPart = 600 },
    -- 16 parts, a quarter down to a sixteenth: 9.2 s
    hard   = { pieces = 16, parts = 16, widest = 4, narrowest = 1, msPerPart = 575 },
}

-- The game whip's own lockpicks play (car and door lockpicks at medium, the ignition hack at hard): 'ring', the
-- check above, or the name of a game another resource adds (Whip.skillCheckGame). If that resource is not
-- running, the ring is played and the console says so.
Config.LockpickGame = 'ring'


-- 11. Character select screen
--
-- The character screen is in the world. Each character has a hero shot: their own spot, camera, time of day,
-- weather and pose, and the cards along the bottom of the screen travel between them. Slots fill in order; an empty
-- slot is still a place. Each slot is self-contained: moving a shot means editing that one entry.

-- The landing page: the first thing a player sees after the loading screen, a camera shot with the whip logo and
-- "Press any button to continue". Only when joining; /logout and a whip_core restart go straight to the character screen.
Config.Landing = {
    enabled = true,   -- false = straight to the character screen

    -- Where the shot is taken from. `rot` is pitch, roll, yaw.
    camera = {
        pos = vector3(-2348.61, 824.75, 307.30),
        rot = vector3(-9.44, 0.00, -123.19),
        fov = 42.0,
    },

    -- The words under the logo.
    prompt = 'Press any button to continue',

    -- The shot's sky and clock, the same shape as the character screen's looks. Without a look the sky could change
    -- while the player watches. look = nil to leave the sky alone.
    look = { weather = 'EXTRASUNNY', hour = 5, minute = 17, frozen = true, priority = 1000 },

    fadeIn  = 800,   -- ms from black up to the shot
    fadeOut = 500,   -- ms down to black after a button is pressed

    -- The longest the game gets to load the view before it is shown, in ms. It shows as soon as the view is ready,
    -- so this only matters on a slow PC.
    streamMs = 6000,
}

-- The character screen's fades, in ms. fadeOut: to black before the screen is built. fadeIn: back up once a
-- character stands in the world. fadeOnPlay: to black after Play. fadeOnCreate: to black after a new character's
-- details (the slowest, on purpose). Read as whip_core starts.
Config.CharSelectFades = { fadeOut = 500, fadeIn = 800, fadeOnPlay = 600, fadeOnCreate = 900 }

Config.CharSelect = {
    -- The hero shots: one per character place, in order. Easiest made in game: /whip > Settings > Config >
    -- Character screen > Edit in world. There can be as many as Config.MaxCharacters. A place with no shot of its
    -- own (past the end of this list, or `false`) shows one of the shots that exists, in turn. Shot 1 must exist.
    --   camera   where the shot is taken from. `rot` is pitch, roll, yaw.
    --   pos      where the character stands. vector4: the w is their heading.
    --   scenario a GTA ambient animation name, OR
    --   anim     { dict = ..., clip = ... } for an exact animation, OR
    --   emote    the name after /e, e.g. 'smoke6': exactly what that emote plays, props included.
    --            Use one of the three. A scenario name that does not exist fails silently (the character just stands).
    --   look     this shot's sky and clock. Omit it and the sky is left as the server has it.
    --   props    optional. The scene's props: { model = 'prop_chair_01a', x, y, z, rx, ry, rz }, at most 60.
    slots = {
        -- 1. Leaning forward on a bartop, early evening.
        {
            camera = {
                pos = vector3(-374.47, 25.87, 52.56),
                rot = vector3(-2.26, 0.00, 120.27),
                fov = 33.0,
            },
            pos  = vector4(-375.72, 24.73, 52.11, 353.28),
            anim = { dict = 'anim@amb@nightclub@lazlow@ig1_vip@', clip = 'clubvip_base_laz' },
            look = { weather = 'EXTRASUNNY', hour = 19, minute = 0, frozen = true, priority = 1000 },
        },

        -- 2. A cigarette, alone. Half six in the morning.
        {
            camera = {
                pos = vector3(57.73, 530.67, 175.70),
                rot = vector3(5.47, 0.00, -94.17),
                fov = 30.0,
            },
            pos   = vector4(58.92, 530.37, 175.32, 71.00),
            emote = 'smoke6',
            look  = { weather = 'EXTRASUNNY', hour = 6, minute = 30, frozen = true, priority = 1000 },
        },

        -- 3. Sat on a chair. Midnight.
        {
            camera = {
                pos = vector3(-1079.24, -1678.58, 4.53),
                rot = vector3(2.33, 0.00, 126.95),
                fov = 39.0,
            },
            pos   = vector4(-1079.89, -1678.95, 4.58, 286.10),
            emote = 'sitchair',
            look  = { weather = 'EXTRASUNNY', hour = 0, minute = 0, frozen = true, priority = 1000 },
        },

        -- 4. Leaning back, entirely at ease. Early afternoon. Wants a wall behind the mark.
        {
            camera = {
                pos = vector3(-134.35, 869.83, 233.16),
                rot = vector3(2.42, 0.00, 87.02),
                fov = 27.0,
            },
            pos  = vector4(-135.48, 869.88, 232.69, 295.77),
            anim = { dict = 'amb@world_human_leaning@male@wall@back@foot_up@idle_a', clip = 'idle_a' },
            look = { weather = 'EXTRASUNNY', hour = 13, minute = 0, frozen = true, priority = 1000 },
        },
    },

    -- Hide pedestrians and traffic while choosing, so nobody wanders through the shot. false shows the city alive behind them.
    quietBucket = true,

    -- Build every character in every shot before the screen shows, behind the black. false builds each on its first
    -- visit instead (still hidden, but that first trip is slower).
    preloadShots = true,

    -- The spawn picker. After Play, a map comes down and the player picks where to arrive: where they last were, a
    -- spawn point (Config.SpawnPoints) or a property they own or have a key to. false: Play fades to black and they
    -- arrive where they left. A dead character, a new one and a player whose browser cannot draw the map always get the fade.
    spawnPicker = true,
}

-- The spawn picker's places, beside where they last were and their properties. Each needs its own `id` (letters,
-- digits, - and _); `label` is its name in the list, `pos` the place and the way they face.
-- Easiest made in game: /whip > Settings > Config > Character screen, Here.
Config.SpawnPoints = {
    { id = 'legion',  label = 'Legion Square', pos = vector4(195.17, -933.77, 29.70, 144.50) },
    { id = 'airport', label = 'LSIA',          pos = vector4(-1037.58, -2737.69, 20.17, 327.00) },
    { id = 'paleto',  label = 'Paleto Bay',    pos = vector4(80.35, 6424.12, 31.67, 45.50) },
}


-- 11b. Character creator
--
-- A new character is made on a private mark, not at the spawn point, in the routing bucket they had on the
-- character screen, so the world never sees a half-finished person. The handover happens behind a black screen; on
-- save they are teleported to Config.DefaultSpawn.
Config.Creator = {
    -- The mark itself: somewhere quiet with clean sightlines.
    spawn = vector4(-1024.39, 656.11, 156.07, 135.34),

    -- The pose a new character holds while the creator is open: an /e name from shared/emote_list.lua, or false to
    -- stand as the game leaves them. It plays even where /e would be refused, and stops when the creator closes.
    -- An emote with props plays without them.
    pose = 'idle6',

    -- The sky a new character is made under: this player's alone, back to the server's once Save is pressed. Same
    -- shape as a hero shot's look (Config.CharSelect.slots). Frozen, so the light on the face does not change.
    look = {
        weather  = 'CLEAR',
        hour     = 20,
        minute   = 0,
        frozen   = true,
        priority = 1000,
    },

    -- The fades either side of the creator closing, in milliseconds: slow, because arriving in the world for the
    -- first time ends the whole login.
    fadeOut = 800,   -- down, when Save is pressed
    fadeIn  = 800,   -- up, once they are standing at the spawn point

    -- How long to hold the black on the way out, after the creator's camera is home and the character is placed at
    -- the spawn point, before the picture returns (milliseconds).
    arriveHoldMs = 500,

    -- How long to hold the black after the creator is up, before letting the picture back in, so the camera move
    -- onto the ped is over before anyone sees it (milliseconds).
    settleMs = 1200,

    -- The editor's Outfits tab: the most outfits one character keeps (1 to 100). An outfit is the clothes and
    -- accessories they had on, saved by name; about half a kilobyte of the character's save each.
    maxOutfits = 20,
}


-- 11c. Arrival scenes
--
-- What the player sees as the picture comes back after picking a character: one of GTA's own character-switch
-- scenes (animation and camera move, as in story mode) plays where they are. When it ends they have the controls and
-- the camera eases back behind them when they move. In a car it cuts straight back.
-- Left in a car: if that car is still within `vehicleRange` metres of where they left, they come back in it, in the
-- seat they had or the first free one (`inVehicle`). A car that is gone, too far or full: on foot where they left.
-- Left on a motorbike: it is stood back up and they arrive beside it (`onBike`). Left on foot with a car of theirs
-- within `nearCarRange` metres: they arrive at it (`nearCar`).
-- No scene for a brand new character, for someone who left dead, or in water. On foot, a scene whose walk would go
-- through a wall is skipped for another; if none fits the picture just comes back. Inside a building only the lines
-- marked `indoors` play.
-- The four lists are also on /whip > Settings > Joining: Add scenes picks from every switch scene the game has.
-- A line: `dict` and `clip` are the game's animation, `cam` the camera move that goes with it. Optional:
--   from = 0.5          start half way through
--   to = 0.9            end there instead of at the last frame
--   vehicleClip = '..'  made with a vehicle in it, lined up with the real one
--   getsIn = true       it ends with them in the seat
--   indoors = true      fine inside a building (little walking, a camera that fits a room)
--   prop = { .. }       what goes in the hand; left out, the game's own is used (client/arrival_list.lua)
Config.ArrivalScenes = {
    enabled = true,          -- false = the picture just fades up
    vehicleRange = 400.0,    -- metres: how far the car may be from where they left
    nearCarRange = 25.0,     -- metres: how near a car of theirs must be for `nearCar`

    -- On foot: one is picked at random each time. Remove a line to drop a scene.
    onFoot = {
        { dict = 'switch@franklin@chopshop', clip = 'checkshoe', cam = 'checkshoe_cam', indoors = true },   -- Franklin checks his shoe
        { dict = 'switch@franklin@chopshop', clip = 'wipehands', cam = 'wipehands_cam', indoors = true },   -- Franklin wipes his hands
        { dict = 'switch@franklin@chopshop', clip = 'wiperight', cam = 'wiperight_cam', indoors = true },   -- Franklin wipes his right hand
        { dict = 'switch@franklin@dispensary', clip = 'exit_dispensary_outro_ped', cam = 'exit_dispensary_outro_cam' },   -- Franklin leaves the dispensary
        { dict = 'switch@franklin@exit_building', clip = 'switch_01', cam = 'switch_01_cam', indoors = true },   -- Franklin walks out of a building
        { dict = 'switch@franklin@exit_building', clip = 'switch_02', cam = 'switch_02_cam' },   -- the same, the other way
        { dict = 'switch@franklin@garbage', clip = 'garbage_toss_plyr', cam = 'garbage_toss_cam' },   -- Franklin tosses a binbag
        { dict = 'switch@franklin@garbage_b', clip = 'garbage_toss_plyr', cam = 'garbage_toss_cam' },   -- the same, another camera
        { dict = 'switch@franklin@getting_ready', clip = '002334_02_fras_v2_11_getting_dressed_exit', cam = '002334_02_fras_v2_11_getting_dressed_exit_cam' },   -- Franklin getting dressed
        { dict = 'switch@franklin@hit_cup_hand', clip = 'hit_cup_hand_exit', cam = 'hit_cup_hand_exit_cam', indoors = true },   -- Franklin and a coffee cup
        { dict = 'switch@franklin@press_ups', clip = 'pressups_out', cam = 'pressups_out_cam', indoors = true },   -- Franklin's press-ups
        { dict = 'switch@franklin@throw_cup', clip = 'throw_cup_exit', cam = 'throw_cup_exit_cam', indoors = true },   -- Franklin throws a cup away
        { dict = 'switch@michael@cafe', clip = 'cafe_exit_ped', cam = 'cafe_exit_cam', indoors = true },   -- Michael leaves the cafe
        { dict = 'missheist_agency2aig_9', clip = 'franklin_call_michael_exit_player', cam = 'franklin_call_michael_exit_cam', indoors = true },   -- a phone call ends
        { dict = 'switch@michael@closet', clip = 'closet_c', cam = 'closet_c_cam' },   -- Michael at the closet
        { dict = 'switch@michael@goodbye_to_soloman', clip = 'exit_michael', cam = 'exit_cam' },   -- Michael says goodbye
        { dict = 'switch@michael@goodbye_to_soloman', clip = '001400_01_mics3_5_bye_to_soloman_exit', cam = '001400_01_mics3_5_bye_to_soloman_exit_cam' },   -- the same, the other take
        { dict = 'switch@michael@pharmacy', clip = 'mics1_ig_11_exit', cam = 'mics1_ig_11_exit_cam' },   -- Michael at the pharmacy
        { dict = 'switch@michael@pier', clip = 'pier_lean_smoke_outro', cam = 'pier_lean_smoke_outro_cam', indoors = true },   -- Michael smoking at a rail
        { dict = 'switch@michael@smoking', clip = 'exit_michael', cam = 'exit_cam' },   -- Michael smoking
        { dict = 'switch@michael@walk_and_talk', clip = 'im_a_married_man_michael', cam = 'im_a_married_man_cam' },   -- Michael walks and talks
        { dict = 'switch@michael@wash_face', clip = 'exit_michael', cam = 'exit_cam' },   -- Michael washes his face
        { dict = 'switch@michael@on_sofa', clip = 'exit_michael', cam = 'exit_cam', from = 0.5 },   -- Michael gets up from the sofa (from halfway in)
        { dict = 'switch@michael@biking_with_jimmy', clip = 'exit_michael', cam = 'exit_cam', from = 0.8 },   -- Michael after a ride (the last fifth of it)
        { dict = 'switch@trevor@at_the_docks', clip = '001209_01_trvs_3_at_the_docks_exit', cam = '001209_01_trvs_3_at_the_docks_exit_cam', indoors = true },   -- Trevor at the docks
        { dict = 'switch@trevor@drunk_howling_sc', clip = 'exit', cam = 'exit_cam' },   -- Trevor howls, Sandy Shores
        { dict = 'switch@trevor@naked_island', clip = 'exit', cam = 'exit_cam' },   -- Trevor gets up on a beach
        { dict = 'switch@trevor@slouched_get_up', clip = 'trev_slouched_get_up_exit', cam = 'trev_slouched_get_up_exit_cam' },   -- Trevor gets up from a slouch
        { dict = 'switch@trevor@stripclub', clip = 'trev_leave_stripclub_outro', cam = 'trev_leave_stripclub_outro_cam' },   -- Trevor leaves the strip club
    },

    -- In the seat of the car they left in (a motorbike has onBike; a bicycle, boat or aircraft: the seat with no scene).
    inVehicle = {
        { dict = 'switch@michael@sleep_in_car', clip = 'sleep_in_car_michael', cam = 'sleep_in_car_cam' },   -- Michael wakes up at the wheel
        -- 70% to 90% of it, the camera coming down as they open the door; then in.
        { dict = 'switch@michael@opens_door_for_ama', clip = '001895_02_mics3_17_opens_door_for_ama_exit_mic', cam = '001895_02_mics3_17_opens_door_for_ama_exit_cam',
          vehicleClip = '001895_02_mics3_17_opens_door_for_ama_exit_car', getsIn = true, from = 0.7, to = 0.9 },
    },

    -- Beside the motorbike they left on, stood back up.
    onBike = {
        { dict = 'switch@franklin@admire_motorcycle', clip = 'exit_franklin', cam = 'exit_cam', vehicleClip = 'exit_bike' },   -- Franklin admires his bike
    },

    -- On foot, at a car of theirs within nearCarRange.
    nearCar = {
        { dict = 'switch@michael@sitting_on_car_bonnet', clip = 'sitting_on_car_bonnet_exit', cam = 'sitting_on_car_bonnet_exit_cam', vehicleClip = 'sitting_on_car_bonnet_exit_car' },   -- Michael leans on the bonnet, then goes
    },
}


-- 12. Performance
--
-- How often background work runs. Bigger numbers mean less server load and slower reactions. The defaults are fine
-- for most servers.

Config.FlushInterval = 1000   -- ms between batched writes to the database (inventories and player rows)

-- Where players are standing; the same numbers as the vehicle settings above.
Config.PlayerPositionSaveInterval = 30    -- Seconds between position sweeps (hunger, thirst and saved stats go with them)
Config.PlayerPositionEpsilon      = 2.0   -- Metres a player must move before a write is worth doing

Config.StatsTickInterval   = 1   -- Seconds between stat updates on the server
Config.StatsSyncInterval   = 5   -- Seconds between sending the full set to the player
Config.StatsSetGuardWindow = 2   -- Seconds after a scripted health change in which a report of 0 health is ignored (a revive racing the game)

Config.TimeSyncInterval = 60000   -- ms between clock corrections sent to players

Config.GroundSyncInterval  = 1     -- Seconds between checking who is near a dropped item
Config.GroundItemCellSize  = 50    -- Search grid size in metres (server and client must match)

Config.ZonePollInterval        = 300    -- ms between checking which zone a player is in
Config.ZoneVehiclePollInterval = 2000   -- ms between the same check for vehicles
Config.ZoneTrackInterval       = 1000   -- ms between the server's check of zones with trackPlayers = true
Config.ZoneCheckRange          = 200    -- Only zones within this many metres are considered
Config.ZoneCellSize            = 50     -- Search grid size in metres


-- 12b. Experimental features: unfinished prototypes, not ready to use. Leave them off on a real server.
-- Also in /whip > Settings > Experimental features.

Config.Experimental = {
    cameraCreator    = false,   -- the Camera Creator: camera shots and paths, a row at the end of /w
    systemsCreator   = false,   -- the Systems Creator: /systems
    combinedSettings = false,   -- one Settings page in the pause menu, GTA's settings and this server's together
}


-- 13. Advanced: you should not normally need to touch these.

-- UI theme: name a resource here and the NUI loads its `theme.css` over the base look. A theme overrides the design
-- tokens in html/css/base.css (docs/nui-theming.md) and ships as its own resource, so it survives whip_core updates.
-- nil means the base look. A missing or stopped resource falls back to the base look with a console error.
-- `/whip_theme` (devtools ACE) re-applies live.
--     Config.Theme = 'my_theme'
Config.Theme = nil

-- Custom inventory renderer: where a theme reskins whip's UI, this replaces the inventory's drawing layer with one
-- from another resource (it ships a `renderer.js` whose default export is a factory returning a renderer with a
-- render(); see docs/nui-inventory.md). A missing or broken renderer falls back to whip's own, loudly.
-- `setr whip_inventory_renderer <resource>` in server.cfg wins over this. Players pick up a change when they rejoin;
-- to try one first, use /whip_inventory_ui <resource> (developer mode).
Config.InventoryRenderer = nil

-- Resources that whip_core force-restarts whenever it restarts itself, because a restart wipes the registrations
-- (items, events, buttons) other resources made. You should not need to add anything: a resource signs itself up
-- again whenever whip_core is ready by including `shared_script '@whip_core/lib/satellite.lua'` and wrapping its
-- registrations in Whip.register(function() ... end). Add a resource here only when you cannot edit it. A restart
-- also throws away whatever state that resource held.
Config.DependentResources = {
}

-- Lets whip_test fake database failures. Every hook is dead while this is false. Turned on only by a test server's
-- server.cfg:  set whip_test_seams true
Config.EnableTestSeams = GetConvar('whip_test_seams', 'false') == 'true'

-- Who can find out another player's character name (a script asks with GetPlayerFullName, for a name tag or a
-- "Search John Smith" option):
--   'nearby'  only players standing close by — within PlayerNameRange metres
--   'always'  anyone, about anyone, anywhere
--   'never'   nobody (server scripts can still read names)
Config.ShowPlayerNames = 'nearby'
Config.PlayerNameRange = 25.0   -- metres, for 'nearby'

-- The statebag integrity guard (server/sentinel.lua). A client can rewrite its own player statebag and those of
-- vehicles it drives, which is where whip keeps replicated state. The Sentinel watches whip's keys (all start with
-- `whip`); a value that differs from what the server wrote is put back on the next tick and logged as a tamper,
-- visible in the Event Monitor's Sentinel tab. No legitimate code writes these keys from a client.
-- A third-party resource that writes one of whip's own keys directly is indistinguishable from a cheater: it has to
-- go through whip instead. If you add resources you have not audited, set autoKick = false and watch the log first.
--   autoKick   strikes before the player is dropped, or false to only log
Config.Sentinel = {
    enabled              = true,
    autoKick             = 3,       -- strikes before DropPlayer; false = log only
    strikesForgetMinutes = 60,      -- strikes are forgotten after this many minutes with no new one; false = never
    logDebounceMs        = 1000,    -- duplicate log/strike suppression per player+key
    bootSweep            = true,    -- one bag-vs-truth pass at start (bags outlive restarts)
    -- The range damageModifier / meleeModifier effects are held to (0.05 = take 5% of the damage). Effects
    -- multiply and the result is kept inside this range.
    damageModifierClamp = { min = 0.05, max = 4.0 },
}
