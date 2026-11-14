-- Director check and compile. Check reads a saved scenario document against the card types (DirectorNodes) and lists
-- every problem, each pinned to its card so the editor can badge it. An error blocks activation; warnings do not.
-- Compile turns a checked document into the lookup tables a run walks (cards by id, where each output pin leads,
-- which inputs are wired, which cards are events); a revision is compiled once and shared read-only by its runs.
-- The document: { format (DirectorDoc.FORMAT), nodes = { {id, type, v, x, y, props} },
-- links = { {id, from = {node, pin}, to = {node, pin}} }, vars = { {id, type, default} },
-- world = { {id, kind, layer, def} }, settings = {...} }. Ids are strings; pins are names. Check reads it through
-- DirectorDoc.load first.

DirectorGraph = {}

-- What a scenario may be. Past any of these Check says so and stops (a document of thousands could
-- hold the server for seconds).
local MAX_NODES = 400
local MAX_LINKS = 1200
local MAX_WORLD = 1000   -- placed things (the World tab)
local MAX_VARS  = 200

local function problem(list, severity, node, message, pin)
    list[#list + 1] = { severity = severity, node = node, pin = pin, message = message }
end

--- A problem about a placed thing (the World tab): `nodes` are the cards that name it, so the editor
--- can light them all up, and `world` is the thing itself.
local function worldProblem(list, severity, message, worldId, nodes, tab)
    list[#list + 1] = { severity = severity, message = message, world = worldId, nodes = nodes, tab = tab }
end

-- (What the server has, an item, a job, a lore character, a weapon, a plate, is asked of DirectorFields: fields.lua.)
local Fields = DirectorFields

--- The cards whose fields name placed thing `id` (by their fields' kinds: DirectorFields.worldIds), sorted.
---@return string[]
function DirectorGraph.usesOfWorld(doc, id)
    local out = {}
    for _, n in ipairs(type(doc) == 'table' and doc.nodes or {}) do
        local def = type(n) == 'table' and DirectorNodes.get(n.type)
        local props = def and type(n.props) == 'table' and n.props or {}
        if def then
            for _, f in ipairs(def.props) do
                if Fields.namesWorld(f, props[f.key], id, doc.world) then out[#out + 1] = n.id break end
            end
        end
    end
    table.sort(out)
    return out
end

local function placed(c)
    return type(c) == 'table' and tonumber(c.x) ~= nil and tonumber(c.y) ~= nil and tonumber(c.z) ~= nil
end

-- ============================================
-- What a scenario says about itself to other resources (the Director API)
-- ============================================
--
-- Two Settings a builder fills in for scripts: its KIND ("heist, crime": a police script tells a
-- heist from a courier job) and WHERE IT HAPPENS (a placed thing: the bank, not the job giver).

local MAX_KINDS, MAX_KIND_LEN = 6, 24

--- A Kind's words: text with commas ("heist, crime"; the Settings field) or a list (a document made in
--- code). Answers them lower-cased, in order, each once, and any word that is not one (for Check).
---@return string[] kinds
---@return string|nil bad
function DirectorGraph.kindsOf(settings)
    local raw = type(settings) == 'table' and settings.kinds or nil
    local words = {}
    if type(raw) == 'string' then
        for w in raw:gmatch('[^,]+') do words[#words + 1] = w end
    elseif type(raw) == 'table' then
        for _, w in ipairs(raw) do words[#words + 1] = w end
    end
    local out, seen, bad = {}, {}, nil
    for _, w in ipairs(words) do
        local s = type(w) == 'string' and w:match('^%s*(.-)%s*$'):lower() or nil
        if s and s ~= '' then
            if #s > MAX_KIND_LEN or not s:match('^[%w][%w %-]*$') then
                bad = bad or s
            elseif not seen[s] then
                seen[s] = true
                out[#out + 1] = s
            end
        end
    end
    return out, bad
end

--- The model a run makes a placed car as (Spawn Car, a take's car): its own, or for a RANDOM VEHICLE (the world
--- builder's first Vehicles tile: def.random, def.models = { { model, chance } } from its page's Models) one of its
--- models by their chances (0-100 each; all at 0 reads as all alike). Its own when the list has none.
---@param def table  the placed car's def
---@return string|nil model
function DirectorGraph.carModel(def)
    if def.random ~= true or type(def.models) ~= 'table' then return def.model end
    local list, total = {}, 0
    for _, m in ipairs(def.models) do
        if type(m) == 'table' and type(m.model) == 'string' and m.model ~= '' then
            local chance = math.max(0, tonumber(m.chance) or 0)
            list[#list + 1] = { model = m.model, chance = chance }
            total = total + chance
        end
    end
    if #list == 0 then return def.model end
    if total <= 0 then return list[math.random(#list)].model end
    local r = math.random() * total
    for _, m in ipairs(list) do
        r = r - m.chance
        if r < 0 then return m.model end
    end
    return list[#list].model
end

--- Where a scenario's runs happen, for scripts: its "Where it happens" thing, else the thing its runs
--- start at. { world = id, label, coords = { x, y, z } }, or nil when neither is placed.
---@param doc table  a document, or a compiled graph (both carry settings, and world by id or as a list)
---@return table|nil
function DirectorGraph.whereOf(doc)
    local settings = type(doc) == 'table' and type(doc.settings) == 'table' and doc.settings or {}
    local start = type(settings.start) == 'table' and settings.start or {}
    local function find(id)
        if type(id) ~= 'string' or type(doc.world) ~= 'table' then return nil end
        if doc.world[id] then return doc.world[id] end
        for _, w in ipairs(doc.world) do if type(w) == 'table' and w.id == id then return w end end
        return nil
    end
    local function at(id)
        local w = find(id)
        local c = w and type(w.def) == 'table' and w.def.coords or nil
        if not w or not c or not placed(c) then return nil end
        return { world = id, label = type(w.label) == 'string' and w.label ~= '' and w.label or id,
                 coords = { x = tonumber(c.x), y = tonumber(c.y), z = tonumber(c.z) } }
    end
    -- The start's thing only for a start that HAS one: a "where" left from an earlier mode is not it.
    local PLACED = { interaction = true, press = true, area = true, timer = true }
    return at(settings.where) or (PLACED[start.mode or 'admin'] and at(start.world)) or nil
end

-- (What each kind of placed thing must say besides where it is, and whether it may stand: shared/director/things.lua.)
local Things = DirectorThings

--- The run's props a Show Prop card brings in: those it names (its groups' too), and with "their groups too", every run
--- prop sharing one's group (nodes_props.lua DirectorNodes.showPropsOf says which).
local function shownProps(doc, world)
    local shown, groups = {}, {}
    for _, n in ipairs(type(doc.nodes) == 'table' and doc.nodes or {}) do
        local p = type(n) == 'table' and n.type == 'prop.show' and type(n.props) == 'table' and n.props or nil
        if p and p.prop ~= nil then
            for _, id in ipairs(DirectorNodes.showPropsOf(doc, p)) do shown[id] = true end
            for _, x in ipairs(type(p.prop) == 'table' and p.prop or { p.prop }) do
                local w = world[x]
                local g = w and type(w.def) == 'table' and w.def.group
                if p.withGroup == true and type(g) == 'string' and g ~= '' then groups[g] = true end
            end
        end
    end
    return shown, groups
end

--- The World tab's things, and the start: everything a run will need to find in the world.
local function checkWorld(doc, world, problems)
    local start = type(doc.settings) == 'table' and type(doc.settings.start) == 'table' and doc.settings.start or {}
    -- The placed thing the start is at, when its mode has one (a "where" left over from another mode
    -- is not needed).
    local PLACED_STARTS = { interaction = true, press = true, area = true, timer = true }
    local startAt = PLACED_STARTS[start.mode or 'admin'] and start.world or nil
    local settings = type(doc.settings) == 'table' and doc.settings or {}
    local whereAt = type(settings.where) == 'string' and settings.where or nil
    local shownBy, shownGroups = shownProps(doc, world)
    -- Which cards name each placed thing (as DirectorGraph.usesOfWorld answers it), in one pass over the
    -- cards: asked once per placed thing, Check would cost placed things × cards × fields.
    local usesOf = {}
    for _, n in ipairs(type(doc.nodes) == 'table' and doc.nodes or {}) do
        local def = type(n) == 'table' and DirectorNodes.get(n.type)
        local props = def and type(n.props) == 'table' and n.props or nil
        if def and props then
            local named = {}
            for _, f in ipairs(def.props) do
                for _, id in ipairs(Fields.worldIds(f, props[f.key], nil, world)) do
                    if type(id) == 'string' and not named[id] then
                        named[id] = true
                        local list = usesOf[id]
                        if not list then list = {}; usesOf[id] = list end
                        list[#list + 1] = n.id
                    end
                end
            end
        end
    end
    for _, list in pairs(usesOf) do table.sort(list) end
    -- The cards by id (a task's Wait for a card names one); the cars a Give Car Key card gives the key of.
    local cardsById, keyGiven = {}, {}
    for _, n in ipairs(type(doc.nodes) == 'table' and doc.nodes or {}) do
        if type(n) == 'table' and type(n.id) == 'string' then cardsById[n.id] = n end
        if type(n) == 'table' and n.type == 'vehicle.dropKey' and type(n.props) == 'table' and type(n.props.car) == 'string' then
            keyGiven[n.props.car] = true
        end
    end
    local ids = {}
    for id in pairs(world) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local w = world[id]
        local name = type(w.label) == 'string' and w.label ~= '' and w.label or id
        local def = type(w.def) == 'table' and w.def or {}
        local uses = usesOf[id] or {}
        -- A prop no card names but that one shows with "its group too" is needed all the same.
        local byGroup = w.kind == 'prop' and type(def.group) == 'string' and def.group ~= '' and shownGroups[def.group] == true
        local needed = w.layer == 'standing' or #uses > 0 or startAt == id or whereAt == id or byGroup
        -- (A route is its points: server/director/routes.lua says what it lacks, not this.)
        if w.kind ~= 'route' and not placed(def.coords) then
            if needed then
                worldProblem(problems, 'error', ('"%s" is not placed yet: place it in the World tab'):format(name), id, uses, 'world')
            else
                worldProblem(problems, 'warning', ('"%s" is not placed, and no card uses it'):format(name), id, uses, 'world')
            end
        end
        local need = Things.is(w.kind, 'needs')
        if not Things.get(w.kind) then
            worldProblem(problems, 'error', ('"%s" is a "%s", which is not a kind of thing the Director has'):format(name, tostring(w.kind)),
                id, uses, 'world')
        elseif Things.is(w.kind, 'runOnly') and w.layer == 'standing' then
            -- A run makes it (Spawn Car, Create Container) or holds it (Lock / Unlock Door), and its end puts it back:
            -- nothing would put a standing one away.
            worldProblem(problems, 'error', (Things.is(w.kind, 'notStanding') or ('"%%s" is the scenario\'s: a %s is made by a card, never Always present')
                :format(Things.is(w.kind, 'noun'))):format(name), id, uses, 'world')
        end
        if need and (type(def[need.key]) ~= 'string' or def[need.key] == '') then
            worldProblem(problems, 'error', ('"%s" has no %s yet (World tab)'):format(name, need.what), id, uses, 'world')
        elseif w.kind == 'groundItem' and not Fields.isItem(def.item) then
            worldProblem(problems, 'error', ('"%s" is "%s", which is not an item on this server'):format(name, tostring(def.item)),
                id, uses, 'world')
        end
        if w.kind == 'prop' and def.weapon ~= nil then
            -- A Fixed Weapon is a firearm with a world model, GTA's or one a running resource adds
            -- (shared/weapon_catalog.lua): any other name has no model, and nothing to fire.
            if not WeaponCatalog.modelOf(def.weapon) then
                local from = WeaponCatalog.goneWith(def.weapon)
                worldProblem(problems, 'error', (from and '"%s": "%s" comes from %s, which is not running'
                    or '"%s": "%s" is not a firearm this server has (pick its Gun in the World tab)')
                    :format(name, tostring(def.weapon), from), id, uses, 'world')
            end
            -- What it rides on: one of the scenario's cars, NPCs or props, never itself, never round in a ring.
            local to = type(def.attach) == 'table' and def.attach.to or nil
            if type(to) == 'string' and to ~= '' then
                local p = world[to]
                if not p then
                    worldProblem(problems, 'error', ('"%s" is attached to "%s", which is not placed in this scenario'):format(name, to), id, uses, 'world')
                elseif p.kind ~= 'vehicle' and p.kind ~= 'npc' and p.kind ~= 'prop' then
                    worldProblem(problems, 'error', ('"%s" can ride on a car, an NPC or a prop, not a %s'):format(name, tostring(p.kind)), id, uses, 'world')
                elseif w.layer == 'standing' then
                    worldProblem(problems, 'warning', ('"%s" is standing: it stays where it was placed (only one a run shows rides on what it is attached to)')
                        :format(name), id, uses, 'world')
                else
                    ---@type table, string|nil
                    local seen, at = { [id] = true }, to
                    while type(at) == 'string' and world[at] do
                        if seen[at] then
                            worldProblem(problems, 'error', ('"%s" is attached round in a ring (each on the next)'):format(name), id, uses, 'world')
                            break
                        end
                        seen[at] = true
                        local pd = type(world[at].def) == 'table' and world[at].def or {}
                        at = type(pd.attach) == 'table' and pd.attach.to or nil
                    end
                end
            end
        end
        if w.kind == 'npc' then
            -- An NPC carries a weapon (never a whip item), GTA's or one a running resource adds: a misspelt one
            -- would leave it unarmed with nothing said.
            local wpn = type(def.weapon) == 'table' and def.weapon.name or def.weapon
            if wpn ~= nil and wpn ~= '' and not Fields.isWeapon(wpn) then
                local from = WeaponCatalog.goneWith(wpn)
                worldProblem(problems, 'error', (from and '"%s": "%s" comes from %s, which is not running'
                    or '"%s": "%s" is not a weapon this server has (pick one in the World tab)')
                    :format(name, tostring(wpn), from), id, uses, 'world')
            end
            -- Its look from the character editor: one Npcs would refuse would leave it never made.
            local lwhy = def.look ~= nil and not def.lore and Fields.lookProblem(def.look)
            if lwhy then
                worldProblem(problems, 'error', ('"%s": its look from the character editor cannot be used (%s): make it again on its page (Outfit)')
                    :format(name, lwhy), id, uses, 'world')
            end
        end
        -- Its tasks (server/director/tasks.lua): each step it could not play, and tasks a run never plays.
        if DirectorTasks.has(w) then
            local _, probs = DirectorTasks.compile(w.kind, def.tasks, world, w)
            for _, pr in ipairs(probs) do
                worldProblem(problems, 'error', ('"%s", task %d (%s): %s'):format(name, pr.i, pr.label, pr.why), id, uses, 'world')
            end
            -- A Wait for a card: its card is one of the scenario's, each outcome picked is one that card has, and
            -- the NPC is one a run makes (a standing one has no run to wait on: it passes the Wait over).
            for i, raw in ipairs(type(def.tasks.list) == 'table' and def.tasks.list or {}) do
                if type(raw) == 'table' and DirectorSteps.waitsOnCard(raw.t, raw) and type(raw.card) == 'string' then
                    local node = cardsById[raw.card]
                    local ndef = node and DirectorNodes.get(node.type)
                    if not ndef then
                        worldProblem(problems, 'error', ('"%s", task %d (Wait): its card is not in the scenario any more'):format(name, i),
                            id, uses, 'world')
                    else
                        for _, pin in ipairs(type(raw.outs) == 'table' and raw.outs or {}) do
                            local has = false
                            for _, o in ipairs(type(ndef.outputs) == 'table' and ndef.outputs or {}) do if o == pin then has = true end end
                            if not has then
                                worldProblem(problems, 'error', ('"%s", task %d (Wait): its card has no outcome "%s"'):format(name, i, tostring(pin)),
                                    id, uses, 'world')
                            end
                        end
                    end
                    if w.layer == 'standing' then
                        worldProblem(problems, 'warning', ('"%s", task %d (Wait): it is standing, so it has no run to wait on: passed over')
                            :format(name, i), id, uses, 'world')
                    end
                end
            end
            if w.layer == 'standing' and w.kind == 'prop' then
                worldProblem(problems, 'warning', ('"%s" has tasks, but it is standing: a prop\'s tasks play on what a run makes (Show Prop)')
                    :format(name), id, uses, 'world')
            elseif w.layer == 'standing' and w.kind == 'npc' then
                -- (A standing NPC plays its list by itself, passing over what needs a run: nodes_tasks.lua playStanding.)
                for i, raw in ipairs(type(def.tasks) == 'table' and type(def.tasks.list) == 'table' and def.tasks.list or {}) do
                    local skip = type(raw) == 'table' and DirectorTasks.standingSkip(raw.t) or nil
                    if skip then
                        local d = DirectorTasks.get(raw.t)
                        worldProblem(problems, 'warning', ('"%s", task %d (%s): it is standing, so this is passed over: %s')
                            :format(name, i, d and d.label or raw.t, skip), id, uses, 'world')
                    end
                end
            end
        end
        -- A route (server/director/routes.lua), and what a guard sees.
        for _, pr in ipairs(DirectorRoutes.problems(w)) do
            worldProblem(problems, pr.severity, ('"%s": %s'):format(name, pr.why), id, uses, 'world')
        end
        if w.kind == 'npc' and type(def.vision) == 'table' and def.vision.on == true and w.layer == 'standing' then
            worldProblem(problems, 'warning', ('"%s" sees players, but it is Always present: a guard sees the scenario\'s players, so it must be one the scenario makes (Spawn NPC)')
                :format(name), id, uses, 'world')
        end
        -- A random vehicle (the world builder's first Vehicles tile): the models a run picks from (carModel).
        if w.kind == 'vehicle' and def.random == true then
            local n = 0
            for _, m in ipairs(type(def.models) == 'table' and def.models or {}) do
                if type(m) == 'table' and type(m.model) == 'string' and m.model ~= '' then n = n + 1 end
            end
            if n == 0 then
                worldProblem(problems, 'error', ('"%s" is a vehicle pool with no models yet: add them on its page'):format(name),
                    id, uses, 'world')
            elseif n == 1 then
                worldProblem(problems, 'warning', ('"%s" is a vehicle pool with one model: it is always that one'):format(name),
                    id, uses, 'world')
            end
        end
        if w.kind == 'door' then
            -- Picked off the door itself (World tab): its model is the hash the game answers, a number.
            if type(def.model) ~= 'number' then
                worldProblem(problems, 'error', ('"%s" has no door picked yet: aim at the door in the World tab'):format(name),
                    id, uses, 'world')
            end
        end
        -- A spot's marker (its page; server/director/spots.lua): a look whip draws, 1-30 m a side, and who sets it off.
        local m = w.kind == 'spot' and type(def.marker) == 'table' and def.marker or nil
        if m and m.look ~= nil and m.look ~= 'none' then
            local function bad(message) worldProblem(problems, 'error', message:format(name), id, uses, 'world') end
            local function side(v) return v == nil or (type(v) == 'number' and v >= 1 and v <= 30) end
            if m.look ~= 'circle' and m.look ~= 'square' and m.look ~= 'garage' then
                bad('"%s": its marker is not one whip draws (a circle, a square or a garage bay)')
            elseif m.look ~= 'garage' and not (side(m.w) and (m.look ~= 'square' or side(m.l))) then
                bad('"%s": its marker is 1-30 metres a side')
            end
            if m.activate ~= nil and m.activate ~= 'one' and m.activate ~= 'all' and m.activate ~= 'vehicle' and m.activate ~= 'thing' then
                bad('"%s": what sets its marker off is not one of the choices')
            elseif m.activate == 'thing' then
                local t = type(m.thing) == 'string' and world[m.thing] or nil
                if not t then
                    bad('"%s" is set off by a placed thing in it, but none is picked (its Marker)')
                elseif t.kind ~= 'npc' and t.kind ~= 'vehicle' then
                    bad('"%s" is set off by a placed thing in it: pick an NPC or a car (its Marker)')
                end
            end
        end
        if w.kind == 'prop' and w.layer ~= 'standing' then
            -- The run's: made only when a Show Prop card shows it (or one of its group).
            local g = def.group
            if not shownBy[id] and not (type(g) == 'string' and g ~= '' and shownGroups[g]) then
                worldProblem(problems, 'warning', ('"%s" only activates via card, but no Show Prop card shows it (make it Always present to have it there while the scenario is on)')
                    :format(name), id, uses, 'world')
            end
        end
        if w.kind == 'vehicle' then
            -- Its trailer (Tows): another of the scenario's cars. And the trailers its takes hitched: each still placed.
            if def.tow ~= nil and def.tow ~= '' then
                local t = type(def.tow) == 'string' and world[def.tow] or nil
                if not t or t.kind ~= 'vehicle' or def.tow == id then
                    worldProblem(problems, 'error', ('"%s" tows "%s", which is not another of this scenario\'s cars (its page: Tows)')
                        :format(name, tostring(def.tow)), id, uses, 'world')
                end
            end
            for _, tk in ipairs(type(def.takes) == 'table' and def.takes or {}) do
                local tracks = type(tk) == 'table' and type(tk.tow) == 'table' and type(tk.tow.tracks) == 'table' and tk.tow.tracks or {}
                for wid in pairs(tracks) do
                    if not (type(wid) == 'string' and world[wid] and world[wid].kind == 'vehicle') then
                        worldProblem(problems, 'warning', ('"%s": %s hitched "%s", which is not placed any more: it plays without it')
                            :format(name, tostring(tk.label or ('driving event ' .. tostring(tk.id))), tostring(wid)), id, uses, 'world')
                    end
                end
            end
            -- Its key (Key settings): somewhere to be, a placed key spot when that is the ground, a card that gives it
            -- when a card does.
            local key = type(def.key) == 'table' and def.key or nil
            if key and key.exists == true then
                local KEY_WHERE = { world = true, ignition = true, glovebox = true, trunk = true, player = true, card = true }
                if not KEY_WHERE[key.where] then
                    worldProblem(problems, 'error', ('"%s" has a key, but where it is is not picked (Key settings)'):format(name), id, uses, 'world')
                elseif key.where == 'card' and not keyGiven[id] then
                    worldProblem(problems, 'warning', ('"%s": its key is given by a card, but no Give Car Key card gives it'):format(name),
                        id, uses, 'world')
                elseif key.where == 'world' then
                    local spot = type(key.spot) == 'string' and world[key.spot] or nil
                    local c = spot and type(spot.def) == 'table' and spot.def.coords or nil
                    if not (type(c) == 'table' and tonumber(c.x)) then
                        worldProblem(problems, 'error', ('"%s": its key is placed in the world, but its key spot is not placed yet (Key settings)')
                            :format(name), id, uses, 'world')
                    end
                end
            elseif keyGiven[id] then
                worldProblem(problems, 'warning', ('"%s" has no key (Key settings), but a Give Car Key card gives it one'):format(name),
                    id, uses, 'world')
            end
        end
        -- A car's key spot: of a car that is still here.
        if w.kind == 'groundItem' and type(def.keyOf) == 'string' then
            local car = world[def.keyOf]
            if not (car and car.kind == 'vehicle') then
                worldProblem(problems, 'warning', ('"%s" is the key spot of a car that is not here any more'):format(name), id, uses, 'world')
            end
        end
        if w.kind == 'vehicle' then
            local plate = def.plate
            local hasPlate = plate ~= nil and plate ~= ''
            local why = hasPlate and Fields.plateProblem(plate)
            if why then
                worldProblem(problems, 'error', ('"%s": %s'):format(name, why), id, uses, 'world')
            elseif #uses > 0 and not DirectorGraph.checkingVariant
                and (tonumber(type(doc.settings) == 'table' and doc.settings.maxConcurrentRuns) or 1) > 1 then
                -- Every run makes it on the same spot (and a plate is one car), so while one run's car is
                -- there, a second run at the same time gets none. (A variant has one run at a time.)
                worldProblem(problems, 'warning', ('"%s": every run makes it on the same spot%s, so only one run at a time gets it (Runs at once is more than 1)')
                    :format(name, hasPlate and ' with the same plate' or ''), id, uses, 'world')
            end
        end
    end
    local mode = start.mode or 'admin'
    local function startProblem(severity, message) worldProblem(problems, severity, message, start.world, {}, 'settings') end
    if mode == 'interaction' then
        local w = start.world ~= nil and world[start.world] or nil
        if not w or w.kind ~= 'npc' or w.layer ~= 'standing' then
            startProblem('error', 'It starts by talking to an NPC, but no NPC set to Always present is picked for it (Scenario Enabled)')
        end
    elseif mode == 'press' or mode == 'area' or mode == 'timer' then
        local how = mode == 'press' and 'pressing something' or mode == 'area' and 'a player coming near' or 'a timer'
        local w = start.world ~= nil and world[start.world] or nil
        if not w then
            startProblem('error', ('It starts by %s, but no placed thing is picked for where (Scenario Enabled)'):format(how))
        elseif mode == 'press' and w.layer ~= 'standing' and w.kind ~= 'spot' then
            -- A run's own NPC, car, prop or container is not there before a run: the prompt floats.
            startProblem('warning', ('The start prompt is on "%s", which the scenario makes: before it starts it is not there, so the prompt is at its spot alone')
                :format(tostring(w.label or w.id)))
        end
        -- Coming into a spot with a marker: before a run there is no crew and no thing of its own.
        local m = mode == 'area' and w and w.kind == 'spot' and type(w.def) == 'table' and type(w.def.marker) == 'table'
            and w.def.marker or nil
        if w and m and (m.look == 'circle' or m.look == 'square' or m.look == 'garage') then
            if m.activate == 'thing' then
                startProblem('error', ('It starts by coming into "%s", whose marker a placed thing sets off: before it starts there is none (pick Any player or A vehicle)')
                    :format(tostring(w.label or w.id)))
            elseif m.activate == 'all' then
                startProblem('warning', ('It starts by coming into "%s": before it starts there is no crew, so All players is Any player there')
                    :format(tostring(w.label or w.id)))
            end
        end
        if mode ~= 'press' and start.radius ~= nil and not (type(start.radius) == 'number' and start.radius >= 1 and start.radius <= 500) then
            startProblem('error', 'It starts: the distance is 1-500 metres (Scenario Enabled)')
        end
        if mode == 'timer' and not (type(start.every) == 'number' and start.every >= 1 and start.every <= 1440) then
            startProblem('error', 'It starts on a timer: how often is 1-1440 minutes (Scenario Enabled)')
        end
    elseif mode == 'item' then
        local key = start.item
        if type(key) ~= 'string' or key == '' then
            startProblem('error', 'A run starts by using an item, but no item is picked (Scenario Enabled)')
        elseif not Fields.isItem(key) then
            startProblem('error', ('A run starts by using "%s", which is not an item on this server (Scenario Enabled)'):format(key))
        else
            local owner = Director.itemUseOwner(key)
            if owner then
                startProblem('error', ('"%s" already does something when used (%s): pick an item with no use of its own (Settings)')
                    :format(key, tostring(owner)))
            elseif not Fields.isUsable(key) then
                startProblem('error', ('"%s" cannot be used: its item definition needs usable = true'):format(key))
            end
        end
    elseif mode ~= 'admin' and mode ~= 'script' and mode ~= 'always' and mode ~= 'enabled' then
        -- ('always': the engine's own, started by hand and never ended by its players leaving. 'enabled': When it's
        -- switched on, main.lua Director.openRun.)
        startProblem('error', ('A run starts: "%s" is not one of the choices (Settings)'):format(tostring(mode)))
    end
    -- What scripts are told about it (Kind, Where it happens).
    if whereAt and not world[whereAt] then
        worldProblem(problems, 'error', ('Where it happens: "%s" is not a placed thing any more (Settings)'):format(whereAt),
            nil, {}, 'settings')
    end
    local kinds, badKind = DirectorGraph.kindsOf(settings)
    if badKind then
        worldProblem(problems, 'error', ('Kind: "%s" is not a word for it (letters, digits, spaces and -, up to %d)'):format(badKind, MAX_KIND_LEN),
            nil, {}, 'settings')
    elseif #kinds > MAX_KINDS then
        worldProblem(problems, 'error', ('Kind: at most %d words'):format(MAX_KINDS), nil, {}, 'settings')
    end
    -- How many one of its runs takes, the starter included (Team size). Empty: the most a run can.
    local most = (Director and Director.MAX_CREW) or 16
    local team = settings.teamSize
    if team ~= nil and not (type(team) == 'number' and team % 1 == 0 and team >= 1 and team <= most) then
        worldProblem(problems, 'error', ('Team size is a whole number from 1 to %d (Settings)'):format(most), nil, {}, 'settings')
    end
    -- Each player's wait after a job of it (main.lua cooldowns), in minutes: a week at most. Empty or 0: none.
    local cd = settings.cooldownMin
    if cd ~= nil and not (type(cd) == 'number' and cd % 1 == 0 and cd >= 0 and cd <= 10080) then
        worldProblem(problems, 'error', 'Cooldown is a whole number of minutes, 0 to 10080 (a week) (Scenario Enabled)', nil, {}, 'settings')
    end
    -- Who waits: 'everyone' in the job (empty: the same) or only the 'starter' (main.lua cooldownWho)
    local who = settings.cooldownWho
    if who ~= nil and who ~= 'everyone' and who ~= 'starter' then
        worldProblem(problems, 'error', 'Cooldown is for everyone in the job, or only who started it (Scenario Enabled)', nil, {}, 'settings')
    end
end

local function isId(s) return type(s) == 'string' and #s >= 1 and #s <= 64 and s:match('^[%w_%-]+$') ~= nil end

local function has(list, x)
    for _, v in ipairs(list) do if v == x then return true end end
    return false
end

--- The items a scenario itself places or gives, as a set of keys: its item spots (not a car's key spot) and what its
--- cards that give items hold (a card's givesItems: Give Item, Drop Item, Put in Car, Create Container's slots; a
--- variant's own things and cards too). A goal for the scenario's own items picks from these (kind runItem; the
--- page's own list: panels.js scenarioItems).
---@param doc table
---@return table<string, true>
function DirectorGraph.scenarioItems(doc)
    local out = {}
    local function add(k) if type(k) == 'string' and k ~= '' then out[k] = true end end
    local function scan(world, nodes)
        for _, w in ipairs(type(world) == 'table' and world or {}) do
            if type(w) == 'table' and w.kind == 'groundItem' and type(w.def) == 'table' and type(w.def.keyOf) ~= 'string' then add(w.def.item) end
        end
        for _, n in ipairs(type(nodes) == 'table' and nodes or {}) do
            local d = type(n) == 'table' and DirectorNodes.get(n.type)
            if d and d.givesItems and type(n.props) == 'table' then
                add(n.props.item)
                for _, e in ipairs(type(n.props.loot) == 'table' and n.props.loot or {}) do
                    if type(e) == 'table' then add(e.item) end
                end
            end
        end
    end
    if type(doc) == 'table' then
        scan(doc.world, doc.nodes)
        for _, v in ipairs(type(doc.variants) == 'table' and doc.variants or {}) do
            if type(v) == 'table' then scan(v.world, v.nodes) end
        end
    end
    return out
end


--- Check one document, read by DirectorDoc.load already (a scenario with no variants, or one variant of one:
--- DirectorGraph.check).
local function checkOne(doc)
    local problems = {}
    local nodes, links = doc.nodes or {}, doc.links or {}
    local over = (#nodes > MAX_NODES and ('more than %d cards'):format(MAX_NODES))
        or (#links > MAX_LINKS and ('more than %d wires'):format(MAX_LINKS))
        or (#(doc.world or {}) > MAX_WORLD and ('more than %d placed things'):format(MAX_WORLD))
        or (#(doc.vars or {}) > MAX_VARS and ('more than %d variables'):format(MAX_VARS))
    if over then
        problem(problems, 'error', nil, over)
        return false, problems
    end
    -- Another resource's card checks (cards_api.lua) read the scenario's variables and placed things:
    -- worked out once for this Check, not once per card.
    DirectorGraph.checking = { doc = doc }

    local vars, world = {}, {}
    for _, v in ipairs(doc.vars or {}) do
        if type(v) ~= 'table' or not isId(v.id) then problem(problems, 'error', nil, 'a variable has no usable name')
        elseif vars[v.id] then problem(problems, 'error', nil, 'two variables are called ' .. v.id)
        else vars[v.id] = v end
    end
    for _, w in ipairs(doc.world or {}) do
        if type(w) ~= 'table' or not isId(w.id) then problem(problems, 'error', nil, 'a placed thing has no usable id')
        elseif world[w.id] then problem(problems, 'error', nil, 'two placed things share the id ' .. w.id)
        elseif w.def ~= nil and type(w.def) ~= 'table' then problem(problems, 'error', nil, ('placed thing %s is not readable'):format(w.id))
        else world[w.id] = w end
    end

    local byId = {}
    local cx = { vars = vars, world = world, doc = doc }   -- (what a field is checked against: DirectorFields.check)
    for _, n in ipairs(nodes) do
        if type(n) ~= 'table' or not isId(n.id) then
            problem(problems, 'error', nil, 'a card has no usable id')
        elseif n.props ~= nil and type(n.props) ~= 'table' then
            problem(problems, 'error', n.id, 'this card\'s fields are not readable')
        elseif byId[n.id] then
            problem(problems, 'error', n.id, 'two cards share this id')
        else
            byId[n.id] = n
            local def = DirectorNodes.get(n.type)
            if not def then
                problem(problems, 'error', n.id, ('unknown card type "%s" (a resource that adds it may not be running)'):format(tostring(n.type)))
            else
                -- Made with a newer version of the card than this server has (another resource's, updated
                -- elsewhere): it may expect what this one does not do.
                if math.type(n.v) == 'integer' and math.type(def.v) == 'integer' and n.v > def.v then
                    problem(problems, 'warning', n.id, ('made with a newer %s (version %d; this server has %d)'):format(tostring(def.title), n.v, def.v))
                end
                -- (A field its card hides, its `when` not holding, is not counted: the page does not show it.)
                local props = n.props or {}
                for _, f in ipairs(def.props) do
                    if Fields.holds(f.when, props, def.props) then
                        local msg = Fields.check(f, props[f.key], cx)
                        if msg then problem(problems, 'error', n.id, msg) end
                    end
                end
                -- What no one field can know: how the fields fit together (a menu's shape). An error,
                -- unless the card says 'warning' with it (a fixed plate).
                if def.check then
                    local ok, msg, severity = pcall(def.check, n.props or {}, doc)
                    if not ok then problem(problems, 'error', n.id, 'this card could not be checked: ' .. tostring(msg))
                    elseif msg then problem(problems, severity == 'warning' and 'warning' or 'error', n.id, tostring(msg)) end
                end
            end
        end
    end

    -- Wires: from an OUTPUT pin to an INPUT pin, both real. (pinTo: where each outcome leads, for the dead ends below.)
    -- (outsOf: a card's own wired outcomes, by card, for a card whose outcome is one only while wired: unusedPin's 4th.)
    local out, seenLink, wiredOut, wiredIn, pinTo, outsOf = {}, {}, {}, {}, {}, {}
    for _, l in ipairs(links) do
        local f, t = type(l) == 'table' and l.from or nil, type(l) == 'table' and l.to or nil
        if type(f) ~= 'table' or type(t) ~= 'table' or type(f.node) ~= 'string' or type(t.node) ~= 'string'
            or type(f.pin) ~= 'string' or type(t.pin) ~= 'string' then
            problem(problems, 'error', nil, 'a wire is broken')
        else
            local fn, tn = byId[f.node], byId[t.node]
            local fd, td = fn and DirectorNodes.get(fn.type), tn and DirectorNodes.get(tn.type)
            if not fn or not tn then
                problem(problems, 'error', f.node, 'a wire goes to a card that does not exist')
            elseif fd and not has(fd.outputs, f.pin) then
                problem(problems, 'error', f.node, ('a wire leaves from "%s", which this card does not have'):format(tostring(f.pin)), f.pin)
            elseif td and not has(td.inputs, t.pin) then
                problem(problems, 'error', t.node, ('a wire arrives at "%s", which this card does not have'):format(tostring(t.pin)), t.pin)
            else
                local key = f.node .. '.' .. f.pin .. '>' .. t.node .. '.' .. t.pin
                if seenLink[key] then
                    problem(problems, 'warning', f.node, 'the same wire is drawn twice', f.pin)
                else
                    seenLink[key] = true
                    out[f.node] = out[f.node] or {}
                    out[f.node][#out[f.node] + 1] = t.node
                    wiredOut[f.node .. '.' .. f.pin] = true
                    outsOf[f.node] = outsOf[f.node] or {}
                    outsOf[f.node][f.pin] = true
                    local pk = f.node .. '.' .. f.pin
                    pinTo[pk] = pinTo[pk] or {}
                    pinTo[pk][#pinTo[pk] + 1] = t.node
                    wiredIn[t.node] = wiredIn[t.node] or {}
                    wiredIn[t.node][t.pin] = true
                end
            end
        end
    end

    checkWorld(doc, world, problems)

    -- A card that starts tasks (its definition's `startsTasksFor`: Start Tasks) wired straight after a card that makes
    -- the thing and starts its tasks itself (its `makes` and `startsTasks`: Spawn NPC's Start their tasks, on by
    -- default): they start twice, the second time from the top. Both said by the cards, nothing here by type.
    for id, n in pairs(byId) do
        local d = DirectorNodes.get(n.type)
        local made = d and DirectorNodes.startsTasksOf(n) and DirectorNodes.makesOf(n, doc) or {}
        for _, to in ipairs(next(made) and pinTo[id .. '.out'] or {}) do
            local list = DirectorNodes.startsTasksForOf(byId[to])
            for _, wid in ipairs(list) do
                if d and made[wid] and DirectorTasks.has(world[wid]) then
                    local switch = 'Start their tasks'
                    for _, f in ipairs(d.props or {}) do if f.key == 'tasks' then switch = f.label end end
                    problem(problems, 'warning', to, ('%s already starts "%s"\'s tasks as it makes it (its %s): this card starts them again from the top. Take %s, or switch %s off on that card')
                        :format(d.title, tostring(world[wid].label or wid), switch, #list > 1 and 'it off this card' or 'this card out', switch))
                end
            end
        end
    end

    -- Something must start it, and every card should be reachable from something that does. (A Fail Condition is
    -- neither: it watches the whole run, wired to nothing: nodes_conditions.lua. An Activate After card starts its own
    -- chain once the run is over: what it leads to is reached, never a way for the run to succeed.)
    local starts, watchers, afters = {}, {}, {}
    for id, n in pairs(byId) do
        local d = DirectorNodes.get(n.type)
        if d and d.condition then watchers[id] = true
        elseif d and d.after then afters[#afters + 1] = id
        elseif d and d.event then starts[#starts + 1] = id end
    end
    if #starts == 0 then problem(problems, 'error', nil, 'nothing starts this scenario (add a Scenario Enabled card)') end
    local reached = {}
    local stack = {}
    for _, id in ipairs(starts) do stack[#stack + 1] = id end
    for _, id in ipairs(afters) do stack[#stack + 1] = id end
    while #stack > 0 do
        local id = table.remove(stack)
        if not reached[id] then
            reached[id] = true
            for _, to in ipairs(out[id] or {}) do stack[#stack + 1] = to end
        end
    end
    for id in pairs(byId) do
        if not reached[id] and not watchers[id] then problem(problems, 'warning', id, 'nothing leads to this card, so it never runs') end
    end

    -- An outcome of a waiting card (or a branch like If) that goes nowhere is how a run gets stuck.
    -- An outcome the card can never take, given its fields (a Dialog Line's empty answer), is not
    -- a dead end: it is no outcome at all. A wire from one is the mistake instead.
    local function pinName(d, props, pin)
        if d.pinName then
            local ok, s = pcall(d.pinName, props, pin)
            if ok and type(s) == 'string' then return s end
        end
        return ('the "%s" outcome'):format((d.labels and d.labels[pin]) or pin)
    end

    -- DEAD ENDS: an outcome after which a run can be left with nothing waiting, so it ends neither succeeded nor
    -- failed ("nothing left to wait for": runtime.lua). A warning: wiring every Walked away and No answer of a long
    -- talk is not asked for. A run that can never SUCCEED is the error (below).
    --   A card STOPS (can leave the run with nothing waiting) when an outcome it can take stops; an outcome stops when
    --   it goes nowhere, or every card it is wired to stops (all of a wire's cards run). Succeed, Fail and Call Off
    --   never stop. Do in Order (`together`) stops only when every outcome does; Start Tasks (`goesOn = 'out'`, out at
    --   once while it still waits) only when Started does and one of its others too. Worked out to a fixed point, so a
    --   loop that waits is not a stop. Only what the Scenario Enabled reaches is said (another event card is its own
    --   start, and while one listens a run is never empty), and nothing in a lead-in (before a Scenario Run Started By
    --   Player card, or from its Not now): a run that ends there ends quietly, as it should.
    local ENDS = { ['scenario.succeed'] = true, ['scenario.fail'] = true, ['scenario.calloff'] = true }
    local function possible(id, d, pin)
        if d.quietPins and d.quietPins[pin] then return false end
        return not DirectorNodes.pinUnused(d, byId[id].props or {}, pin, wiredIn[id], outsOf[id])
    end
    local stops = {}
    local function pinStops(id, pin)
        for _, to in ipairs(pinTo[id .. '.' .. pin] or {}) do
            if not stops[to] then return false end
        end
        return true
    end
    local function cardStops(id, d)
        if ENDS[byId[id].type] then return false end
        local any, all, some = false, true, false
        for _, pin in ipairs(d.outputs or {}) do
            if possible(id, d, pin) then
                some = true
                local s = pinStops(id, pin)
                if s and pin ~= d.goesOn then any = true end
                if not s then all = false end
            end
        end
        if d.together then return some and all end
        if d.goesOn then return any and pinStops(id, d.goesOn) end
        return any or (not some and not d.latent)
    end
    local changed = true
    while changed do
        changed = false
        for id, n in pairs(byId) do
            local d = DirectorNodes.get(n.type)
            if d and not stops[id] and cardStops(id, d) then stops[id], changed = true, true end
        end
    end
    local otherEvents = false
    for _, n in pairs(byId) do
        local d = DirectorNodes.get(n.type)
        if d and d.event and not d.condition and n.type ~= 'scenario.started' then otherEvents = true end
    end
    local hasBegin = false
    for _, n in pairs(byId) do
        if n.type == 'scenario.begin' then hasBegin = true break end
    end
    local deadEnd, walked = {}, {}
    local function walk(id, pre)
        local key = pre and (id .. '|pre') or id
        if walked[key] then return end
        walked[key] = true
        local n = byId[id]
        local d = DirectorNodes.get(n.type)
        if not d then return end
        for _, pin in ipairs(d.outputs or {}) do
            -- (Scenario Run Started By Player's Started ends the lead-in; its Not now does not.)
            local stillPre = pre and not (n.type == 'scenario.begin' and pin == 'started')
            if possible(id, d, pin) and pinStops(id, pin) then
                local to = pinTo[id .. '.' .. pin]
                if to then
                    for _, t in ipairs(to) do walk(t, stillPre) end
                elseif not stillPre and not d.together and pin ~= d.goesOn and not (n.type == 'scenario.started' and otherEvents) then
                    deadEnd[id .. '.' .. pin] = true
                    problem(problems, 'warning', id, ('%s goes nowhere: coming out here, the scenario has nothing left to wait for, '
                        .. 'and ends neither succeeded nor failed (wire it on, or to Succeed, Fail or Call Off)')
                        :format(pinName(d, n.props or {}, pin)), pin)
                end
            end
        end
    end
    for id, n in pairs(byId) do
        if n.type == 'scenario.started' and stops[id] then walk(id, hasBegin) end
    end

    -- HANDED OUT IN THE LEAD-IN: a card that gives something before Scenario Run Started By Player can be had again and
    -- again (talk, take it, walk away, talk again: a lead-in ends quietly, with no cooldown). What gives is the card's
    -- own say (givesItems, handsOut). Another resource's card is not known: its code may give or not.
    if hasBegin then
        local seen, todo = {}, {}
        for id, n in pairs(byId) do
            if n.type == 'scenario.started' then todo[#todo + 1] = id end
        end
        while #todo > 0 do
            local id = table.remove(todo)
            if not seen[id] then
                seen[id] = true
                local n = byId[id]
                local d = DirectorNodes.get(n.type)
                if d and (d.givesItems or d.handsOut) then
                    problem(problems, 'warning', id, 'this hands something out before Scenario Started By Player: a player could take it, '
                        .. 'walk away and come back for more (a lead-in ends quietly, with no cooldown)')
                end
                for _, pin in ipairs(d and d.outputs or {}) do
                    if not (n.type == 'scenario.begin' and pin == 'started') then
                        for _, to in ipairs(pinTo[id .. '.' .. pin] or {}) do todo[#todo + 1] = to end
                    end
                end
            end
        end
    end

    -- CAN A RUN SUCCEED? A Succeed card reached from what starts it, through outcomes that can happen. An outcome never
    -- happens when its card says so from its fields (pinWhen: a Dialog Line's empty answer) or from the world
    -- (neverPin: Start Tasks' Finished, for tasks that start again when they end). None reached: the run is
    -- unpassable, an error that keeps it from being switched on (`live`: a Test still runs, to try a job half made).
    -- Another resource's card, or the script that starts it, may end a run itself (a success too): then a warning.
    local never = {}   -- ['<id>.<pin>'] = why it never comes
    for id, n in pairs(byId) do
        local d = DirectorNodes.get(n.type)
        if d and d.neverPin then
            for _, pin in ipairs(d.outputs or {}) do
                local ok, why = pcall(d.neverPin, n.props or {}, pin, world)
                if ok and type(why) == 'string' then never[id .. '.' .. pin] = why end
            end
        end
    end
    local function canFire(id, d, pin, strict)
        if strict and never[id .. '.' .. pin] then return false end
        return not DirectorNodes.pinUnused(d, byId[id].props or {}, pin, wiredIn[id], outsOf[id])
    end
    local function reachFrom(strict)
        local seen, todo = {}, {}
        for _, id in ipairs(starts) do todo[#todo + 1] = id end
        while #todo > 0 do
            local id = table.remove(todo)
            if not seen[id] then
                seen[id] = true
                local d = DirectorNodes.get(byId[id].type)
                for _, pin in ipairs(d and d.outputs or {}) do
                    if canFire(id, d, pin, strict) then
                        for _, to in ipairs(pinTo[id .. '.' .. pin] or {}) do todo[#todo + 1] = to end
                    end
                end
            end
        end
        return seen
    end
    local startMode = type(doc.settings) == 'table' and type(doc.settings.start) == 'table' and doc.settings.start.mode or 'admin'
    local blocker
    if startMode ~= 'always' and #starts > 0 then
        local reachedStrict, reachedLoose = reachFrom(true), reachFrom(false)
        local hasSucceed, strictOk, looseOk, satellite = false, false, false, false
        for id, n in pairs(byId) do
            if n.type == 'scenario.succeed' then
                hasSucceed = true
                if reachedStrict[id] then strictOk = true end
                if reachedLoose[id] then looseOk = true end
            end
            local d = DirectorNodes.get(n.type)
            if d and d.satellite then satellite = true end
        end
        if not strictOk then
            local why
            if not hasSucceed then
                why = 'there is no Succeed card: the scenario can never succeed (add one where the job is done)'
            elseif looseOk then
                -- An outcome that never comes is the only way to it: the first such one a run can reach, by id.
                local keys = {}
                for key in pairs(never) do keys[#keys + 1] = key end
                table.sort(keys)
                for _, key in ipairs(keys) do
                    local id, pin = key:match('^(.+)%.([^.]+)$')
                    if id and reachedLoose[id] and pinTo[key] then
                        local d = DirectorNodes.get(byId[id].type)
                        blocker = { id = id, pin = pin, key = key }
                        why = ('%s never comes: %s, so the scenario can never reach a Succeed card'):format(pinName(d, byId[id].props or {}, pin), never[key])
                        break
                    end
                end
            end
            why = why or 'nothing leads to a Succeed card: the scenario can never succeed'
            local severity = 'error'
            if satellite then
                severity, why = 'warning', why .. ' (unless another resource\'s card ends it)'
            elseif startMode == 'script' then
                severity, why = 'warning', why .. ' (unless the script that starts it ends it)'
            elseif startMode == 'enabled' and not hasSucceed then
                -- (Switched on, it may only put things out: its run stays up, with nobody in it, while it is on.)
                severity, why = 'warning', why .. ' (fine for one that only puts things out while it is switched on)'
            end
            problems[#problems + 1] = { severity = severity, node = blocker and blocker.id or nil, pin = blocker and blocker.pin or nil,
                                        message = why, live = severity == 'error' or nil }
        end
    end
    -- (Any other outcome that never comes but is wired: said, as a wire from one that can never happen.)
    for key, why in pairs(never) do
        if pinTo[key] and not (blocker and blocker.key == key) then
            local id, pin = key:match('^(.+)%.([^.]+)$')
            local d = id and DirectorNodes.get(byId[id].type)
            if d then problem(problems, 'warning', id, ('%s has a wire, but never comes: %s'):format(pinName(d, byId[id].props or {}, pin), why), pin) end
        end
    end

    for id, n in pairs(byId) do
        local d = DirectorNodes.get(n.type)
        if d and (d.latent or d.branch) then
            local props = n.props or {}
            for _, pin in ipairs(d.outputs) do
                local unused = DirectorNodes.pinUnused(d, props, pin, wiredIn[id], outsOf[id])
                local wired = wiredOut[id .. '.' .. pin]
                if unused and wired then
                    problem(problems, 'warning', id, ('%s has a wire, but can never happen'):format(pinName(d, props, pin)), pin)
                -- (A quiet pin is fine unwired: another resource's Didn't Work faults the run with why.)
                elseif not unused and not wired and not (d.quietPins and d.quietPins[pin]) and not deadEnd[id .. '.' .. pin] then
                    local msg = ('%s goes nowhere'):format(pinName(d, props, pin))
                    if pin == 'timeout' then msg = msg .. ' (the scenario would stop here)' end
                    problem(problems, 'warning', id, msg, pin)
                end
            end
        end
    end

    -- A loop must pass through a card that waits, or one pulse would go round it for ever.
    local instant = {}
    for id, n in pairs(byId) do
        local d = DirectorNodes.get(n.type)
        instant[id] = d ~= nil and not d.latent and not d.event
    end
    local state = {}   -- nil unvisited, 1 on the path, 2 done
    local function dfs(id)
        state[id] = 1
        for _, to in ipairs(out[id] or {}) do
            if instant[to] then
                if state[to] == 1 then
                    problem(problems, 'error', to, 'this card is in a loop that never waits (add a Wait to the loop)')
                elseif state[to] == nil then
                    dfs(to)
                end
            end
        end
        state[id] = 2
    end
    for id in pairs(byId) do
        if instant[id] and state[id] == nil then dfs(id) end
    end

    DirectorGraph.checking = nil
    for _, p in ipairs(problems) do
        if p.severity == 'error' then return false, problems end
    end
    return true, problems
end

-- ============================================
-- Variants (Multi Run Variants)
-- ============================================
--
-- A scenario can hold more than one VARIANT of its job. Variant 1 is the document's own cards, wires, comment boxes
-- and placed things; the others are doc.variants = { { id = 'v2', name, nodes, links, world, comments } }. All of
-- them share the scenario's name, settings (how a run starts, its limits, how a variant is picked: variantPick,
-- variantOrder), variables, and its SHARED placed things (sharedIds), kept once in doc.world: a variant's own world
-- holds only its own run things. One run plays one variant (main.lua Director.pickVariant). A document with no
-- variants is exactly as before. Nothing outside this file reads doc.variants: what walks a document's cards or
-- things walks DirectorGraph.variantsOf.

DirectorGraph.MAX_VARIANTS = 8
local PICKS = { sequential = true, random = true, order = true }

--- The placed things every variant shares: what stands while the scenario is on (made before any run picks a
--- variant), the start's placed thing (one start for all), and what those name: a task step's thing.
---@return table set  [id] = true
function DirectorGraph.sharedIds(doc)
    local world = {}
    for _, w in ipairs(type(doc.world) == 'table' and doc.world or {}) do
        if type(w) == 'table' and type(w.id) == 'string' then world[w.id] = w end
    end
    local shared, queue = {}, {}
    local function add(id)
        if type(id) == 'string' and world[id] and not shared[id] then
            shared[id] = true
            queue[#queue + 1] = id
        end
    end
    local ids = {}
    for id in pairs(world) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        if world[id].layer == 'standing' then add(id) end
    end
    local s = type(doc.settings) == 'table' and doc.settings or {}
    local start = type(s.start) == 'table' and s.start or {}
    local mode = start.mode
    if mode == 'interaction' or mode == 'press' or mode == 'area' or mode == 'timer' then add(start.world) end
    local i = 1
    while i <= #queue do
        local def = type(world[queue[i]].def) == 'table' and world[queue[i]].def or {}
        i = i + 1
        local t = type(def.tasks) == 'table' and def.tasks or nil
        for _, step in ipairs(t and type(t.list) == 'table' and t.list or {}) do
            local d = type(step) == 'table' and DirectorTasks.get(step.t)
            for _, f in ipairs(d and d.fields or {}) do
                for _, id in ipairs(Fields.worldIds(f, step[f.key], step)) do add(id) end
            end
        end
    end
    return shared
end

--- The scenario's variants, each a document of its own to check and compile: { { id, name, doc } }. Variant 1 (id
--- 'v1') first, the document itself; each other one the scenario's name, settings and variables, its shared things
--- (in Variant 1's order), then its own cards, wires, comment boxes and things.
---@return table[]
function DirectorGraph.variantsOf(doc)
    local out = { { id = 'v1', name = type(doc.variantName) == 'string' and doc.variantName or nil, doc = doc } }
    if type(doc.variants) ~= 'table' or #doc.variants == 0 then return out end
    local shared = DirectorGraph.sharedIds(doc)
    local common = {}
    for _, w in ipairs(type(doc.world) == 'table' and doc.world or {}) do
        if type(w) == 'table' and shared[w.id] then common[#common + 1] = w end
    end
    for _, v in ipairs(doc.variants) do
        if type(v) == 'table' then
            local world = {}
            for _, w in ipairs(common) do world[#world + 1] = w end
            if type(v.world) == 'table' then
                for _, w in ipairs(v.world) do world[#world + 1] = w end
            end
            out[#out + 1] = { id = v.id, name = v.name, doc = {
                format = doc.format, name = doc.name, description = doc.description, settings = doc.settings, vars = doc.vars,
                nodes = v.nodes, links = v.links, comments = v.comments, world = world,
            } }
        end
    end
    return out
end

--- Check a scenario document: with variants, each of them (a problem found the same in every one said once; one
--- found in some, said with its variant: { variant, variantName }), and the variants themselves.
---@param raw table          the document, read the one way first (doc.lua)
---@return boolean ok        true when there are no errors (warnings allowed)
---@return table problems    { { severity = 'error'|'warning', node?, pin?, message, variant?, variantName? } }
function DirectorGraph.check(raw)
    -- Read the one way first (doc.lua): a document that cannot be read is one error, never a throw (one bad document
    -- must not stop the Director's start-up), and a card that could not be brought up to date is one too. (Only read:
    -- one read already is not copied again.)
    local doc, why, stale = DirectorDoc.read(raw)
    if not doc then return false, { { severity = 'error', message = why } } end
    if stale then
        local problems = {}
        for _, s in ipairs(stale) do problem(problems, 'error', nil, s) end
        return false, problems
    end
    if doc.variants == nil then return checkOne(doc) end
    local problems = {}
    if type(doc.variants) ~= 'table' then
        problem(problems, 'error', nil, 'the scenario\'s variants are not a list')
        return false, problems
    end
    if #doc.variants == 0 then return checkOne(doc) end
    if #doc.variants + 1 > DirectorGraph.MAX_VARIANTS then
        problem(problems, 'error', nil, ('more than %d variants'):format(DirectorGraph.MAX_VARIANTS))
        return false, problems
    end
    local known = { v1 = true }
    for i, v in ipairs(doc.variants) do
        if type(v) ~= 'table' or type(v.id) ~= 'string' or not v.id:match('^v%d+$') or known[v.id] then
            problem(problems, 'error', nil, ('variant %d has no usable id'):format(i + 1))
            return false, problems
        end
        known[v.id] = true
        if v.name ~= nil and (type(v.name) ~= 'string' or #v.name > 40) then
            problem(problems, 'error', nil, ('variant %d\'s name is 40 letters at most'):format(i + 1))
        end
        for _, k in ipairs({ 'nodes', 'links', 'world', 'comments' }) do
            if v[k] ~= nil and type(v[k]) ~= 'table' then
                problem(problems, 'error', nil, ('variant %d\'s %s are not a list'):format(i + 1, k))
                return false, problems
            end
        end
    end
    local settings = type(doc.settings) == 'table' and doc.settings or {}
    local pick = settings.variantPick
    if pick ~= nil and not PICKS[pick] then
        problem(problems, 'error', nil, 'How a variant is picked is not one of the choices (Scenario Enabled)')
    end
    local order = settings.variantOrder
    local inOrder = {}
    if order ~= nil and type(order) ~= 'table' then
        problem(problems, 'error', nil, 'The variants\' order is not a list (Scenario Enabled)')
    elseif type(order) == 'table' then
        for _, id in ipairs(order) do
            if not known[id] then
                problem(problems, 'error', nil, ('The variants\' order names "%s", which is not one of them (Scenario Enabled)'):format(tostring(id)))
            elseif inOrder[id] then
                problem(problems, 'error', nil, ('The variants\' order has "%s" twice (Scenario Enabled)'):format(id))
            end
            inOrder[id] = true
        end
    end

    local variants = DirectorGraph.variantsOf(doc)
    local nameOf = function(v, i) return (type(v.name) == 'string' and v.name ~= '') and v.name or ('Variant ' .. i) end
    if pick == 'order' then
        if type(order) ~= 'table' or #order == 0 then
            problem(problems, 'error', nil, 'Variants are picked in order, but the order is empty (Scenario Enabled)')
        else
            for i, v in ipairs(variants) do
                if not inOrder[v.id] then
                    problem(problems, 'warning', nil, ('%s is not in the variants\' order: it is never picked (Scenario Enabled)'):format(nameOf(v, i)))
                end
            end
        end
    end
    local most = tonumber(settings.maxConcurrentRuns)
    if most and most < #variants then
        problem(problems, 'warning', nil, ('Runs at once is %d, so %d of the %d variants can never run at the same time as the others (Scenario Enabled)')
            :format(most, #variants - most, #variants))
    end

    -- A variant's own things: never one every variant shares, and never always present (that is every variant's).
    local shared = DirectorGraph.sharedIds(doc)
    for i, v in ipairs(doc.variants) do
        for _, w in ipairs(type(v.world) == 'table' and v.world or {}) do
            if type(w) == 'table' and (w.layer == 'standing' or shared[w.id]) then
                problem(problems, 'error', nil, ('%s holds "%s", which every variant shares: it belongs to Variant 1'):format(
                    nameOf(variants[i + 1], i + 1), tostring(w.label or w.id)))
            end
        end
    end

    -- Each variant, as a document of its own; what every one of them says, said once.
    local seen, lists = {}, {}
    for i, v in ipairs(variants) do
        DirectorGraph.checkingVariant = v.id
        local ran, okOrWhy, list = pcall(checkOne, v.doc)
        DirectorGraph.checkingVariant = nil
        if not ran then
            DirectorGraph.checking = nil
            list = { { severity = 'error', message = ('%s could not be checked: %s'):format(nameOf(v, i), tostring(okOrWhy)) } }
        end
        lists[i] = list
        for _, p in ipairs(list) do
            local key = table.concat({ p.severity, p.message or '', tostring(p.node), tostring(p.world), tostring(p.pin) }, '\0')
            seen[key] = (seen[key] or 0) + 1
        end
    end
    local said = {}
    for i, v in ipairs(variants) do
        for _, p in ipairs(lists[i]) do
            local key = table.concat({ p.severity, p.message or '', tostring(p.node), tostring(p.world), tostring(p.pin) }, '\0')
            if seen[key] == #variants then
                if not said[key] then
                    said[key] = true
                    problems[#problems + 1] = p
                end
            else
                p.variant, p.variantName = v.id, nameOf(v, i)
                problems[#problems + 1] = p
            end
        end
    end

    -- Two variants live at once with the same plate: two cars with one plate.
    local plates = {}
    for i, v in ipairs(variants) do
        for _, w in ipairs(type(v.doc.world) == 'table' and v.doc.world or {}) do
            local plate = type(w) == 'table' and w.kind == 'vehicle' and not shared[w.id] and type(w.def) == 'table' and w.def.plate or nil
            if type(plate) == 'string' and plate ~= '' then
                local up = plate:upper()
                if plates[up] and plates[up] ~= i then
                    problem(problems, 'warning', nil, ('%s and %s both make a car with the plate %s: run at the same time, one of them gets none')
                        :format(nameOf(variants[plates[up]], plates[up]), nameOf(v, i), up))
                end
                plates[up] = plates[up] or i
            end
        end
    end

    for _, p in ipairs(problems) do
        if p.severity == 'error' then return false, problems end
    end
    return true, problems
end

--- May it be TESTED with these problems? Every error but the ones only a live scenario minds (`live`: a run that can
--- never succeed, which a builder still tries half made) stops a Test as it stops switching on.
---@return boolean
function DirectorGraph.testable(problems)
    for _, p in ipairs(problems or {}) do
        if p.severity == 'error' and not p.live then return false end
    end
    return true
end

--- Compile a CHECKED document into what a run walks. Call check first; compile assumes it passed.
---@param doc table
---@return table compiled
function DirectorGraph.compile(doc)
    -- (A card another resource renamed since the document was read: a running scenario compiled again, cards_api.lua.)
    doc = DirectorNodes.applyRenames(doc)
    local c = { nodes = {}, out = {}, wiredIn = {}, events = {}, watches = {}, vars = {}, world = {}, settings = doc.settings or {} }
    for _, v in ipairs(doc.vars or {}) do c.vars[v.id] = v end
    for _, w in ipairs(doc.world or {}) do c.world[w.id] = w end
    for _, n in ipairs(doc.nodes or {}) do
        local def = DirectorNodes.get(n.type)
        c.nodes[n.id] = { id = n.id, type = n.type, def = def, props = n.props or {} }
        if def and def.event then
            local list = c.events[def.event.name]
            if not list then list = {}; c.events[def.event.name] = list end
            list[#list + 1] = n.id
        elseif def and def.watch then
            c.watches[#c.watches + 1] = n.id
        end
    end
    table.sort(c.watches)
    for _, l in ipairs(doc.links or {}) do
        local f, t = l.from, l.to
        local byPin = c.out[f.node]
        if not byPin then byPin = {}; c.out[f.node] = byPin end
        local list = byPin[f.pin]
        if not list then list = {}; byPin[f.pin] = list end
        local dup = false
        for _, e in ipairs(list) do if e.node == t.node and e.pin == t.pin then dup = true end end
        if not dup then list[#list + 1] = { node = t.node, pin = t.pin } end
        local w = c.wiredIn[t.node]
        if not w then w = {}; c.wiredIn[t.node] = w end
        w[t.pin] = (w[t.pin] or 0) + 1
    end
    -- Event cards (and watches, above) in a fixed order (by id), so dispatch never depends on table order.
    for _, list in pairs(c.events) do table.sort(list) end
    return c
end
