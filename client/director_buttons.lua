-- Director: other resources' buttons on a placed thing (Whip.directorButton). A button for a kind of placed thing
-- (car, NPC, spot...) shows on its page, in the world builder's bubble, or both. Pressed, it runs that resource's
-- `press` here inside a pcall, handed the thing:
--   { id, kind, label, model, models, coords = { x, y, z, heading }, scenario, data, entity, builder }
-- `data` is what that resource keeps on the thing; `entity` the world builder's copy while it is open (nil
-- otherwise, and for a button that takes over); `builder` whether it was pressed in the world builder. A random
-- vehicle has `models` (every model a run picks from) and is pressed for one: `model`.
--
-- Saving: thing:save(t) keeps `t` on the thing (w.def.ext[<resource>], plain data, 4 KB at most; nil removes it),
-- as an edit in the open scenario (undone with Ctrl+Z). A run hands it back (whip_core:run:thingMade,
-- card:made(id).data, GetDirectorThingData on the server).
--
-- Taking over: takesOver = true has the Director step out of the way (as recording a take does, client/director.lua
-- DirectorScreen). The resource has the screen until it calls thing:back(t?) (saving `t` first); then the Director
-- returns as it was. Its code throwing, or its resource stopping, also brings it back.

local MAX_DATA = 4096   -- bytes of JSON a resource keeps on one thing (or in one entry of a card's list)
-- `card`: a button for a card's list (an entries field of a Whip.card: server/director/cards_api.lua), pressed on
-- the card's page to add or change an entry. Its thing is the card: { id, kind = 'card', label, scenario, builder,
-- card = { type, field, entry (number, nil for a new one), value, props, world } }, world being the card's placed
-- things by field. thing:save(t) keeps t as that entry (a new one is added, then changed by later saves); nil removes it.
local THING_KINDS = DirectorThings.with('builder')
THING_KINDS.card = true
local WHERE = { both = true, page = true, bubble = true }

local Buttons = {}   -- [id] = { id, owner, label, icon, hint, kinds, where, takesOver, entry }

local presses = {}   -- [token] = { owner, button, id, takesOver, builder }: a press its resource may still save from
local takeover = nil -- the token of the press that has the screen now

local callable, text = DirectorKit.callable, DirectorKit.text

--- A plain copy (8 deep, no functions), or nil.
local function plain(v) return DirectorKit.plain(v) end

--- The buttons as the page draws them (no code): by resource, then label.
local function list()
    local out = {}
    for _, b in pairs(Buttons) do
        out[#out + 1] = { id = b.id, owner = b.owner, label = b.label, icon = b.icon, hint = b.hint, kinds = b.kinds,
                          where = b.where, takesOver = b.takesOver }
    end
    table.sort(out, function(a, b)
        if a.owner ~= b.owner then return a.owner < b.owner end
        return a.label < b.label
    end)
    return out
end

local function pushList()
    if DirectorEditorOpen then SendNUIMessage({ action = 'directorButtonsChanged', buttons = list() }) end
end

