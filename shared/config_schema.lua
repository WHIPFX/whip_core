-- ============================================
-- ConfigSchema — what /whip → Settings → Config shows, and what it may change
-- ============================================
--
-- One entry per setting the Config panel edits. config.lua holds the DEFAULTS; this says how
-- each one may be edited (its type and range), what it is called and what it does in plain words,
-- and WHEN a change takes effect. Shared because the server validates against it and both sides
-- coerce a saved value by it when settings.json is read at load (shared/settings.lua).
--
-- WHAT GOES ON THE PAGE: what a server owner would choose or argue about. A feature on or off,
-- money, sizes and times players feel, the places and first scenes players see, and how the HUD
-- and prompts look. Background timings, reaches and stream distances, pixel sizes and fades,
-- physics, per-model fixes and debug switches stay in config.lua only, with their own comments.
--
-- AN ENTRY:
--   path     the setting's place in Config: 'DefaultCash', or 'Emotes.menuKey' for a field of a table
--   type     'int' | 'number' | 'bool' | 'string' | 'enum' | 'vec3' | 'vec4' | 'list' | 'records' | 'map'
--            | 'record' (one card of `fields`, each kept as a setting of its own: '<path>.<key>')
--   label    its name in the panel           help   one or two plain sentences
--   min/max/step/unit   numbers               maxLen   strings (minLen defaults to 1)
--   pattern  strings: a Lua pattern the whole text must match, and patternWhy, its rule in words
--   options  enum: { { value = 'nearby', label = 'Nearby only' }, ... }
--   nullable true when "none" is a real value (written as nil; an empty text box is none)
--   limits   vec3/vec4: { x = { min, max }, ... }   axisLabels: the boxes' names   here: true for
--            a "Use where I stand" button
--   item     list: what each entry is (an entry of its own: type, min, max, unit)
--   minItems/maxItems   list, records, map: how many entries
--   fields   records/map/record: the fields of each row, as entries with a `key` (which may reach
--            inside the row: 'permissions.canHire') instead of a path. Fields not listed are kept as they are.
--   unique   records: a field key no two rows may share
--   each     map: what each row's value is, when it is one value rather than a row of fields
--   keyKind  map: 'hash' for model keys (a model name or its number; kept as the number), else names
--            keyPattern/keyWhy: the rule for names; keyLabel: the key column's heading
--   shownWhen  { path, equals }: the row (a card: all its fields) shows only while that setting is
--            that value, as the panel has it: a distance under the switch it belongs to
--   warnOn   bool: { title, text, confirm } the panel asks before the switch goes on (an experimental feature)
--   cross    a function(get) answering true, or false and why, about settings that must agree; the
--            server asks it about the values as they will be once an Apply is saved
--   apply    'live' (default): takes effect at once, everywhere.
--            'restart': saved now, takes effect when whip_core next starts; say why in `why`.
--   sides    'both' (default) | 'server': where the value is read. A 'server' setting never reaches
--            a player: it is not sent, and it is kept in server_settings.json, which players do not
--            download (shared/settings.lua).
--
-- A SETTING THAT NEEDS SOMETHING RE-RUN when it changes registers a hook beside the code that
-- reads it: Settings.onChange('Path', fn) (shared/settings.lua). A setting is 'live' only if every
-- place that reads it either reads it at the moment of use or has such a hook.
--
-- A group with `editedIn` (a section id) is changed on that page of the panel instead of here:
-- config.lua's items, on Items.

-- The most characters one account may have, and so the most hero shots (one per character; a place with no shot
-- of its own falls back to one that exists, client/charselect.lua).
local MAX_CHARACTERS = 30

-- A place on the map, and the way it faces.
-- y reaches -7000 for Cayo Perico and North Yankton.
local WORLD = { x = { -4000, 8000 }, y = { -7000, 8000 }, z = { -200, 2000 }, w = { 0, 360 } }

-- A camera's turn: pitch (up and down), roll, yaw (round), in degrees.
local TURN = { x = { -90, 90 }, y = { -180, 180 }, z = { -360, 360 } }

-- A weather a scene names. Text chosen from the list, not a fixed set of choices: this file loads
-- before a saved weather list is applied, so choices made here would be config.lua's forever. The
-- panel offers the list as it stands (choicesFrom), and the cross check keeps the name in it.
local WEATHER = { type = 'string', maxLen = 20, pattern = '^[%u%d_]+$', patternWhy = 'must be a GTA weather name in capitals',
                  choicesFrom = 'WeatherTypes' }

-- One of the arrival scenes' four lists (Config.ArrivalScenes, client/arrival.lua): its scene lines, edited by the
-- page's arrivalScenes widget, which adds scenes from GTA's own (client/arrival_list.lua) and plays one where the admin
-- stands (Watch). A line's other fields (a `prop`) are kept as they are.
local ARRIVAL_ON = { path = 'ArrivalScenes.enabled', equals = true }
local ANIM = { type = 'string', maxLen = 96, pattern = '^[%w_@%.%-]+$', patternWhy = 'must be a GTA animation name' }
local function animField(key, label, nullable)
    return { key = key, type = ANIM.type, maxLen = ANIM.maxLen, pattern = ANIM.pattern, patternWhy = ANIM.patternWhy,
             nullable = nullable, label = label }
end
local function arrivalList(list, label, help)
    return {
        path = 'ArrivalScenes.' .. list, type = 'records', widget = 'arrivalScenes', minItems = 0, maxItems = 60,
        shownWhen = ARRIVAL_ON, label = label, help = help,
        fields = {
            animField('dict', 'Dictionary'),
            animField('clip', 'Clip'),
            animField('cam', 'Camera move', true),
            animField('vehicleClip', 'Vehicle clip', true),
            { key = 'from', type = 'number', min = 0, max = 0.95, step = 0.05, nullable = true, label = 'Starts at' },
            { key = 'to', type = 'number', min = 0.05, max = 1, step = 0.05, nullable = true, label = 'Ends at' },
            { key = 'getsIn', type = 'bool', nullable = true, label = 'Ends in the seat' },
            { key = 'indoors', type = 'bool', nullable = true, label = 'Indoors too' },
        },
        cross = function(get)
            for i, line in ipairs(get('ArrivalScenes.' .. list) or {}) do
                if line.from and line.to and line.to <= line.from then
                    return false, ('%s, scene %d: it must end after it starts'):format(label, i)
                end
            end
            return true
        end,
    }
end

-- What switching on an experimental feature asks first (warnOn: the panel shows it, and the switch goes on only
-- if the admin agrees).
local EXPERIMENTAL_WARNING = {
    title = 'An unfinished prototype',
    text = 'This feature is in an unfinished prototype state. It is extremely broken and unusable, and is here only '
        .. 'so upcoming features can be looked at while they are being built. It is recommended to leave it off. '
        -- Josh, 9 Nov: "Turn it on" read as done, and the switch was never saved
        .. 'It is a change like any other here: press Apply to save it.',
    confirm = 'Turn it on',
}

