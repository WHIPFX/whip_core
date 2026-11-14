-- ============================================
-- Item settings — what an admin may change about one item (/whip → Economy → Items)
-- ============================================
--
-- Every item has a page of settings of its own in the settings engine (shared/settings.lua,
-- server/settings.lua), under the owner 'item:<key>'. So a change is saved in whip_settings with who
-- made it and when, logged in whip_settings_log, and Reset puts the item's own value back. Only a
-- permanent admin may change one (Settings.change).
--
-- EVERY ITEM: its name, description, weight, whether it is picked up with one hand or both (`grab`, '1h'
-- or '2h': client/ground.lua), and whether a player holding it out to give keeps their own walk
-- (`playerWalk`, client/inventory.lua). The default is what its definition says, so a resource
-- that rewords its item moves the default with it. (config.lua's own items have these, and more, as
-- settings of Config: 'Items.<key>.name' and so on, put in force as whip_core loads. The Items page
-- edits those there.)
--
-- AN ITEM'S OWN SETTINGS, opted into with a `settings` list in its definition. Each entry is a
-- RegisterSettings entry: a key, a type (int, number, bool, string or enum), a default, a label, and
-- whatever that type takes (min, max, step, unit, maxLen, nullable, options, help):
--
--     exports.whip_core:RegisterItem('pistol_mag', {
--         name = 'Pistol Magazine', weight = 0.2, ...,
--         settings = {
--             { key = 'capacity', type = 'int', min = 1, max = 100, default = 12,
--               label = 'Rounds it holds', help = 'How many rounds fit in one.' },
--             { key = 'quickLoad', type = 'bool', default = false, label = 'Loads in one go' },
--         },
--     })
--
-- The resource reads what is in force, and hears a change, on the server and on a player's game:
--
--     local capacity = exports.whip_core:GetItemSetting('pistol_mag', 'capacity')
--     exports.whip_core:OnItemSettingChanged('pistol_mag', 'capacity', function(value, old) end)
--
-- A player's game is sent every item's own settings as it joins and each change after
-- (client/item_settings.lua). None of them go in settings.json (sides = 'server'): this file sends
-- them, defaults included.
--
-- EVERY ITEM'S PICTURES: its `images` (server/item_options.lua) as rows an admin changes on its page, `pictures`:
-- { image, field, op, value } each, the first whose test passes drawn, the item's own when none does. `field` ''
-- is always; 'amount' the slot's count; any other a metadata field, tested by `op` (is, above, below, atLeast, atMost,
-- has, empty) against `value`. Its default is the definition's own `images`, so Reset puts them back. A row's
-- picture is one of the definition's own, or a link to one an admin pasted, from a site Config.LorePictureLinks
-- accepts. What the page offers to test (ItemSettings.pictureFields): the count for an item that stacks, the
-- definition's `pictureFields` ({ key, label, type = 'bool' | 'number' | 'text' }), its card's metaFields, and any
-- field its own pictures test.

ItemSettings = {}

local CORE = GetCurrentResourceName()
local DEVTOOLS = 'whip.devtools'

-- The settings every item has. Their keys are taken: an item's own may not use them.
local IS_BASE = { name = true, desc = true, weight = true, grab = true, playerWalk = true }
-- What an item's own setting may be: a value or an on/off ("values or toggles"). The Items page
-- edits each on one line.
local TYPES = { int = true, number = true, bool = true, string = true, enum = true }
local NUMBER_FIELDS = { 'min', 'max', 'step', 'maxLen' }
local MAX_OWN = 20

