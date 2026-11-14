-- ============================================
-- WEAPON CATALOG — GTA's own weapons, and those other resources add
-- ============================================
--
-- GTA's are shared/gta_weapons.lua, each firearm's world model shared/gta_weapon_models.lua. A resource that streams
-- weapons of its own (add-on weapons in its own weapons.meta: whip_gunny's WEAPON_WHIP_*) adds them with Whip.weapons
-- (@whip_core/lib/satellite.lua), on both sides, and everything whip lists weapons in offers them beside GTA's: the
-- Director's NPC weapons, its Hold a Weapon step, its Fixed Weapons (a firearm with a world model), Dungeon Mode, the
-- Object Viewer's Give a weapon. Each says whose it is: "Pump Shotgun (gunny)". They go when that resource stops.
--
-- Everything reads weapons through here (get, modelOf, weaponOf, list), never GtaWeapons alone.
--
-- SHARED: the server and each game keep their own list. The server's decides what Check and a run accept; a game's what
-- its editor and world builder offer (only those that game has: they ask it).

WeaponCatalog = { version = 0 }

local MAX_WEAPONS = 200   -- one resource's list
local MAX_LABEL = 40
local MAX_TAG = 16

-- Every group GTA's list has, in its order; the firearms' (a world model) from shared/gta_weapon_models.lua.
local GROUP_AT, GROUP_ORDER = {}, {}
for _, w in ipairs(GtaWeapons.list) do
    if not GROUP_AT[w.group] then
        GROUP_ORDER[#GROUP_ORDER + 1] = w.group
        GROUP_AT[w.group] = #GROUP_ORDER
    end
end
local FIREARM = {}
for _, g in ipairs(GtaWeaponModels.groups) do FIREARM[g] = true end

local added = {}     -- [NAME] = { name, label, group, model?, from }: what other resources add
local byModel = {}   -- [model] = NAME, of those added with one
local goneWith = {}  -- [NAME] = the resource that added it, since it stopped (Check says so)
local listeners = {}

local function changed()
    WeaponCatalog.version = WeaponCatalog.version + 1
    for _, fn in ipairs(listeners) do
        local ok, err = pcall(fn)
        if not ok then print(('[whip_core:weapons] a listener failed: %s'):format(tostring(err))) end
    end
end

local reg = Registry.new('weapons', {
    label = 'weapon', store = added,
    onAdd = function(name, w, _, old)
        if old and old.model and byModel[old.model] == name then byModel[old.model] = nil end
        if w.model then byModel[w.model] = name end
        goneWith[name] = nil
        changed()
    end,
    onRemove = function(name, w, owner, why)
        if w.model and byModel[w.model] == name then byModel[w.model] = nil end
        if why == 'stopped' then goneWith[name] = owner end
        changed()
    end,
})

-- ============================================
-- Reading
-- ============================================

--- A weapon by its name (any case): GTA's { name, label, group }, or one added { name, label, group, model?, from }.
--- Nil when it is neither.
function WeaponCatalog.get(name)
    if type(name) ~= 'string' then return nil end
    local up = name:upper()
    return GtaWeapons.byName[up] or added[up]
end

--- A firearm's world model, or nil (no such firearm here, or one added without a model).
function WeaponCatalog.modelOf(name)
    local m = GtaWeaponModels.modelOf(name)
    if m then return m end
    local w = type(name) == 'string' and added[name:upper()] or nil
    return w and w.model or nil
end

--- The firearm a world model is, or nil.
function WeaponCatalog.weaponOf(model)
    return GtaWeaponModels.weaponOf(model) or (type(model) == 'string' and byModel[model:lower()]) or nil
end

--- What a list shows for it: its label, and whose for one added ("Pump Shotgun (gunny)").
function WeaponCatalog.title(w)
    if type(w) ~= 'table' then return nil end
    return w.from and ('%s (%s)'):format(w.label, w.from) or w.label
end

--- The resource that added it, when it has stopped since (nil while it runs, or for a name nobody added).
function WeaponCatalog.goneWith(name)
    return type(name) == 'string' and goneWith[name:upper()] or nil
end

--- Every weapon, GTA's and those added: by group (GTA's order), each group by label, GTA's first where two share one.
--- The same table until the catalog changes: read it, never write it.
local listed, listedAt
function WeaponCatalog.list()
    if listed and listedAt == WeaponCatalog.version then return listed end
    local out = {}
    for _, w in ipairs(GtaWeapons.list) do out[#out + 1] = w end
    for _, w in pairs(added) do out[#out + 1] = w end
    table.sort(out, function(a, b)
        local ga, gb = GROUP_AT[a.group], GROUP_AT[b.group]
        if ga ~= gb then return ga < gb end
        if a.label ~= b.label then return a.label < b.label end
        if (a.from ~= nil) ~= (b.from ~= nil) then return a.from == nil end
        return a.name < b.name
    end)
    listed, listedAt = out, WeaponCatalog.version
    return out
end

--- Call `fn` whenever weapons are added or go (no arguments; read the catalog again).
function WeaponCatalog.onChange(fn)
    listeners[#listeners + 1] = fn
end

-- ============================================
-- Adding: Whip.weapons (__AddWeapons)
-- ============================================

local function readWeapon(e, i, tag)
    if type(e) ~= 'table' then return nil, ('weapon %d is a table: { name, label, group, model }'):format(i) end
    local name = type(e.name) == 'string' and e.name:upper() or nil
    if not name or #name > 64 or not name:match('^WEAPON_[A-Z0-9_]+$') then
        return nil, ('weapon %d: name is WEAPON_ and capitals, digits or _, like WEAPON_MY_PUMP'):format(i)
    end
    if GtaWeapons.byName[name] then return nil, ('%s is one of GTA\'s own: it is listed already'):format(name) end
    local label = type(e.label) == 'string' and e.label:gsub('%c', ' '):match('^%s*(.-)%s*$') or ''
    if label == '' or #label > MAX_LABEL then return nil, ('%s: label is text, %d characters at most'):format(name, MAX_LABEL) end
    if not GROUP_AT[e.group] then
        return nil, ('%s: group is one of %s'):format(name, table.concat(GROUP_ORDER, ', '))
    end
    local model = nil
    if e.model ~= nil then
        if not FIREARM[e.group] then return nil, ('%s: only a firearm has a world model (not %s)'):format(name, e.group) end
        model = type(e.model) == 'string' and e.model:lower() or nil
        if not model or #model > 64 or not model:match('^[%w_]+$') then return nil, ('%s: model is a model\'s name'):format(name) end
        if GtaWeaponModels.weaponOf(model) then
            return nil, ('%s: %s is GTA\'s %s\'s model'):format(name, model, GtaWeaponModels.weaponOf(model))
        end
    end
    return { name = name, label = label, group = e.group, model = model, from = tag }
end

--- __AddWeapons(list, opts) -> true | false, why. Through Whip.weapons. `list`: { { name, label, group, model? } };
--- opts.tag: shown beside each label (16 characters; the resource's name unless given). The caller's whole list: one
--- it gave before that is not in this one goes. Nothing is added when any of it is refused.
exports('__AddWeapons', function(list, opts)
    local owner = Registry.caller()
    if type(list) ~= 'table' then return false, 'Whip.weapons(list): a list of { name, label, group, model }' end
    if #list > MAX_WEAPONS then return false, ('%d weapons at most'):format(MAX_WEAPONS) end
    local tag = type(opts) == 'table' and opts.tag or nil
    if tag ~= nil then
        tag = type(tag) == 'string' and tag:gsub('%c', ' '):match('^%s*(.-)%s*$') or ''
        if tag == '' or #tag > MAX_TAG then return false, ('tag is text, %d characters at most'):format(MAX_TAG) end
    else
        tag = owner
    end
    local read, seen, models = {}, {}, {}
    for i, e in ipairs(list) do
        local w, why = readWeapon(e, i, tag)
        if not w then return false, why end
        if seen[w.name] then return false, ('%s is in the list twice'):format(w.name) end
        local o = reg:ownerOf(w.name)
        if o ~= nil and o ~= owner and Registry.alive(o) then return false, ('%s belongs to %s'):format(w.name, o) end
        if w.model then
            if models[w.model] then return false, ('%s and %s have the same model, %s'):format(models[w.model], w.name, w.model) end
            local at = byModel[w.model]
            if at and at ~= w.name and reg:ownerOf(at) ~= owner then
                return false, ('%s: %s is %s\'s model already'):format(w.name, w.model, at)
            end
            models[w.model] = w.name
        end
        seen[w.name] = true
        read[#read + 1] = w
    end
    -- Theirs no longer listed go first (a model may pass from one to another of theirs), then each added or changed.
    for _, name in ipairs(reg:keysOf(owner)) do
        if not seen[name] then reg:remove(owner, name) end
    end
    for _, w in ipairs(read) do
        local ok, why = reg:add(owner, w.name, w)
        if not ok then return false, why end
    end
    return true
end)

--- __RemoveWeapons() -> true. All of the caller's (they go by themselves when it stops).
exports('__RemoveWeapons', function()
    local owner = Registry.caller()
    for _, name in ipairs(reg:keysOf(owner)) do reg:remove(owner, name) end
    return true
end)