--- A shot's camera (`<base>.pos/.rot/.fov`), as one card: place, turn and zoom together,
--- each still saved on its own. Its place carries the camera buttons (`camera`): "Place camera" flies a free
--- camera from the shot and Enter takes all three (tools/panel_sections/config.lua); "Use my camera" takes
--- the camera you are looking through now.
local function cameraCard(base, title, where, shownWhen)
    return { path = base, type = 'record', shownWhen = shownWhen,
             fields = {
                 { key = 'pos', type = 'vec3', limits = { x = { -4000, 8000 }, y = { -7000, 8000 }, z = { -200, 2000 } },
                   camera = { rot = base .. '.rot', fov = base .. '.fov' },
                   label = 'Place' },
                 { key = 'rot', type = 'vec3', limits = TURN, axisLabels = { 'Pitch', 'Roll', 'Yaw' },
                   label = 'Turn' },
                 { key = 'fov', type = 'number', min = 10, max = 120, step = 0.5, unit = '°',
                   label = 'Zoom' },
             },
             label = title .. ': camera',
             help = 'The camera for ' .. where .. '. Place camera: fly to the shot you want (as noclip flies: WASD, the mouse, the wheel zooms; the sticks on a controller) and press Enter, and its place, turn and zoom are filled in here, ready to Apply. Esc leaves them as they were. Or type them: turn is in degrees (pitch up and down, yaw round), and a lower zoom is closer in.' }
end