-- Pictures: a row's test, what a definition's pictureFields may be, and how many of each.
local PICTURE_OPS = { 'is', 'above', 'below', 'atLeast', 'atMost', 'has', 'empty' }
local NUMBER_OPS = { above = true, below = true, atLeast = true, atMost = true }
local PICTURE_FIELD_TYPES = { bool = true, number = true, text = true }
local MAX_PICTURES = 24
local MAX_PICTURE_FIELDS = 20
local PICTURE_ROW = {
    { key = 'image', type = 'string', maxLen = 300, label = 'Picture' },
    -- '' is kept as '' (minLen 0): Always, and a test with no value.
    { key = 'field', type = 'string', minLen = 0, maxLen = 40, pattern = '^[%w_]*$', label = 'Shown by' },
    { key = 'op', type = 'enum', label = 'Test', options = (function()
        local out = {}
        for i, op in ipairs(PICTURE_OPS) do out[i] = { value = op } end
        return out
    end)() },
    { key = 'value', type = 'string', minLen = 0, maxLen = 60, label = 'Value' },
}

local base = {}      -- [key] = { name, desc, weight, grab, playerWalk }: as the item's definition has them (the defaults)
local declaredPics = {}   -- [key] = its definition's own `images` (the pictures' default), {} for none
local own = {}       -- [key] = { entry, ... }: the item's own settings, checked
local waiting = {}   -- [key] = true: registered before whip_core was ready; its page is made then
local hooked = {}    -- [owner][path] = true: Settings.onChange listens already
local pushed = {}    -- [key] = true: players have been sent this item's own settings

---@param key string
---@return string
function ItemSettings.ownerOf(key)
    return Settings.ITEM_PREFIX .. key
end

--- Is this one of config.lua's items, whose name, description and weight are settings of Config?
---@param key string
---@return boolean
function ItemSettings.inConfig(key)
    return Settings.entry(CORE, 'Items.' .. key .. '.name') ~= nil
end