--- The press that has the screen is over: the Director again, on the thing in the world builder if pressed there.
local function comeBack(token)
    local p = presses[token]
    if not p or not p.takesOver or p.back then return end
    p.back = true
    presses[token] = nil
    if takeover == token then takeover = nil end
    -- (A card's press: the builder again on the thing it names.)
    DirectorScreen.back(p.builder and (p.reopen or p.id) or nil, p.aside)
end

-- The Director closed (death, logout, Exit) while a press had the screen or could still save: those presses are over.
DirectorScreen.onClose(function()
    presses = {}
    takeover = nil
end)

local ButtonReg = Registry.new('directorButton', {
    label = 'Director button', store = Buttons,
    -- (A restarted resource hands in a new entry: every registration replaces.)
    same = false,
    onAdd = function() pushList() end,
    onRemove = function(_, b, owner)
        -- (Its resource stopped while it had the screen: the Director comes back.)
        for token, p in pairs(presses) do
            if p.owner == owner and p.button == (b and b.id) then
                if p.takesOver then comeBack(token) else presses[token] = nil end
            end
        end
        pushList()
    end,
})

--- One of a resource's buttons, as kept here, or nil and why.
local function buttonOf(owner, id, spec, entry)
    if type(id) ~= 'string' or #id > 64 or not id:match('^[%a][%w_]*%.[%a][%w_]*$') then
        return nil, 'a button\'s id is "<your namespace>.<name>", like autos.customise'
    end
    if type(spec) ~= 'table' or callable(spec) or spec.__whipButton == nil or not callable(entry) then
        return nil, 'use Whip.directorButton (@whip_core/lib/satellite.lua)'
    end
    local label = text(spec.label, 24)
    if not label or label:match('^%s*$') then return nil, id .. ': it needs a label (24 letters at most)' end
    local b = { id = id, owner = owner, label = label, hint = text(spec.hint, 120), entry = entry,
                takesOver = spec.takesOver == true, where = spec.where == nil and 'both' or spec.where, kinds = {} }
    if not WHERE[b.where] then return nil, id .. ": where is 'page', 'bubble' or 'both'" end
    if spec.icon ~= nil then
        if type(spec.icon) ~= 'string' or #spec.icon > 24 or not spec.icon:match('^[%w_%-]+$') then
            return nil, id .. ': icon is one of whip\'s icons by its key (html/js/glyphs.js)'
        end
        b.icon = spec.icon
    end
    if type(spec.kinds) ~= 'table' or callable(spec.kinds) or #spec.kinds == 0 then
        return nil, id .. ': kinds is a list of placed things: npc, vehicle, prop, spot, groundItem, container, door, route '
            .. '(or card: a card\'s list)'
    end
    for _, k in ipairs(spec.kinds) do
        if not THING_KINDS[k] then return nil, ('%s: "%s" is not a kind of placed thing'):format(id, tostring(k)) end
        b.kinds[#b.kinds + 1] = k
    end
    return b
end

-- The page: the list, and a press

RegisterNUICallback('directorButtons', function(_, cb)
    cb({ buttons = list() })
end)

--- A button pressed on a thing's page or in the bubble. d = { button, thing = { id, kind, label, model, coords,
--- scenario }, data, builder }: the page's view of the thing.
RegisterNUICallback('directorButtonPress', function(d, cb)
    local b = type(d) == 'table' and type(d.button) == 'string' and Buttons[d.button] or nil
    local t = type(d) == 'table' and type(d.thing) == 'table' and d.thing or nil
    if not DirectorEditorOpen or not b or not t or type(t.id) ~= 'string' or #t.id > 64 then
        cb({ ok = false, why = 'That button is not here any more' })
        return
    end
    local fits = false
    for _, k in ipairs(b.kinds) do if k == t.kind then fits = true end end
    if not fits then cb({ ok = false, why = 'That button is not for this kind of thing' }) return end
    if takeover then cb({ ok = false, why = 'Another button has the screen' }) return end

    -- A card's list: which list, and which entry (nil: a new one).
    local card
    if t.kind == 'card' then
        local c = type(t.card) == 'table' and t.card or {}
        local entry = c.entry ~= nil and math.tointeger(tonumber(c.entry)) or nil
        if type(c.type) ~= 'string' or #c.type > 64 or type(c.field) ~= 'string' or #c.field > 24
           or (c.entry ~= nil and not (entry and entry >= 1 and entry <= 12)) then
            cb({ ok = false, why = 'That card\'s list is not readable' })
            return
        end
        card = { type = c.type, field = c.field, entry = entry, value = plain(c.value), props = plain(c.props), world = plain(c.world) }
    end

    -- Where it is now: the world builder's copy while open.
    local coords = type(t.coords) == 'table' and plain(t.coords) or nil
    local entity
    local it = FurnishBuilder and FurnishBuilder.itemOf and FurnishBuilder.itemOf(t.id) or nil
    if it then
        coords = { x = it.x, y = it.y, z = it.z, heading = it.rz or 0.0 }
        if not b.takesOver and it.obj and DoesEntityExist(it.obj) then entity = it.obj end
    end

    local token = ('%08x%06x'):format(math.random(0, 0x7fffffff), GetGameTimer() % 0x1000000)
    -- (Older presses of the same button on the same thing are done.)
    for k, p in pairs(presses) do
        if p.button == b.id and p.id == t.id then presses[k] = nil end
    end
    -- (A card's: its list and entry, for the saves, and the thing the builder reopens on.)
    presses[token] = { owner = b.owner, button = b.id, id = t.id, takesOver = b.takesOver, builder = d.builder == true,
                       card = card and { field = card.field, entry = card.entry } or nil, reopen = text(t.back, 64) }
    if b.takesOver then
        local asideN = DirectorScreen.aside()
        if not asideN then
            presses[token] = nil
            cb({ ok = false, why = 'The Director cannot step aside now' })
            return
        end
        presses[token].aside = asideN
        takeover = token
    end
    cb({ ok = true })

    -- A random vehicle's models, each a name (pressed for one of them: `model`).
    local models
    if t.kind == 'vehicle' and type(t.models) == 'table' then
        models = {}
        for i = 1, math.min(#t.models, 8) do
            local m = text(t.models[i], 64)
            if m and m ~= '' then models[#models + 1] = m end
        end
    end
    local thing = { id = t.id, kind = t.kind, label = text(t.label, 60), model = t.model, models = models, coords = coords,
                    scenario = text(t.scenario, 64), data = plain(d.data), entity = entity, builder = d.builder == true,
                    card = card }
    local ok, res = pcall(b.entry, 'press', { token = token, thing = thing })
    if not ok or type(res) ~= 'table' or res.err ~= nil then
        local why = ok and type(res) == 'table' and res.err or res
        print(('[whip_core:director] %s\'s button %s failed: %s'):format(b.owner, b.id, tostring(why or 'its code threw an error')))
        UI.Notify(('%s did not work'):format(b.label), 'error')
        comeBack(token)
    end
end)

-- Exports

--- __RegisterDirectorButton(id, spec, entry) -> true | false, why. Through Whip.directorButton only.
exports('__RegisterDirectorButton', function(id, spec, entry)
    local owner = Registry.caller()
    local b, why = buttonOf(owner, id, spec, entry)
    if not b then return false, why end
    return ButtonReg:add(owner, id, b)
end)

--- __RemoveDirectorButton(id) -> true | false, why. Only your own.
exports('__RemoveDirectorButton', function(id)
    return ButtonReg:remove(Registry.caller(), id)
end)

--- __DirectorButtonDo(token, op, data?) -> true | false, why. Behind thing:save and thing:back: 'save' keeps `data`
--- on the thing (nil removes it), 'back' hands the screen back, saving `data` first when given.
exports('__DirectorButtonDo', function(token, op, data)
    local by = Registry.caller()
    local p = type(token) == 'string' and presses[token] or nil
    if not p or p.owner ~= by then return false, 'that press is over' end
    if not DirectorEditorOpen then
        presses = {}
        takeover = nil
        return false, 'the Director is closed'
    end
    if op ~= 'save' and op ~= 'back' then return false, "op is 'save' or 'back'" end
    if op == 'back' and not p.takesOver then return false, 'only a button that takes over hands the screen back' end
    if op == 'save' or data ~= nil then
        local copy = plain(data)
        if data ~= nil and copy == nil then return false, 'data is plain data (a table, text, a number), or nil' end
        local okJson, s = pcall(json.encode, copy)
        if not okJson then return false, 'data could not be written as JSON' end
        if #s > MAX_DATA then return false, ('data is %d bytes of JSON at most'):format(MAX_DATA) end
        -- (A card's list: that entry, and the press, so later saves change the entry it added.)
        SendNUIMessage({ action = 'directorThingData', id = p.id, owner = p.owner, data = copy, card = p.card, press = token })
    end
    if op == 'back' then comeBack(token) end
    return true
end)