--- Is `weather` in the weather list as it will be? (A scene's weather must be one of them.)
local function weatherListed(get, weather)
    for _, w in ipairs(get('WeatherTypes') or {}) do
        if w == weather then return true end
    end
    return false
end

--- A scene's weather and time of day (`<base>.weather/.hour/.minute`), held while it shows, as one card.
--- `clock`: with `.frozen` too, the clock stopped or running from there.
local function skyCard(base, title, clock, shownWhen)
    local path = base .. '.weather'
    local fields = {
        { key = 'weather', type = WEATHER.type, maxLen = WEATHER.maxLen, pattern = WEATHER.pattern,
          patternWhy = WEATHER.patternWhy, choicesFrom = WEATHER.choicesFrom,
          cross = function(get)
              local w = get(path)
              if w == nil or weatherListed(get, w) then return true end
              return false, ('%s: %s is not in the weather list'):format(title, tostring(w))
          end,
          label = 'Weather' },
        { key = 'hour', type = 'int', min = 0, max = 23, unit = 'h', label = 'Hour' },
        { key = 'minute', type = 'int', min = 0, max = 59, unit = 'min', label = 'Minute' },
    }
    if clock then fields[#fields + 1] = { key = 'frozen', type = 'bool', label = 'Clock stopped' } end
    return { path = base, type = 'record', fields = fields, shownWhen = shownWhen,
             label = title .. ': weather and time',
             help = 'The weather and the time of day while it shows, for this player only.'
                 .. (clock and ' Clock stopped holds the time still; off lets it run from there.' or '') }
end

-- When the minimap shows, or "Each player chooses" (MapOptions.onFoot, MapOptions.inVehicle).
local SHOWN_WHEN = {
    { value = 'player', label = 'Each player chooses' }, { value = 'on', label = 'Always shown' },
    { value = 'off', label = 'Never shown' },
}

-- A GTA model name. Checked for its characters only: whether the game has it shows in game.
local MODEL = '^[%w_]+$'
local MODEL_WHY = 'must be a model name (letters, digits and _)'

-- A resource name, as FiveM allows them.
local RESOURCE = '^[%w_%-]+$'
local RESOURCE_WHY = 'must be a resource name (letters, digits, _ and -)'

--- The weather list must keep every weather a scene names (the character screen, landing, creator,
--- the first start's).
local function weatherListCross(get)
    local uses = { 'Landing.look.weather', 'Creator.look.weather', 'StartWeather' }
    for _, p in ipairs(uses) do
        local w = get(p)
        if type(w) == 'string' and not weatherListed(get, w) then
            return false, ('the weather list must keep %s: %s uses it'):format(w, p)
        end
    end
    for i, shot in ipairs(get('CharSelect.slots') or {}) do
        local w = type(shot) == 'table' and shot.look and shot.look.weather
        if type(w) == 'string' and not weatherListed(get, w) then
            return false, ('the weather list must keep %s: hero shot %d uses it'):format(w, i)
        end
    end
    -- And the weather in force now (the server's): taken off the list it would stay until a restart,
    -- which then quietly drops it.
    local now = TimeWeather and TimeWeather.state and TimeWeather.state.weather
    if type(now) == 'string' and not weatherListed(get, now) then
        return false, ('the weather list must keep %s while it is the weather; change the weather first'):format(now)
    end
    return true
end

--- What config.lua's own items may have changed. Other resources' items are theirs.
local ITEM_FIELDS = {
    { key = 'name', type = 'string', maxLen = 50, label = 'Name' },
    { key = 'desc', type = 'string', maxLen = 300, nullable = true, label = 'Description' },
    { key = 'weight', type = 'number', min = 0, max = 1000, step = 0.0001, unit = 'kg', label = 'Weight' },
    { key = 'type', type = 'string', maxLen = 30, nullable = true, label = 'Kind' },
    -- Never empty: the server would fill an empty one in, and the panel would show it as changed.
    { key = 'stack', type = 'bool', label = 'Stacks' },
    { key = 'maxStack', type = 'int', min = 1, max = 1000000, label = 'Most per slot' },
    { key = 'usable', type = 'bool', nullable = true, label = 'Usable' },
    { key = 'cooldown', type = 'number', min = 0, max = 3600, step = 0.5, unit = 's', nullable = true, label = 'Cooldown' },
    { key = 'prop', type = 'string', maxLen = 64, nullable = true, pattern = MODEL, patternWhy = MODEL_WHY, label = 'Prop' },
    -- How a player picks one up off the ground: Rockstar's grab with one hand (the left or right, whichever side it
    -- is on) or with both (client/ground.lua). Every item has it (server/item_settings.lua's base rows for the rest).
    { key = 'grab', type = 'enum', options = { { value = '1h', label = 'One hand' }, { value = '2h', label = 'Both hands' } },
      label = 'Picked up with' },
    -- Held out to give or throw: off, the player carries it with the give walk (Config.GiveModeStyle); on, they keep
    -- their own walk (client/inventory.lua). Every item has it, as it has grab.
    { key = 'playerWalk', type = 'bool', label = 'Allow player walk animation' },
}

--- A new character gets the starting cash as one stack of notes in one slot of their pockets, so
--- cash must stack that high and the notes must fit the pocket's weight. Asked whichever of the
--- three changes.
local function cashCross(get)
    local cash = get('DefaultCash') or 0
    if cash <= 0 or get('Items.cash.name') == nil then return true end
    local maxStack, weight = get('Items.cash.maxStack'), get('Items.cash.weight') or 0
    if not get('Items.cash.stack') or (tonumber(maxStack) or 1) < cash then
        return false, ('$%s of starting cash is more than one stack of cash holds (%s)'):format(tostring(cash), tostring(maxStack))
    end
    local room = get('MaxWeight.player')
    if type(room) == 'number' and cash * weight > room then
        return false, ('$%s of starting cash weighs %.1f kg, more than a pocket holds (%s kg)'):format(tostring(cash), cash * weight, tostring(room))
    end
    return true
end

--- The item registry's own rules, asked before saving: a hook cannot refuse once it is saved.
local function itemCross(key)
    local base = 'Items.' .. key .. '.'
    return function(get)
        local name = get(base .. 'name') or key
        local stack, maxStack = get(base .. 'stack'), get(base .. 'maxStack')
        if not stack and tonumber(maxStack) and maxStack > 1 then
            return false, ('%s does not stack, so it holds one per slot (most per slot 1)'):format(name)
        end
        if stack and Panels and Panels.itemConfigs and Panels.itemConfigs[key] ~= nil then
            return false, ('%s holds a panel of its own, so it cannot stack'):format(name)
        end
        if key == 'cash' then return cashCross(get) end
        return true
    end
end

--- config.lua's items, one entry each, as config.lua has them when whip_core starts (other
--- resources register theirs later, and they are not in this list).
local function itemEntries()
    local keys = {}
    for k, def in pairs(Config.Items or {}) do
        if type(def) == 'table' and type(k) == 'string' then keys[#keys + 1] = k end
    end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do
        -- One hand unless config.lua says both: the default the page shows and Reset puts back.
        if Config.Items[k].grab ~= '2h' then Config.Items[k].grab = '1h' end
        -- The give walk unless config.lua says their own: likewise.
        Config.Items[k].playerWalk = Config.Items[k].playerWalk == true
        out[#out + 1] = {
            path = 'Items.' .. k, type = 'record', fields = ITEM_FIELDS, cross = itemCross(k),
            label = ('%s (%s)'):format(tostring(Config.Items[k].name or k), k),
            help = 'Its name, description, weight, whether it stacks and how many to a slot, whether it can be used and how often, its prop, whether it is picked up with one hand or both, and whether a player holding it out keeps their own walk. Players see the change the next time they open their inventory.',
        }
    end
    return out
end

--- The hero shots' weathers must be on the weather list, as every scene's must.
local function heroWeathers(get)
    for i, shot in ipairs(get('CharSelect.slots') or {}) do
        local w = type(shot) == 'table' and shot.look and shot.look.weather
        if type(w) == 'string' and not weatherListed(get, w) then
            return false, ('hero shot %d\'s weather %s is not on the weather list'):format(i, w)
        end
    end
    return true
end

local LANDING_ON = { path = 'Landing.enabled', equals = true }

ConfigSchema = {
    {
        id = 'characters', label = 'Characters, money & jobs',
        settings = {
            { path = 'MaxCharacters', type = 'int', min = 1, max = MAX_CHARACTERS, unit = 'characters', sides = 'both',
              label = 'Characters per account',
              help = 'How many characters one player account may make. Each gets a hero shot on the character screen (Joining page); one not made yet shows another until it is. Lowering it deletes nobody, but characters past the new limit are hidden from the character screen until it is raised again.' },
            { path = 'DefaultCash', type = 'int', min = 0, max = 800000, unit = '$', sides = 'server', cross = cashCross,
              label = 'Starting cash',
              help = 'Cash a new character starts with, as one stack of notes in their pockets. It must fit one stack of cash and the pocket\'s weight (with config.lua\'s cash, $800,000 fills an 80 kg pocket).' },
            { path = 'StartingBalance', type = 'int', min = 0, max = 1000000000, unit = '$', sides = 'server',
              label = 'Starting bank balance',
              help = 'What a new character\'s personal account starts with.' },
            { path = 'MaxExtraAccounts', type = 'int', min = 0, max = 100, unit = 'accounts', sides = 'server',
              label = 'Savings and shared accounts',
              help = 'How many savings and shared accounts one character may open, from the phone\'s Bank app or any resource. Their personal account and job accounts do not count. 0 = none. Lowering it closes nothing.' },
            { path = 'BlockOwnCharacterTransfers', type = 'bool', sides = 'server',
              label = 'No money between a player\'s own characters',
              help = 'On: a player cannot send bank money from one of their characters to another of their own characters. Off: they can, like sending it to anyone else.' },
            { path = 'DefaultSpawn', type = 'vec4', limits = WORLD, here = true,
              label = 'New character spawn',
              help = 'Where a new character appears when they leave the creator, and the way they face. Characters who have played before come back where they left.' },
            { path = 'ShowPlayerNames', type = 'enum', sides = 'server',
              options = {
                  { value = 'nearby', label = 'Nearby players only' }, { value = 'always', label = 'Always' },
                  { value = 'never', label = 'Never' },
              },
              label = 'Who sees character names',
              help = 'Every player plays a character with a name of its own, like "John Smith". This decides when other players may see that name: in menus like giving an item, the phone\'s list of people nearby, and mission teams. Nearby players only: only players standing close by. Always: everyone, wherever they are. Never: nobody sees anyone else\'s character name. You always see your own.' },
            { path = 'PlayerNameRange', type = 'number', min = 2, max = 200, step = 1, unit = 'm', sides = 'server',
              shownWhen = { path = 'ShowPlayerNames', equals = 'nearby' },
              label = 'Name range',
              help = 'How close another player has to stand to see your character\'s name.' },
            { path = 'JobDefaultRoles', type = 'records', sides = 'server', minItems = 1, maxItems = 20, unique = 'name',
              -- The database's role names ignore case, and the owner holds the top role.
              cross = function(get)
                  local seen, top = {}, false
                  for i, r in ipairs(get('JobDefaultRoles') or {}) do
                      local n = tostring(r.name or ''):lower()
                      if seen[n] then return false, ('roles %d and %d have the same name (case does not count)'):format(seen[n], i) end
                      seen[n] = i
                      if r.level == 100 then top = true end
                  end
                  if not top then return false, 'one role must be level 100: a job\'s owner holds it' end
                  return true
              end,
              fields = {
                  { key = 'name', type = 'string', maxLen = 50, label = 'Role' },
                  { key = 'level', type = 'int', min = 1, max = 100, label = 'Level' },
                  { key = 'permissions.canHire', type = 'bool', nullable = true, label = 'Hire' },
                  { key = 'permissions.canFire', type = 'bool', nullable = true, label = 'Fire' },
                  { key = 'permissions.canPromote', type = 'bool', nullable = true, label = 'Promote' },
                  { key = 'permissions.canDemote', type = 'bool', nullable = true, label = 'Demote' },
                  { key = 'permissions.canManage', type = 'bool', nullable = true, label = 'Manage' },
                  { key = 'permissions.bankAccess', type = 'enum', nullable = true, emptyLabel = 'none', label = 'Bank',
                    options = { { value = 'none', label = 'None' }, { value = 'view', label = 'View' },
                                { value = 'deposit', label = 'Deposit' }, { value = 'withdraw', label = 'Withdraw' },
                                { value = 'manager', label = 'Manager' } } },
              },
              label = 'Roles a new job starts with',
              help = 'The roles a job gets when it is made without its own. The owner holds the top level, so keep a role at 100. Jobs already made keep theirs.' },
            { path = 'JobDutyOneAtATime', type = 'bool', sides = 'server',
              label = 'One job on duty at a time',
              help = 'On: clocking on at a job clocks the player off every other job. Off: a player can be on duty at several, and the one they clocked on at last is their current job. Anyone already on several stays so until they next clock on.' },
            { path = 'JobOneCharacterPerAccount', type = 'bool', sides = 'server',
              label = 'One character per account at a job',
              help = 'On (the safe default): hiring is refused when another character of the same player account already works at that job, its owner included, so an alt cannot keep a fired character\'s access. Off: any character may be hired. Changing it fires nobody.' },
        },
    },
    {
        id = 'joining', label = 'Joining',
        settings = {
            { path = 'Landing.enabled', type = 'bool',
              label = 'Landing page',
              help = 'A shot with the whip logo and "press any button" before the character screen, as a player joins. Off goes straight to the character screen. Players joining after a change see it.' },
            cameraCard('Landing.camera', 'Landing', 'the landing shot', LANDING_ON),
            { path = 'Landing.prompt', type = 'string', maxLen = 80, nullable = true, shownWhen = LANDING_ON,
              label = 'Landing: prompt',
              help = 'The words under the logo. Empty keeps the page\'s own.' },
            skyCard('Landing.look', 'Landing', false, LANDING_ON),
            { path = 'CharSelect.slots', type = 'heroShots', widget = 'heroShots', maxItems = MAX_CHARACTERS, maxProps = 60,
              limits = { world = WORLD, turn = TURN }, cross = heroWeathers,
              label = 'Hero shots',
              help = 'Each character has a hero shot on the character screen: a place on the map, a camera, a pose, a sky and a scene of props. There is one for every character a player may have (Characters per account). Edit in world takes you there to build it: fly the camera and press "Use this view", move your character (they stand in for each player\'s), press "Pose" to pick their emote from the emote menu (each one plays on them as you click it), pick props from the catalog, then Done, and Apply here. A shot not made yet shows another one until it is.' },
            { path = 'CharSelect.quietBucket', type = 'bool',
              label = 'No traffic or people there',
              help = 'Each player on the character screen is in a world of their own. On: it has no traffic and no passers-by walking through the shots. A change reaches each player the next time they come to the character screen.' },
            { path = 'CharSelect.spawnPicker', type = 'bool',
              label = 'Choose where to arrive',
              help = 'On: after Play, the camera looks up, the map comes down over it, and the player picks where to arrive (where they last were, a spawn point below, or a property they own or have a key to), then the map drops into their arrival. Off: Play fades to black and they arrive where they left. A dead character and a brand new one always get the fade.' },
            { path = 'SpawnPoints', type = 'records', sides = 'server', minItems = 0, maxItems = 30, unique = 'id',
              shownWhen = { path = 'CharSelect.spawnPicker', equals = true },
              fields = {
                  { key = 'id', type = 'string', maxLen = 24, pattern = '^[%w_%-]+$', patternWhy = 'may only use letters, digits, - and _', label = 'Id' },
                  { key = 'label', type = 'string', maxLen = 40, label = 'Name' },
                  { key = 'pos', type = 'vec4', limits = WORLD, here = true, label = 'Place' },
              },
              label = 'Spawn points',
              help = 'The places a player may choose to arrive at, beside where they last were and the properties they own or have a key to. Here fills a place from where you stand, facing the way you face. A change shows the next time someone comes to the character screen.' },
            -- Arrival scenes (Config.ArrivalScenes): the switch, the two distances and the four lists.
            { path = 'ArrivalScenes.enabled', type = 'bool',
              label = 'Arrival scenes',
              help = 'As the picture comes back after picking a character, one of GTA\'s own character-switch scenes plays where they are, and someone who left sitting in a car that is still near wakes up in it. Off: the picture just fades up.' },
            { path = 'ArrivalScenes.vehicleRange', type = 'number', min = 0, max = 2000, step = 10, unit = 'm',
              shownWhen = ARRIVAL_ON,
              label = 'Back in the car within',
              help = 'Someone who left sitting in a car comes back in it while it is at most this far from where they left (a locked one: beside it).' },
            { path = 'ArrivalScenes.nearCarRange', type = 'number', min = 0, max = 200, step = 1, unit = 'm',
              shownWhen = ARRIVAL_ON,
              label = 'Arrive at their car within',
              help = 'Someone who left on foot with a car of theirs at most this near arrives at it.' },
            arrivalList('onFoot', 'Arrival scenes: on foot',
                'Played where they arrive, one picked at random each time. A scene whose walk would go through a wall is skipped for another, and inside a building only those marked Indoors too play. Add any of GTA\'s own switch scenes; Watch plays one where you stand.'),
            arrivalList('inVehicle', 'Arrival scenes: in a car seat',
                'Played in the seat of the car they left in. A scene made with a car is lined up with it; Ends in the seat finishes with them in the seat.'),
            arrivalList('onBike', 'Arrival scenes: by a motorbike',
                'Played beside the motorbike they left on, stood back up. Only scenes made with a bike line up with it.'),
            arrivalList('nearCar', 'Arrival scenes: at their car',
                'Played at a car of theirs within the distance above, when they left on foot. Only scenes made with a car line up with it.'),
            { path = 'Creator.spawn', type = 'vec4', limits = WORLD, here = true,
              label = 'Creator: where',
              help = 'Where a new character stands while being made, and the way they face. It must be open ground; the player is in a private world there.' },
            skyCard('Creator.look', 'Creator', true),
        },
    },
    {
        id = 'survival', label = 'Hunger, thirst and breath',
        settings = {
            -- The gauges as the HUD draws them, dragged into order. Its own widget
            -- (html/js/wp/config.js); what can be dragged is server/stats.lua's (Settings.setChoices).
            { path = 'StatOrder', type = 'list', widget = 'statOrder', maxItems = 40, sides = 'server',
              item = { type = 'string', maxLen = 40, pattern = '^[%w_%-]+$', patternWhy = 'must be a stat name' },
              label = 'Gauge order',
              help = 'The gauges as the HUD shows them, left to right: drag one to move it. A faded gauge is turned off (Hunger or Thirst, below) and takes this place when it is turned on. A gauge another resource adds goes on the end until it is moved here.' },
            -- On or off, and how long each takes to drain; the rest is server/stats.lua's.
            { path = 'Hunger', type = 'bool', sides = 'server',
              label = 'Hunger (drains over time)',
              help = 'On: hunger drains over time, is saved with the character, has a gauge, and costs health once it falls under 10%. Food fills it back up. Off: no hunger at all: no gauge, no drain, no damage. Food can still be eaten. Turning it off fills everyone up.' },
            { path = 'HungerMinutes', type = 'int', min = 1, max = 1440, unit = 'minutes', sides = 'server',
              shownWhen = { path = 'Hunger', equals = true },
              label = 'Hunger drain time',
              help = 'How long hunger takes to go from full to empty. A change takes effect at once and moves nobody\'s hunger, only how fast it goes from here.' },
            { path = 'Thirst', type = 'bool', sides = 'server',
              label = 'Thirst (drains over time)',
              help = 'The same for thirst. Drinks fill it back up.' },
            { path = 'ThirstMinutes', type = 'int', min = 1, max = 1440, unit = 'minutes', sides = 'server',
              shownWhen = { path = 'Thirst', equals = true },
              label = 'Thirst drain time',
              help = 'How long thirst takes to go from full to empty. A change takes effect at once and moves nobody\'s thirst.' },
            { path = 'NeedDamage', type = 'int', min = 0, max = 50, unit = 'health', sides = 'server',
              label = 'Empty hunger or thirst costs',
              help = 'Health lost every 10 seconds while hunger or thirst is under 10% (health runs to 200). 0: they never hurt. A change takes effect at once.' },
            -- The server's stat tick reads it (server/stats.lua, tickOxygen).
            { path = 'OxygenSeconds', type = 'number', min = 1, max = 45, step = 1, unit = 's', sides = 'server',
              label = 'Breath under water',
              help = 'How long a player can stay under water, from a full breath, before they start to drown. The oxygen gauge shows it running out, and appears only while the breath is not full. Up to 45: the game\'s own breath is 50, and whip\'s must run out first. A change takes effect at once.' },
            -- Read by both sides at each death: the client counts it, the server refuses a respawn sooner
            -- (client/death.lua, server/events_misc.lua). The hospitals are a list in config.lua.
            { path = 'RespawnTime', type = 'int', min = 0, max = 600, unit = 's',
              label = 'Respawn wait',
              help = 'How many seconds a dead player waits before they can hold E to respawn at a hospital. A resource can hold one player longer (an EMS job with a medic on the way). A change counts from the next death. The hospitals are in config.lua (RespawnLocations).' },
            { path = 'DeathScreen', type = 'bool',
              label = 'whip\'s death screen',
              help = 'On: whip shows its death screen (the countdown, then hold E to respawn). Off: a resource of yours draws its own, from the client event whip_core:death:screenChanged. whip still counts down and reads E held to respawn either way.' },
        },
    },
    {
        id = 'inventory', label = 'Inventory',
        settings = {
            -- Whether whip's inventory screen is used at all.
            { path = 'EnableInventoryUI', type = 'bool',
              label = 'Enable Inventory?',
              help = 'Off disables whip\'s own inventory screen, while the inventory engine keeps working: items, weight, saving, stashes and car boots all still work. Turn it off if you are making your own inventory screen.' },
            { path = 'ContainerSlots.player', type = 'int', min = 1, max = 200, unit = 'slots', apply = 'restart',
              why = 'The checks on every inventory request take the largest inventory size when whip_core starts.',
              label = 'Player Inventory Size',
              help = 'How many slots every character\'s inventory has. Lowering it hides anything in the slots past the new size until it is raised again.' },
            { path = 'MaxWeight.player', type = 'number', min = 1, max = 1000, step = 0.5, unit = 'kg', cross = cashCross,
              label = 'Inventory Weight Limit',
              help = 'How much weight a character can carry, the accessory strip included. Lowering it below what someone carries takes nothing away, but nothing more fits until they put something down.' },
            { path = 'WeightUnit', type = 'enum',
              options = { { value = 'kg', label = 'Kilograms and grams' }, { value = 'lb', label = 'Pounds and ounces' } },
              label = 'Weight unit',
              help = 'What the inventory and shops show weights in, until a player picks their own in Settings, under Server. Weights typed in config.lua and on these pages are kilograms either way.' },
            -- A plain on/off; its slots are code (shared/inventory_shape.lua, AccessoryStripSlots).
            { path = 'AccessoryStrip', type = 'bool', apply = 'restart',
              why = 'Which containers a character has is fixed when whip_core starts.',
              label = 'Accessory Inventory',
              help = 'On: every character has the accessory inventory, a small strip beside their inventory with five slots that each take any item. A car key in it goes into the ignition by itself when they get in the driver\'s seat. Off: there is no strip, everything goes in the player inventory, and keys are put in the ignition by hand. Turning it off moves what each character had in the strip into their inventory when they next log in.' },
            { path = 'DropOnFullInventory', type = 'bool', sides = 'server',
              label = 'Drop when pockets are full',
              help = 'When a player is given an item but their inventory has no room. On: it is dropped on the ground at their feet, for them to pick up. Off: they do not get it at all, and whatever gave it (a shop, a job, a script) is told it failed.' },
            { path = 'GroundItemPickupRange', type = 'number', min = 1.5, max = 10, step = 0.5, unit = 'm',
              label = 'Ground pickup range',
              help = 'How close dropped items must be to show in the Ground panel, and the furthest a drop can land.' },
            { path = 'PlaceItemRange', type = 'number', min = 1, max = 20, step = 0.5, unit = 'm',
              label = 'Placing reach',
              help = 'How far from the camera a player can set an item down.' },
            { path = 'MaxGroundPilesPerDrop', type = 'int', min = 1, max = 200, unit = 'piles', sides = 'server',
              label = 'Drop pile limit',
              help = 'When a lot of items land on the ground at once (a big drop, or a full inventory spilling over), each stack becomes its own pile. This is the most piles one drop can make: past it, the items are shared out between that many piles, so the ground is not covered in them.' },
        },
    },
    {
        -- Changed on the Items page (/whip → Economy → Items), with every other item's settings, not
        -- on the Config page (`editedIn`: server/settings.lua leaves the group out of Config).
        id = 'items', label = 'Items', editedIn = 'items',
        settings = itemEntries(),
    },
    {
        id = 'vehicles', label = 'Vehicles',
        settings = {
            { path = 'DrivingCamera.Enabled', type = 'bool',
              label = 'Smooth driving camera',
              help = 'Lets players switch on the smooth driving camera for themselves (pause menu: Settings → Server → Vehicles): a chase camera on a spring that leans into slides and widens with speed. Off: nobody can, and anyone using it goes back to GTA\'s.' },
            { path = 'DrivingCamera.Default', type = 'bool',
              shownWhen = { path = 'DrivingCamera.Enabled', equals = true },
              label = 'Smooth driving camera to start with',
              help = 'Whether a player who has never chosen has it on. Players who chose keep their choice.' },
            { path = 'DrivingCamera.Shake', type = 'number', min = 0, max = 3, step = 0.1, unit = '×',
              shownWhen = { path = 'DrivingCamera.Enabled', equals = true },
              label = 'Driving camera shake',
              help = 'How much the smooth driving camera shakes at speed and in a crash. 0: never.' },
            { path = 'BikeAutoHelmet', type = 'bool',
              label = 'Helmet on a motorbike',
              help = 'GTA puts a helmet on a character getting onto a motorbike, over whatever they wear on their head. Off: they ride in what they have on.' },
            { path = 'Seats.NoAutoShuffle', type = 'bool',
              label = 'Passengers stay in their seat',
              help = 'On: GTA no longer slides a passenger into an empty driver\'s seat, getting in at the passenger door gives the passenger seat, and GTA\'s own shuffle button (H, D-pad right) does nothing. Players change seat with Seats on the F1 wheel. Off is GTA\'s own way.' },
            { path = 'VehiclePartPrompts', type = 'record',
              fields = {
                  { key = 'door.enabled', type = 'bool', label = 'Doors' },
                  { key = 'trunk.enabled', type = 'bool', label = 'Boot' },
                  { key = 'hood.enabled', type = 'bool', label = 'Bonnet' },
                  { key = 'bike.enabled', type = 'bool', label = 'Motorbikes' },
                  { key = 'bicycle.enabled', type = 'bool', label = 'Bicycles' },
                  { key = 'boat.enabled', type = 'bool', label = 'Boats' },
              },
              label = 'Vehicle prompts',
              help = 'The E circles on vehicles: on a car\'s doors, boot and bonnet to open and shut them, and one on a motorbike, a bicycle or a boat to get on, refuel or store it. Off takes that one away.' },
            { path = 'VehicleTrunkSlots', type = 'int', min = 1, max = 500, unit = 'slots', sides = 'server',
              label = 'Boot slots',
              help = 'Slots in a car\'s boot, unless the car, its model or its category has its own (Vehicles → Vehicle Adjustments). Lowering it hides anything in the slots past the new size until it is raised again. An open boot shows the new size when it is opened again.' },
            { path = 'VehicleTrunkMaxWeight', type = 'number', min = 1, max = 5000, step = 5, unit = 'kg', sides = 'server',
              label = 'Boot weight limit',
              help = 'The same for weight. Lowering it below what a boot holds takes nothing out, but nothing more goes in.' },
            { path = 'VehicleGloveboxSlots', type = 'int', min = 1, max = 500, unit = 'slots', sides = 'server',
              label = 'Glovebox slots',
              help = 'Slots in a car\'s glovebox, unless the car, its model or its category has its own. Lowering it hides anything in the slots past the new size until it is raised again.' },
            { path = 'MotorbikeGloveboxSlots', type = 'int', min = 1, max = 500, unit = 'slots', sides = 'server',
              label = 'Motorbike glovebox slots',
              help = 'Slots in a motorbike\'s glovebox, unless the bike, its model or the Motorcycles category has its own. A bicycle has no glovebox, and needs no key to ride.' },
            { path = 'VehicleGloveboxMaxWeight', type = 'number', min = 1, max = 1000, step = 1, unit = 'kg', sides = 'server',
              label = 'Glovebox weight limit',
              help = 'The same for weight.' },
            { path = 'NpcVehicleLockRange', type = 'number', min = 0, max = 50, step = 1, unit = 'm',
              label = 'Lock street cars within',
              help = 'Parked street cars this close are kept locked, so they must be lockpicked. 0 turns the rule off (cars it already locked stay locked).' },
            { path = 'UnlockOnExit', type = 'bool', sides = 'server',
              label = 'Getting out unlocks a locked car',
              help = 'On: getting out of a locked car unlocks it (GTA lets anyone open a locked door from inside). Off: it stays locked behind them, as a car that locks itself. Leaving the game in a locked car never unlocks it either way.' },
            { path = 'LockpickGame', type = 'string', maxLen = 64, pattern = '^[%w_%.%-]+$', patternWhy = 'must be ring or a skill check game\'s name', sides = 'server',
              label = 'Lockpick game',
              help = 'The skill check whip\'s own lockpicks play (cars and doors at medium, the ignition hack at hard): ring, whip\'s own, or the name of a game another resource adds (such as one of whip_phone\'s). If that resource is not running, the ring is played and the console says so.' },
            { path = 'VehicleDamage.remember', type = 'bool', sides = 'server',
              label = 'Cars keep their damage',
              help = 'Engine and body damage, doors torn off and burst tyres are saved with the car and put back on when it comes out of a garage or after a restart. Dents are not. Off: every car comes back like new.' },
            { path = 'VehicleHud.speedUnit', type = 'enum',
              options = { { value = 'mph', label = 'Miles an hour' }, { value = 'kmh', label = 'Kilometres an hour' } },
              label = 'Speedometer unit',
              help = 'The number on the rev dial and the label under it.' },
            { path = 'VehicleHud.dashSkins', type = 'bool',
              label = 'Cars\' own dial looks',
              help = 'Each car\'s rev dial wears that car\'s own GTA dashboard look: its face colour, fonts, number and needle colours. Off, every car has the dial as designed. A car with no dashboard art of its own in GTA keeps the dial as designed either way, and so does every aircraft.' },
            { path = 'GaragePositionHelper.enabled', type = 'bool',
              label = 'Parking guide',
              help = 'Paints a bay\'s outline on the road for a driver, since prompts are hidden in a car. A hint only: nothing on it is clicked.' },
            { path = 'GaragePositionHelper.showRange', type = 'number', min = 5, max = 100, step = 1, unit = 'm',
              shownWhen = { path = 'GaragePositionHelper.enabled', equals = true },
              label = 'Guide seen from',
              help = 'How far away a bay\'s outline starts to show.' },
            { path = 'ExperimentalDriveSync', type = 'bool', sides = 'server',
              label = 'Experimental recorded drives sync',
              help = 'Improves the quality of recorded drives across multiple players, at the cost of inconsistencies in syncing the vehicle\'s state between players.' },
        },
    },
    {
        id = 'properties', label = 'Properties',
        settings = {
            { path = 'PropertyMaxObjects', type = 'int', min = 1, max = 1000, unit = 'pieces', sides = 'server', apply = 'restart',
              why = 'Each property works out its furniture limit when whip_core starts.',
              label = 'Furniture per property',
              help = 'The most furniture one property may hold, unless its own settings say. Lowering it below what a room holds takes nothing away, but the room cannot save more until pieces are removed.' },
            { path = 'PropertyStashProps', type = 'map', keyLabel = 'Model', keyPattern = MODEL, keyWhy = MODEL_WHY,
              sides = 'server', maxItems = 200,
              fields = {
                  { key = 'label', type = 'string', maxLen = 40, label = 'Name' },
                  { key = 'slots', type = 'int', min = 1, max = 500, unit = 'slots', label = 'Slots' },
                  { key = 'weight', type = 'number', min = 1, max = 10000, step = 1, unit = 'kg', label = 'Holds' },
              },
              label = 'Stash furniture',
              help = 'Furniture that is a stash once placed in a property: only the owner and keyholders open it. The model must be in the furnisher\'s catalog. A change reaches stashes made after it; ones already placed keep their size. A stash holding anything is never thrown away: its furniture cannot be taken away until it is emptied.' },
            { path = 'PropertyStashLimit', type = 'int', min = 0, max = 50, unit = 'stashes', sides = 'server',
              label = 'Stashes per property',
              help = 'The most stash furniture one property may have. Lowering it takes none away; a room over it can still be saved, but gets no more.' },
        },
    },
    {
        id = 'world', label = 'World & gameplay',
        settings = {
            { path = 'TimeScale', type = 'number', min = 0, max = 10, step = 0.1, unit = '×', sides = 'server',
              link = { section = 'time', label = 'Open Time & Weather' },
              label = 'Clock speed',
              help = 'How fast the day passes: 1 is GTA\'s own (a day in 48 minutes), 2 twice as fast, 0 stops the clock. The running clock takes it at once; Time & Weather changes the clock without changing this.' },
            { path = 'WeatherTypes', type = 'list', minItems = 1, maxItems = 30, cross = weatherListCross,
              item = { type = 'string', maxLen = 20, pattern = '^[%u%d_]+$', patternWhy = 'must be a GTA weather name in capitals' },
              label = 'Weathers',
              help = 'The weathers whip and admins may set, split by commas. It must keep every weather a scene here uses. The scenes\' weather choices take a new name after a restart.' },
            { path = 'WeaponGuard.Enabled', type = 'bool',
              label = 'Block GTA\'s own guns',
              help = 'Guns are items, given by a weapon resource (whip_gunny ships with whip). On stops players picking up GTA\'s own (a dead NPC\'s, the shotgun in a police car) and takes away any that still arrive. Off lets them through, as GTA does.' },
            { path = 'WeaponGuard.Allow', type = 'list', minItems = 0, maxItems = 50,
              shownWhen = { path = 'WeaponGuard.Enabled', equals = true },
              item = { type = 'string', maxLen = 64, pattern = MODEL, patternWhy = 'must be a weapon name (letters, digits and _)' },
              label = 'GTA weapons players may keep',
              help = 'Weapon names split by commas, such as GADGET_PARACHUTE (to bail out of an aircraft). A misspelt name allows nothing.' },
            { path = 'ThrowKnockdown.Enabled', type = 'bool',
              label = 'Thrown items knock people over',
              help = 'An item thrown at someone knocks them down, like GTA\'s thrown newspaper, and bounces off them. Not someone in a no-PvP zone or with god mode on.' },
            { path = 'ThrowKnockdown.Npcs', type = 'bool',
              shownWhen = { path = 'ThrowKnockdown.Enabled', equals = true },
              label = 'NPCs are knocked over too',
              help = 'Off: only players fall.' },
            { path = 'ActionMode.Disable', type = 'bool',
              label = 'Keep GTA\'s combat stance off',
              help = 'GTA\'s crouched combat walk after firing or being shot at. On keeps it off, every frame.' },
            { path = 'IdleCam.Disable', type = 'bool',
              label = 'Keep GTA\'s idle camera off',
              help = 'GTA\'s slow cinematic pan after about 30 seconds with no input.' },
            { path = 'InteractPress.enabled', type = 'bool',
              label = 'Hand press',
              help = 'Using a car door, the boot or bonnet, an ATM, a fuel pump or any prompt marked to press: the player\'s hand goes out towards it and straight back. Only how it looks: the thing happens at once either way, and the player is never moved. Off: no presses. Picking things up off the ground plays GTA\'s own grab either way.' },
            -- Read at the moment of each line (server/shop_talk.lua). The lines themselves are config.lua's
            -- lists: they have commas in them, which a list box here would split.
            { path = 'ShopTalk.enabled', type = 'bool', sides = 'server',
              label = 'Shop talk',
              help = 'At a shop, the shopper says what they are doing in a /me bubble ("I\'ll take x3 Water") and the shopkeeper answers. The lines are in config.lua.' },
            -- Live: every shop's prompt takes it at once (server/shop_counters.lua).
            { path = 'ShopInteractRange', type = 'number', min = 1, max = 15, step = 0.5, unit = 'm',
              label = 'Shop reach',
              help = 'How close a player must stand to use a shop\'s prompt (the server allows 2 m more).' },
        },
    },
    {
        id = 'emotes', label = 'Emotes, /me and talk',
        settings = {
            { path = 'Emotes.placeRange', type = 'number', min = 1, max = 15, step = 0.5, unit = 'm',
              label = 'Emote placing reach',
              help = 'How far away a player can place an emote.' },
            { path = 'Bubbles.range', type = 'number', min = 5, max = 100, step = 1, unit = 'm',
              label = '/me seen from',
              help = 'Players further away do not see a /me. Onlookers see NPC conversations this far too.' },
            { path = 'Bubbles.duration', type = 'int', min = 500, max = 30000, step = 100, unit = 'ms',
              label = '/me stays up for',
              help = 'How long a /me bubble stays before it folds away.' },
            { path = 'Bubbles.maxLength', type = 'int', min = 10, max = 240, unit = 'characters',
              label = 'Longest /me',
              help = 'A longer /me is cut and the player told. A bubble shows two lines, so past about 120 the end is cut off on screen anyway.' },
            -- No more than 3: a player's share of the bubble texture holds three two-line bubbles.
            { path = 'Bubbles.maxStack', type = 'int', min = 1, max = 3, unit = 'bubbles', apply = 'restart',
              why = 'The bubbles are drawn on one texture, made for this many when whip_core starts.',
              label = '/me bubbles per player',
              help = 'Bubbles one player can have up at once; a new one pushes the oldest off.' },
            { path = 'Conversations.range', type = 'number', min = 2, max = 25, step = 0.5, unit = 'm',
              label = 'Conversation range',
              help = 'Walk further than this from an NPC and the conversation ends (the server allows 2 m more).' },
            { path = 'Conversations.watcherBubbles', type = 'bool',
              label = 'Onlookers see conversations',
              help = 'Players nearby see a conversation as /me bubbles: the NPC\'s line above the NPC, and the answer above the player who chose it.' },
            { path = 'Conversations.npcLines', type = 'int', min = 1, max = 4, unit = 'lines',
              label = 'NPC bubble lines',
              help = 'Lines an NPC\'s conversation bubble may wrap to.' },
            { path = 'LoreVoice.Enabled', type = 'bool', sides = 'server',
              label = 'Lore characters speak',
              help = 'Lore characters say their voice lines out loud in the world, from their NPC (Director > Lore characters > Voice lines), heard like a player\'s voice. Needs whip_voice and its voice bot.' },
            { path = 'LoreVoice.Links', type = 'list', minItems = 0, maxItems = 5, sides = 'server',
              shownWhen = { path = 'LoreVoice.Enabled', equals = true },
              item = { type = 'string', maxLen = 120, pattern = '^https://[%w%-%.]+%.[%a][%a]+/[%w%-%._/]*$',
                       patternWhy = 'must be https:// then a web address, ending in /' },
              label = 'Voice line links accepted',
              help = 'A voice line is a recording\'s link (.mp3, .ogg or .wav), and only one starting with one of these is taken. The voice bot fetches it; players never download it. Fivemanage by default; put your own account\'s address (https://r2.fivemanage.com/your-id/) to take only your own. Empty: no voice lines.' },
        },
    },
    {
        id = 'hud', label = 'HUD, map & prompts',
        settings = {
            { path = 'HudSkin', type = 'enum',
              options = {
                  { value = 'black', label = 'Black: white rims, map frame, dark map' },
                  { value = 'classic', label = 'Classic' },
              },
              label = 'HUD look',
              help = 'How the gauges and the minimap look. Black: black discs in a white rim that drains, no capsule behind them (it shows for a notification or chat), a white frame round the minimap, whip\'s dark map on it and a blue waypoint route. The frame is made for the rounded minimap; /radardebug lines it up. The vehicle dial stays as it is.' },
            { path = 'AimDot', type = 'bool',
              label = 'Aim dot',
              help = 'On: while a player aims, a small dot where the weapon points replaces GTA\'s reticle, red when the muzzle is up against a wall. Any weapon but melee ones and the petrol can. Off: GTA\'s own reticle. Takes effect at once.' },
            { path = 'MinimapMask', type = 'enum',
              options = {
                  { value = 'square', label = 'Square' }, { value = 'rounded', label = 'Rounded' },
                  { value = false, label = 'The game\'s own' },
              },
              label = 'Minimap shape',
              help = 'The shape of the minimap.' },
            -- The minimap, decided by the server instead of each player (client/minimap.lua, client/hud.lua). A player's
            -- row the server decides shows greyed in their Settings (Server), "Disabled by server admin" (PlayerPrefs `forced`).
            { path = 'MapOptions.onFoot', type = 'enum', options = SHOWN_WHEN,
              label = 'Minimap on foot',
              help = 'Whether players see the minimap on foot. "Each player chooses" leaves it to their own Settings (Server → Minimap → Show on foot); the others decide it for everyone.' },
            { path = 'MapOptions.inVehicle', type = 'enum', options = SHOWN_WHEN,
              label = 'Minimap in a vehicle',
              help = 'Whether players see the minimap in a vehicle. "Each player chooses" leaves it to their own Settings (Server → Minimap → Show in a vehicle).' },
            { path = 'Interact3D', type = 'record',
              fields = {
                  { key = 'theme', type = 'enum',
                    options = {
                        { value = 'keycap', label = 'Square: a key to press' },
                        { value = 'classic', label = 'Circle' },
                    },
                    label = 'Shape' },
                  { key = 'dark', type = 'bool', label = 'Dark' },
                  { key = 'badgePx', type = 'number', min = 20, max = 200, step = 1, unit = 'px', label = 'Circle size' },
                  { key = 'labelPx', type = 'number', min = 20, max = 200, step = 1, unit = 'px', label = 'Label size' },
              },
              label = 'Prompts',
              help = 'How the E prompts in the world look to players who have not chosen their own (pause menu, Settings → Server → Map & HUD). Dark swaps black and white: a black square with a white outline and symbol, and black words with a white outline. The sizes are how tall the circle and its label are on screen at the distance a prompt can be used from (measured at 1440p); further away they shrink like any object.' },
            { path = 'InteractVisibleRange', type = 'number', min = 1, max = 25, step = 0.5, unit = 'm',
              label = 'Prompt visible from',
              help = 'How far away an E prompt\'s circle appears. Keep it above the distance a prompt can be used from.' },
            { path = 'InteractActiveRange', type = 'number', min = 0.5, max = 10, step = 0.1, unit = 'm',
              label = 'Prompt usable from',
              help = 'How close a player must be for an E prompt to show its label and work (the server allows 2 m more). Keep it below the distance prompts appear from.' },
            -- Read as the camera comes up (client/items/camera.lua): one already up keeps what it had.
            { path = 'CameraHidesDui', type = 'bool',
              label = 'Hide DUI Elements whilst using camera?',
              help = 'Looking through the camera item always hides the HUD and whip\'s screens. Off: whip\'s things in the world stay, so the camera sees them: /me bubbles, NPC conversations, the parking guide, the Director\'s marks. On: they are hidden too. Takes effect the next time a camera comes up.' },
            { path = 'Keyboard.Languages', type = 'list', minItems = 1, maxItems = 20, apply = 'restart',
              why = 'The on-screen keyboard learns its languages when whip_core starts.',
              item = { type = 'string', maxLen = 3, pattern = '^%l%l%l?$', patternWhy = 'must be a language code, like en or fr' },
              label = 'On-screen keyboard languages',
              help = 'The languages controller players may type and get word suggestions in, by code (en, fr, de...), split by commas. Each needs its pack in html/keyboard/; English comes with whip.' },
            { path = 'Keyboard.Default', type = 'string', maxLen = 3, pattern = '^%l%l%l?$',
              patternWhy = 'must be a language code, like en or fr', apply = 'restart',
              why = 'The on-screen keyboard learns its languages when whip_core starts.',
              cross = function(get)
                  for _, code in ipairs(get('Keyboard.Languages') or {}) do
                      if code == get('Keyboard.Default') then return true end
                  end
                  return false, 'On-screen keyboard: the default language must be one of its languages'
              end,
              label = 'On-screen keyboard default language',
              help = 'The language for a player whose GTA language is not one of the keyboard\'s.' },
        },
    },
    {
        id = 'server', label = 'Server',
        settings = {
            { path = 'Theme', type = 'string', maxLen = 64, nullable = true, pattern = RESOURCE, patternWhy = RESOURCE_WHY,
              label = 'Theme',
              help = 'A resource whose theme.css restyles whip\'s screens; empty is the base look. One that is missing or stopped falls back to the base look. A resource that sets its own theme (SetActiveTheme) wins until it stops.' },
            { path = 'HudDeveloperMark', type = 'bool', sides = 'server',
              label = 'Show the developer mode mark',
              help = 'On: a player in developer mode has its mark on the HUD, an amber terminal prompt among the gauges. Off: no mark, for filming with developer mode on. Developer mode itself works the same either way. Takes effect at once.' },
            { path = 'ActivityLogDays', type = 'int', min = 1, max = 3650, unit = 'days', sides = 'server', apply = 'restart',
              why = 'Old entries are cleared once, as whip_core starts.',
              label = 'Keep activity log for',
              help = 'How long player and item timelines are kept.' },
            -- Read each time the Player Manager's list or a player's page loads (server/devtools.lua).
            { path = 'PlayerManagerSessionWarn', type = 'bool', sides = 'server',
              label = 'Warn in Player Manager if player is logged in on multiple game clients',
              help = 'Two game clients on one PC share a license, so whip sees one account with two characters in. The Player Manager lists each as its own row either way. On: it warns too, "2 sessions" on the rows and "Also in" with the other character on the player\'s page. Off: no warning. Takes effect the next time the list or a page loads.' },
            { path = 'LorePictureLinks', type = 'list', minItems = 0, maxItems = 5, sides = 'server',
              item = { type = 'string', maxLen = 120, pattern = '^https://[%w%-%.]+%.[%a][%a]+/[%w%-%._/]*$',
                       patternWhy = 'must be https:// then a web address, ending in /' },
              label = 'Picture links accepted',
              help = 'A profile picture (a lore character\'s, or a player\'s on their phone\'s My card) is a link, and only one starting with one of these is taken. Every player\'s game loads it from that site, so keep it to an image host you trust. Fivemanage by default; put your own account\'s address (https://r2.fivemanage.com/your-id/) to take only your own pictures, and players can\'t use their own then. Empty: no pictures.' },
            { path = 'Sentinel.enabled', type = 'bool', sides = 'server',
              label = 'Sentinel (tamper guard)',
              help = 'Watches whip\'s values on players and cars; one a player\'s game changes is put back and logged as a tamper, in the Event Monitor too. Off stops watching.' },
            { path = 'Sentinel.autoKick', type = 'int', min = 1, max = 50, unit = 'strikes', sides = 'server',
              offWhenEmpty = true, emptyLabel = 'off', shownWhen = { path = 'Sentinel.enabled', equals = true },
              label = 'Kick after',
              help = 'Tampers before the player is kicked; empty only logs. A resource you have not checked that writes one of whip\'s own values looks like a cheater, so leave it empty while you watch the log.' },
            { path = 'Sentinel.strikesForgetMinutes', type = 'number', min = 1, max = 1440, step = 1, unit = 'min', sides = 'server',
              offWhenEmpty = true, emptyLabel = 'never', shownWhen = { path = 'Sentinel.enabled', equals = true },
              label = 'Forget strikes after',
              help = 'A player\'s strikes start again after this long with no new one; empty never forgets them in a session.' },
        },
    },
    -- Unfinished prototypes, off by default. Switching one on asks first (warnOn: the panel's popup).
    {
        id = 'experimental', label = 'Experimental features',
        settings = {
            { path = 'Experimental.cameraCreator', type = 'bool', warnOn = EXPERIMENTAL_WARNING,
              label = 'Camera Creator',
              help = 'Camera shots and paths, flown with a free camera. On: a row at the end of /w (developer mode). An unfinished prototype: leave it off.' },
            { path = 'Experimental.systemsCreator', type = 'bool', warnOn = EXPERIMENTAL_WARNING,
              label = 'Systems Creator',
              help = 'Building game systems from cards. On: /systems opens it, and so does a row at the end of /w (developer mode). Off: /systems does not open. An unfinished prototype: leave it off.' },
        },
    },
}