--- The settings every item has, with its definition's values as the defaults. Room is made for a
--- definition longer or heavier than the usual limits, so its own value always passes.
---@param declared table  { name, desc, weight }
---@return table
local function baseEntries(declared)
    local name = tostring(declared.name or '')
    local desc = type(declared.desc) == 'string' and declared.desc ~= '' and declared.desc or nil
    local weight = tonumber(declared.weight) or 0
    -- grab and playerWalk are set in the hand position editor (tools/hand_edit.lua), not on the Items page.
    return {
        { key = 'name', type = 'string', label = 'Name', default = name,
          maxLen = math.max(50, utf8.len(name) or #name) },
        { key = 'desc', type = 'string', label = 'Description', default = desc, nullable = true,
          maxLen = math.max(300, desc and (utf8.len(desc) or #desc) or 0) },
        { key = 'weight', type = 'number', label = 'Weight', default = weight, unit = 'kg',
          min = 0, max = math.max(1000, weight), step = 0.0001 },
        { key = 'grab', type = 'enum', label = 'Picked up with', default = declared.grab == '2h' and '2h' or '1h',
          options = { { value = '1h', label = 'One hand' }, { value = '2h', label = 'Both hands' } } },
        { key = 'playerWalk', type = 'bool', label = 'Allow player walk animation', default = declared.playerWalk == true },
    }
end

--- An item's own `settings`, checked and copied. Answers the list (nil for none), or nil and why.
---@param list any
---@param where string  'item "pistol_mag" settings', for the answer
---@return table|nil list
---@return string|nil why
function ItemSettings.clean(list, where)
    if list == nil then return nil end
    if type(list) ~= 'table' then return nil, where .. ': a list of settings' end
    if #list > MAX_OWN then return nil, ('%s: %d at most'):format(where, MAX_OWN) end
    local out, seen = {}, {}
    for i, e in ipairs(list) do
        local at = ('%s %d'):format(where, i)
        if type(e) ~= 'table' then return nil, at .. ' is not a table' end
        local key = e.key
        if type(key) ~= 'string' or not key:match('^[%a_][%w_]*$') or #key > 40 then
            return nil, at .. ': key must be a name (letters, digits and _)'
        end
        at = ('%s (%s)'):format(at, key)
        if IS_BASE[key] then return nil, at .. ': every item has name, desc, weight, grab and playerWalk already' end
        if key == 'pictures' then return nil, at .. ': every item has pictures already' end
        if seen[key] then return nil, at .. ' is there twice' end
        seen[key] = true
        if not TYPES[e.type] then return nil, at .. ': type must be int, number, bool, string or enum' end
        for _, f in ipairs(NUMBER_FIELDS) do
            if e[f] ~= nil and type(e[f]) ~= 'number' then return nil, ('%s: %s must be a number'):format(at, f) end
        end
        if e.type == 'enum' then
            if type(e.options) ~= 'table' or #e.options == 0 then return nil, at .. ': an enum needs options' end
            for n, o in ipairs(e.options) do
                if type(o) ~= 'table' or o.value == nil then return nil, ('%s: option %d needs a value'):format(at, n) end
            end
        end
        local entry = {
            key = key, type = e.type, default = e.default,
            label = type(e.label) == 'string' and e.label ~= '' and e.label:sub(1, 60) or key,
            help = type(e.help) == 'string' and e.help:sub(1, 400) or nil,
            min = e.min, max = e.max, step = e.step, maxLen = e.maxLen, unit = type(e.unit) == 'string' and e.unit or nil,
            nullable = e.nullable == true or nil,
            options = e.type == 'enum' and Settings.copy(e.options) or nil,
        }
        -- Its default must pass its own check (and is kept as the check gives it back: 5 as 5.0).
        local called, ok, value = pcall(Settings.check, entry, entry.default)
        if not called or not ok then
            return nil, ('%s: its default %s'):format(at, tostring(called and value or ok))
        end
        entry.default = value
        out[#out + 1] = entry
    end
    if #out == 0 then return nil end
    return out
end

-- ---- Pictures ----

--- One rule of `images` as a page row. A rule testing more than one field keeps the first by name (whip's own test
--- one at most); `amount` with atLeast and atMost the same is "is".
---@param rule table
---@return table row  { image, field, op, value }
function ItemSettings.pictureRow(rule)
    local row = { image = tostring(rule.image or ''), field = '', op = 'is', value = '' }
    local field, t
    if type(rule.amount) == 'table' then
        field, t = 'amount', rule.amount
    elseif type(rule.when) == 'table' then
        local names = {}
        for name in pairs(rule.when) do names[#names + 1] = tostring(name) end
        table.sort(names)
        field = names[1]
        if field then t = rule.when[field] end
    end
    if not field then return row end
    row.field = field
    if type(t) ~= 'table' then
        row.value = t == nil and '' or tostring(t)
    elseif t[1] ~= nil then
        row.value = tostring(t[1])   -- one of a list: the first
    elseif t.empty == false then
        row.op = 'has'
    elseif t.empty == true then
        row.op = 'empty'
    elseif t.atLeast ~= nil and t.atLeast == t.atMost then
        row.value = tostring(t.atLeast)
    else
        for _, op in ipairs({ 'above', 'below', 'atLeast', 'atMost' }) do
            if t[op] ~= nil then
                row.op, row.value = op, tostring(t[op])
                break
            end
        end
    end
    return row
end

--- A page row back as a rule of `images`.
---@param row table  { image, field, op, value }
---@return table rule
function ItemSettings.pictureRule(row)
    local rule = { image = row.image }
    local field, op, value = row.field or '', row.op or 'is', tostring(row.value or '')
    if field == '' then return rule end
    local test
    if op == 'has' then
        test = { empty = false }
    elseif op == 'empty' then
        test = { empty = true }
    elseif NUMBER_OPS[op] then
        test = { [op] = tonumber(value) }
    elseif field == 'amount' then
        local n = tonumber(value)
        test = { atLeast = n, atMost = n }
    elseif value == 'true' or value == 'false' then
        test = value == 'true'
    else
        test = tonumber(value) or value
    end
    if field == 'amount' then rule.amount = test else rule.when = { [field] = test } end
    return rule
end

--- Why an admin's pasted picture is refused, or nil: the lore pictures' rule (server/director/lore.lua), one list of
--- the sites a picture may come from (Config.LorePictureLinks).
---@param url string
---@return string|nil
local function linkProblem(url)
    if not (DirectorLore and DirectorLore.pictureProblem) then return 'Picture links cannot be checked yet' end
    if url == '' then return 'Paste a picture link' end
    return DirectorLore.pictureProblem(url)
end

--- Are these rows an item's pictures? Each picture is one of the definition's own or a link to one; each test
--- one the page offers, with a value it can take. True, or false and why ("Picture 2: ...").
---@param key string
---@param rows any
---@param declared table|nil  the definition's own `images` (default: what it registered)
---@return boolean ok
---@return string|nil why
function ItemSettings.checkPictures(key, rows, declared)
    if type(rows) ~= 'table' then return false, 'Pictures must be a list' end
    if #rows > MAX_PICTURES then return false, ('An item has %d pictures at most'):format(MAX_PICTURES) end
    local ownPaths = {}
    for _, rule in ipairs(declared or declaredPics[key] or {}) do ownPaths[tostring(rule.image)] = true end
    for i, row in ipairs(rows) do
        local at = ('Picture %d: '):format(i)
        local image, field, op = tostring(row.image or ''), tostring(row.field or ''), tostring(row.op or 'is')
        local value = tostring(row.value or '')
        if not ownPaths[image] then
            local why = linkProblem(image)
            if why then return false, at .. why end
        end
        if field ~= '' then
            if field ~= 'amount' and not field:match('^[%a_][%w_]*$') then return false, at .. 'shown by a field name' end
            if NUMBER_OPS[op] and tonumber(value) == nil then return false, at .. 'needs a number to test against' end
            if field == 'amount' then
                if op == 'has' or op == 'empty' then return false, at .. 'a quantity is a number to test against' end
                if tonumber(value) == nil then return false, at .. 'needs a quantity' end
            end
        end
    end
    return true
end

--- The pictures in force as `images`: what was saved, else the definition's own. nil for none.
---@param key string
---@param declared table|nil
---@return table|nil
local function picturesInForce(key, declared)
    local owner = ItemSettings.ownerOf(key)
    local has, rows = Settings.savedValue(owner, 'pictures')
    if has and ItemSettings.checkPictures(key, rows, declared) then
        local out = {}
        for i, row in ipairs(rows) do out[i] = ItemSettings.pictureRule(row) end
        return #out > 0 and out or nil
    end
    return declared and #declared > 0 and Settings.copy(declared) or nil
end

--- A definition's `pictureFields`, checked and copied: { { key, label, type } }. nil for none.
---@param list any
---@param where string
---@return table|nil list
---@return string|nil why
function ItemSettings.cleanPictureFields(list, where)
    if list == nil then return nil end
    if type(list) ~= 'table' then return nil, where .. ': a list of { key, label, type }' end
    if #list > MAX_PICTURE_FIELDS then return nil, ('%s: %d at most'):format(where, MAX_PICTURE_FIELDS) end
    local out, seen = {}, {}
    for i, f in ipairs(list) do
        local at = ('%s %d'):format(where, i)
        if type(f) ~= 'table' then return nil, at .. ' is not a table' end
        if type(f.key) ~= 'string' or not f.key:match('^[%a_][%w_]*$') or #f.key > 40 or f.key == 'amount' then
            return nil, at .. ': key must be a metadata field name (letters, digits and _; not amount)'
        end
        if seen[f.key] then return nil, at .. ' is there twice' end
        seen[f.key] = true
        local kind = f.type or 'text'
        if not PICTURE_FIELD_TYPES[kind] then return nil, at .. ': type must be bool, number or text' end
        out[#out + 1] = { key = f.key, type = kind,
                          label = type(f.label) == 'string' and f.label ~= '' and f.label:sub(1, 40) or f.key }
    end
    if #out == 0 then return nil end
    return out
end

--- What the Items page offers to show a picture by: the count (an item that stacks), the definition's
--- pictureFields, its card's metaFields, and any field its own pictures test. { { key, label, type } }.
---@param key string
---@return table
function ItemSettings.pictureFields(key)
    local def = Config.Items[key]
    if type(def) ~= 'table' then return {} end
    local out, seen = {}, {}
    local function add(k, label, kind)
        if type(k) ~= 'string' or seen[k] then return end
        seen[k] = true
        out[#out + 1] = { key = k, label = label or k, type = kind or 'text' }
    end
    if def.stack then add('amount', 'Quantity', 'number') end
    for _, f in ipairs(def.pictureFields or {}) do add(f.key, f.label, f.type) end
    for _, f in ipairs(type(def.metaFields) == 'table' and def.metaFields or {}) do
        if type(f) == 'table' then add(f.key, type(f.label) == 'string' and f.label or nil, 'text') end
    end
    for _, rule in ipairs(declaredPics[key] or {}) do
        for name, t in pairs(type(rule.when) == 'table' and rule.when or {}) do
            local kind = 'text'
            if type(t) == 'boolean' then kind = 'bool'
            elseif type(t) == 'number' then kind = 'number'
            elseif type(t) == 'table' and (t.above or t.below or t.atLeast or t.atMost) then kind = 'number' end
            add(name, name, kind)
        end
    end
    return out
end

--- The pictures entry on an item's page: its default the definition's own `images`.
---@param key string
---@return table
local function picturesEntry(key)
    local rows = {}
    for i, rule in ipairs(declaredPics[key] or {}) do rows[i] = ItemSettings.pictureRow(rule) end
    return {
        key = 'pictures', type = 'records', label = 'Pictures', default = rows, maxItems = MAX_PICTURES,
        fields = PICTURE_ROW,
        cross = function(get) return ItemSettings.checkPictures(key, get('pictures')) end,
    }
end

-- ---- Hearing a change: the resources that asked, and every player ----

-- '<resource>:<item>|<key>' = fn. On the registration rule (shared/registry.lua): one per resource for
-- each setting (calling again replaces it, so a Whip.register that runs again does not stack them),
-- and gone when that resource stops.
local listeners = {}
local _listeners = Registry.new('ItemSettingListener', {
    label = 'item setting listener', store = listeners, scoped = true, same = false,
})

--- What players are sent of one item: { [key] = value } of its own settings in force.
---@param key string
---@return table
local function valuesOf(key)
    local out = {}
    for _, e in ipairs(own[key] or {}) do out[e.key] = Settings.copy(ItemSettings.get(key, e.key)) end
    return out
end

local pushQueued, pushKeys = false, {}

--- Players sent this item's own settings, with the others that changed in the same tick: an item's
--- page is made two hundred at a time as a resource starts.
---@param key string
local function queuePush(key)
    if not own[key] and not pushed[key] then return end
    pushKeys[key] = true
    if pushQueued then return end
    pushQueued = true
    SetTimeout(0, function()
        pushQueued = false
        local out = {}
        for k in pairs(pushKeys) do
            out[k] = valuesOf(k)
            pushed[k] = own[k] ~= nil or nil
        end
        pushKeys = {}
        TriggerClientEvent('whip_core:client:itemSettings', -1, out, false)
    end)
end

--- A setting of an item's page changed (an admin, a Reset, or its default moving with its resource).
---@param key string
---@param path string
---@param value any
---@param old any
local function changed(key, path, value, old)
    if path == 'pictures' then
        -- Onto its definition: the rows saved, or (Reset) its own `images` again.
        ---@type WhipItemDef|nil
        local def = Config.Items[key]
        if type(def) ~= 'table' then return end
        def.images = picturesInForce(key, declaredPics[key])
        Inventory.invalidateItemDefs()
        if DevTools and DevTools.refresh then DevTools.refresh('ib') end
        return
    end
    if IS_BASE[path] and base[key] then
        -- Onto its definition: what was saved, or the definition's own again (Reset). Every player's
        -- copy of the definitions is then stale, and an open Item Browser redraws.
        local def = Config.Items[key]
        if type(def) ~= 'table' then return end
        local v = base[key][path]
        if Settings.isSaved(ItemSettings.ownerOf(key), path) then v = value end
        def[path] = Settings.copy(v)
        Inventory.invalidateItemDefs()
        if DevTools and DevTools.refresh then DevTools.refresh('ib') end
        return
    end
    local suffix = ':' .. key .. '|' .. path
    for k, fn in pairs(listeners) do
        if k:sub(-#suffix) == suffix then
            local ok, err = pcall(fn, Settings.copy(value), Settings.copy(old), key, path)
            if not ok then
                print(('^1[whip_core:items] %s\'s hook for %s %s errored: %s^0'):format(k:match('^[^:]+'), key, path, tostring(err)))
            end
        end
    end
    queuePush(key)
    -- An open Items page's list counts what was changed.
    if DevTools and DevTools.refresh then DevTools.refresh('ib') end
end

---@param key string
---@param path string
local function listen(key, path)
    local owner = ItemSettings.ownerOf(key)
    hooked[owner] = hooked[owner] or {}
    if hooked[owner][path] then return end
    hooked[owner][path] = true
    Settings.onChange(path, function(value, old) changed(key, path, value, old) end, owner)
end

-- ---- An item's page ----

--- Make (or make again) an item's page: its name, description and weight unless config.lua has them
--- as Config's, then its own settings, then its pictures (every item).
---@param key string
local function declare(key)
    local groups = {}
    if base[key] then
        groups[#groups + 1] = { id = 'item', label = 'The item', settings = baseEntries(base[key]) }
    end
    if own[key] then
        local list = {}
        for i, e in ipairs(own[key]) do list[i] = Settings.copy(e) end
        groups[#groups + 1] = { id = 'own', label = 'Its own', settings = list }
    end
    groups[#groups + 1] = { id = 'pictures', label = 'Pictures', settings = { picturesEntry(key) } }
    for _, g in ipairs(groups) do
        for _, e in ipairs(g.settings) do e.sides = 'server' end
    end
    local ok, why = Settings.register(ItemSettings.ownerOf(key), { label = 'Item', groups = groups }, { quiet = true })
    if not ok then
        print(('^3[whip_core:items] %s: its settings page was not made: %s^0'):format(key, tostring(why)))
        return
    end
    for _, g in ipairs(groups) do
        for _, e in ipairs(g.settings) do listen(key, e.key) end
    end
    queuePush(key)
end

--- What an admin saved for an item's name, description and weight, written onto `definition` where
--- it passes the checks the item's page will make. Answers whether anything was written.
---@param key string
---@param definition table
---@param declared table  { name, desc, weight }: the definition's own
---@return boolean
local function writeSaved(key, definition, declared)
    local owner, any = ItemSettings.ownerOf(key), false
    for _, e in ipairs(baseEntries(declared)) do
        local has, v = Settings.savedValue(owner, e.key)
        if has then
            local ok, checked = Settings.check(e, v)
            if ok and not Settings.same(definition[e.key], checked) then
                definition[e.key] = checked
                any = true
            end
        end
    end
    return any
end

--- RegisterItem's part, before the item is stored (server/inventory.lua): its own settings checked,
--- its name, description and weight kept beside it as declared, and what an admin changed written
--- on. Written on BEFORE it is stored, so registering the same item again stores the same thing and
--- costs nothing (the item registry's no-op). Answers true, or false and why.
---@param key string
---@param definition table  changed in place
---@return boolean ok
---@return string|nil why
function ItemSettings.prepare(key, definition)
    local list, why = ItemSettings.clean(definition.settings, ('item "%s" settings'):format(key))
    if why then return false, why end
    definition.settings = list
    local fields, fieldsWhy = ItemSettings.cleanPictureFields(definition.pictureFields, ('item "%s" pictureFields'):format(key))
    if fieldsWhy then return false, fieldsWhy end
    definition.pictureFields = fields
    if not ItemSettings.inConfig(key) then
        local declared = { name = definition.name, desc = definition.desc, weight = definition.weight,
                           grab = definition.grab, playerWalk = definition.playerWalk }
        definition._declared = declared
        writeSaved(key, definition, declared)
    end
    -- Its pictures: its own kept as the default, an admin's written on (after whip_core is ready; before, at
    -- declareWaiting).
    definition._declaredImages = definition.images and Settings.copy(definition.images) or {}
    if CoreReady == true then definition.images = picturesInForce(key, definition._declaredImages) end
    return true
end

--- config.lua's own item, as whip_core loads (server/inventory.lua): its pictureFields checked, its own pictures
--- kept as the pictures' default. Said and left out when wrong, as its other lists are.
---@param key string
---@param def table
function ItemSettings.prepareConfigItem(key, def)
    local fields, why = ItemSettings.cleanPictureFields(def.pictureFields, ('item "%s" pictureFields'):format(key))
    if why then print(('[whip_core:inv] config.lua %s: left out'):format(why)) end
    def.pictureFields = fields
    def._declaredImages = def.images and Settings.copy(def.images) or {}
end

--- The item registry stored an item (server/inventory.lua's onAdd): its page made from it. Before
--- whip_core is ready it waits (ItemSettings.declareWaiting): the saved values are not read yet.
---@param key string
---@param def table
function ItemSettings.added(key, def)
    base[key] = type(def) == 'table' and def._declared or nil
    declaredPics[key] = type(def) == 'table' and def._declaredImages or {}
    own[key] = type(def) == 'table' and def.settings or nil
    if CoreReady ~= true then
        waiting[key] = true
        return
    end
    declare(key)
end

--- As whip_core becomes ready (server/player_lifecycle.lua): the pages of the items registered while
--- it started (config.lua's, and any registered early), and what was saved for them, written on.
function ItemSettings.declareWaiting()
    local keys = waiting
    waiting = {}
    local any = false
    for key in pairs(keys) do
        local def = Config.Items[key]
        if type(def) == 'table' then
            declare(key)
            if base[key] and writeSaved(key, def, base[key]) then any = true end
            local pics = picturesInForce(key, declaredPics[key])
            if not Settings.same(def.images, pics) then
                def.images = pics
                any = true
            end
        end
    end
    if any then
        Inventory.invalidateItemDefs()
        if DevTools and DevTools.refresh then DevTools.refresh('ib') end
    end
end

-- ---- Reading ----

--- A setting of an item in force: its name, desc or weight from its definition, else one of its own
--- settings (saved, or its default). nil for an unknown item or key.
---@param key string
---@param path string
---@return any
---@diagnostic disable-next-line: duplicate-set-field -- the client's ItemSettings is a different table
function ItemSettings.get(key, path)
    if type(key) ~= 'string' or type(path) ~= 'string' then return nil end
    if IS_BASE[path] then
        local def = Config.Items[key]
        return type(def) == 'table' and def[path] or nil
    end
    for _, e in ipairs(own[key] or {}) do
        if e.key == path then
            -- Its page not made yet (whip_core starting): the default.
            if not Settings.entry(ItemSettings.ownerOf(key), path) then return e.default end
            return Settings.read(ItemSettings.ownerOf(key), path)
        end
    end
    return nil
end

-- ['Items.<key>'] = { entry, ... }: config.lua's items' rows in Config, by item. Made once: Config's
-- page is declared as whip_core loads and never changes after.
local coreForms = nil

---@param key string
---@return table
local function coreEntries(key)
    if not coreForms then
        coreForms = {}
        local page = Settings.page(CORE)
        for _, g in ipairs(page and page.groups or {}) do
            if g.id == 'items' then
                for _, e in ipairs(g.settings) do
                    if e.form then
                        coreForms[e.form] = coreForms[e.form] or {}
                        table.insert(coreForms[e.form], e)
                    end
                end
            end
        end
    end
    return coreForms['Items.' .. key] or {}
end

--- How many of an item's settings an admin has changed (the Items page's list says so).
---@param key string
---@return number
function ItemSettings.changedCount(key)
    local n = 0
    for _, e in ipairs(coreEntries(key)) do
        if Settings.isSaved(CORE, e.path) then n = n + 1 end
    end
    local owner = ItemSettings.ownerOf(key)
    local page = Settings.page(owner)
    for _, g in ipairs(page and page.groups or {}) do
        for _, e in ipairs(g.settings) do
            if Settings.isSaved(owner, e.path) then n = n + 1 end
        end
    end
    return n
end

--- How many settings of its own an item declared.
---@param key string
---@return number
function ItemSettings.ownCount(key)
    return own[key] and #own[key] or 0
end

--- One item's settings as the Items page draws them (in config.js's form, each with its owner, so an
--- Apply names the right page): its name, description and weight (config.lua's from Config, with the
--- rest of Config's fields for it), then its own.
---@param key string
---@return table groups  { { id, label, settings = { ... } } }
function ItemSettings.panel(key)
    local groups = {}
    local function add(id, label, owner, entries)
        local list = Settings.panelSettings(owner, entries)
        for _, s in ipairs(list) do s.owner = owner end
        if #list > 0 then groups[#groups + 1] = { id = id, label = label, settings = list } end
    end
    add('item', 'The item', CORE, coreEntries(key))
    local owner = ItemSettings.ownerOf(key)
    local page = Settings.page(owner)
    for _, g in ipairs(page and page.groups or {}) do add(g.id, g.label, owner, g.settings) end
    return groups
end

SecureCallback('whip_core:itemSettings:get', {
    ace = DEVTOOLS, rateLimit = 150, burst = 10, whileDead = true,
    params = { { 'key', 'key', 60 } },
}, function(source, _, key)
    if not Config.Items[key] then return false, 'There is no item ' .. key end
    return {
        key = key, mayEdit = Settings.mayEdit(source), groups = ItemSettings.panel(key),
        -- Its pictures' editor: what a picture can be shown by, and the sites a pasted one may come from.
        pictureFields = ItemSettings.pictureFields(key),
        pictureLinks = DirectorLore and DirectorLore.pictureLinks() or {},
    }
end)

-- A player's game asks for every item's own settings as it starts, and again when whip_core is
-- ready (client/item_settings.lua). Before then the answer could be missing pages, so it waits for
-- the second ask, as the settings hello does.
SecureEvent('whip_core:server:itemSettingsHello', { rateLimit = 5000, burst = 2, whileDead = true, requirePlayer = false }, function(source)
    if CoreReady ~= true then return end
    local out = {}
    for key in pairs(own) do out[key] = valuesOf(key) end
    TriggerClientEvent('whip_core:client:itemSettings', source, out, true)
end)

-- ---- Exports ----

--- An item's setting in force: one of its own (declared in its `settings`), or its name, desc or
--- weight. nil for an item or key it does not have.
exports('GetItemSetting', function(item, key)
    return Settings.copy(ItemSettings.get(item, key))
end)

--- fn(value, old, item, key) after one of an item's own settings changes, on this side (Reset too).
--- ONE per resource for each setting: calling again replaces it. Answers true, or false and why.
exports('OnItemSettingChanged', function(item, key, fn)
    local owner = Registry.caller()   -- first, before anything can yield
    if type(item) ~= 'string' or type(key) ~= 'string' or fn == nil then
        return false, 'OnItemSettingChanged(item, key, function(value, old, item, key) end)'
    end
    local ok, why = _listeners:add(owner, item .. '|' .. key, fn)
    if not ok then return false, why end
    return true
end)
