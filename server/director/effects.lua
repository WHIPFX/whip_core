-- ============================================
-- DirectorEffects — what a run does to a player's things, done one way
-- ============================================
--
-- Handing out items, paying, charging: every card that does one (Give Item, Drop Item, Put in Car, Create Container,
-- Pay, Send Money, Charge Player, another resource's card through card:give / pay / charge) does it here, so the
-- run's rules hold for all of them:
--
--   A TEST       what a test hands out is stamped with the run (metadata director = its id, and where it was made) and
--                listed in run.handedOut BEFORE the first one goes (a test ending in between already knows to take it
--                back): the test's end takes it back from whoever holds it (E.takeBack, below).
--   A LIVE RUN   gives real items: theirs to keep, never taken back, refused nowhere. Only an item one of the run's
--                own cards looks for (Collect, Bring Item To: a 'runItem' field; an item spot's pile) carries the run's
--                plain tag (fromRun = its id, and where it was made), which nothing but those cards reads. The rest
--                carry nothing, so they stack with the player's own.
--   ITS OWN DATA an item with data of its own per thing (a serial: Inventory.MetaGenerators) is handed one at a time,
--                each with fresh data, MAX_SERIALS at most.
--   MONEY        a test pays and charges nothing: it says what it would have. Paid, the run's payout grows; every
--                one is in the run's history (Director.event).
--   TOO LATE     money that comes after its card gave up (a slow bank): a payment is the player's, and said
--                (latePay); a charge is refunded (lateCharge).
--
-- Each waits (the database): call it from within ctx:call.

DirectorEffects = {}
local E = DirectorEffects

local CORE = GetCurrentResourceName()

E.MAX_SERIALS = 10

local money = DirectorKit.money

-- ============================================
-- Items
-- ============================================

--- The items a run's own cards look for by the run's mark (a 'runItem' field: Collect, Bring Item To). Worked out once
--- a run, from its graph.
---@return table set  [item] = true
function E.tracked(run)
    if run.tracked then return run.tracked end
    local set = {}
    for _, n in pairs(run.graph and run.graph.nodes or {}) do
        local fields = type(n.def) == 'table' and n.def._fields or nil
        for key, f in pairs(fields or {}) do
            local v = type(n.props) == 'table' and n.props[key] or nil
            if f.kind == 'runItem' and type(v) == 'string' then set[v] = true end
        end
    end
    run.tracked = set
    return set
end

--- The mark what a run hands out of `item` carries: a test's stamp ('director': taken back at its end, and refused
--- where its end does not look), a live run's plain tag on an item its cards look for ('fromRun'), or none (a live
--- run's item like any other).
---@return string|nil field
function E.markField(run, item)
    if run.test then return 'director' end
    if E.tracked(run)[item] then return 'fromRun' end
    return nil
end

--- The metadata field that marks this run's own things (what its cards count and take): its stamp in a test, its
--- plain tag in a live run.
function E.ownField(run) return run.test and 'director' or 'fromRun' end

--- Is this stack one this run marked as its own? (Its stamp in a test, its plain tag in a live run.)
---@param md table|nil  the stack's metadata
function E.isRunItem(run, md)
    return type(md) == 'table' and md[E.ownField(run)] == run.id
end

--- An item's own fresh data for one thing (a serial), as AddItem would make it, or nil when it has none.
function E.fresh(item)
    local gen = Inventory.MetaGenerators and Inventory.MetaGenerators[item]
    if not gen then return nil end
    local ok, md = pcall(gen, item)
    return ok and type(md) == 'table' and md or nil
end

--- List `item` as one the run hands out and takes back at its end (run.handedOut): before the first goes, so a run
--- ending in between already knows (a car's key, whose own data says it is the run's).
function E.handsOut(run, item)
    run.handedOut = run.handedOut or {}
    run.handedOut[item] = true
end

--- The mark for what a run hands out of `item`: stamp(md) -> md as it is given. In a test, run.handedOut lists the item
--- now (before the first goes) and each one carries director = the run's id; in a live run, one its cards look for
--- carries fromRun = the run's id (E.markField). Either way with `extra`'s keys (dworld: the placed thing it came from).
--- An item with no mark goes as it is.
function E.stamper(run, item, extra)
    local field = E.markField(run, item)
    if not field then return function(md) return md end end
    if field == 'director' then E.handsOut(run, item) end
    return function(md)
        md = md or {}
        md[field] = run.id
        for k, v in pairs(extra or {}) do md[k] = v end
        return md
    end
end

--- A pile the run put on the ground, on its ledger (CTX:own): its end, or a test rewound to before it, clears it
--- (ground items are rows: the run's tag does not reach them). Not while whip_core stops: a row is saved as it lies,
--- and the boot's sweep takes a stamped one.
function E.ownGround(ctx, groundId)
    return ctx:own(function(why)
        if why ~= 'stopping' and GroundItems.getById(groundId) then GroundItems.deleteItem(groundId) end
    end, 'a ground pile')
end

--- Put down a pile that is the run's own (Place Item's, a car's key at its spot): GroundItems.createItem's spec, on the
--- run's ledger (E.ownGround), and marked drun = the run's id. drun is a pile key (GroundItems.PILE_KEYS): it stays on
--- the ground when the item is picked up, so the boot's sweep finds a pile whip_core stopped under, never an item
--- someone picked up and dropped again. Waits.
---@return table|nil pile
---@return string|nil why
function E.placePile(ctx, spec)
    spec.metadata = spec.metadata or {}
    spec.metadata.drun = ctx.run.id
    local g, why = GroundItems.createItem(spec)
    if not g then return nil, why end
    E.ownGround(ctx, g.id)
    return g
end

--- Hand a player some of an item, the run's way (the header): how many they got, or 0 and why. Into their pockets,
--- at their feet when it does not fit (Inventory.give).
---@param opts table|nil  { metadata = the giver's own (else the item's fresh data), reason }
---@return integer given
---@return string|nil why
function E.give(run, nodeId, src, item, amount, opts)
    opts = opts or {}
    local stamp = E.stamper(run, item)
    local reason = opts.reason or Director.reason(run)
    local n, why = 0, nil
    if opts.metadata == nil and Inventory.MetaGenerators and Inventory.MetaGenerators[item] then
        -- Each thing its own data (a serial), then the stamp.
        for _ = 1, math.min(amount, E.MAX_SERIALS) do
            if run.status ~= 'running' then break end   -- (its end has swept: no more)
            local where, w = Inventory.give(src, item, 1, stamp(E.fresh(item)), { reason = reason })
            if not where then why = w break end
            n = n + 1
        end
    else
        local where, w = Inventory.give(src, item, amount, stamp(opts.metadata), { reason = reason })
        if where then n = amount else why = w end
    end
    if n > 0 then
        Director.event(run, nodeId, 'given', src, ('%s x%d'):format(item, n))
        return n
    end
    return 0, tostring(why or 'nothing could be given')
end

-- ============================================
-- Money
-- ============================================

--- A character's own bank balance (their default account), or nil when it cannot be read. Waits.
function E.bankBalance(src)
    local p = Players[src]
    if not (p and p.charId and Bank and Bank.GetDefaultAccount) then return nil end
    local row = Bank.GetDefaultAccount(p.charId)
    return row and tonumber(row.balance) or 0
end

--- Pay a player, the run's way: a test pays nothing and says what it would; paid, the run's payout grows and its
--- history says so.
---@param opts table|nil  { method ('auto' | 'cash' | 'bank'), reason (on their statement), testSays (what a test
---                         tells them), detail (the history's words: '$n' else), send = fn() -> ok, why (how it pays:
---                         Money.pay with method and reason else) }
---@return boolean ok
---@return string|nil why
function E.pay(run, nodeId, src, amount, opts)
    opts = opts or {}
    local detail = opts.detail or money(amount)
    if run.test then
        NotifyPlayer(src, opts.testSays or ('Test: this would pay %s (%s)'):format(money(amount), tostring(opts.method or 'auto')), 'info')
        Director.event(run, nodeId, 'paid (test)', src, detail)
        return true
    end
    local ok, why
    if opts.send then ok, why = opts.send()
    else ok, why = Money.pay(src, amount, { method = opts.method, reason = opts.reason }, CORE, Director.reason(run)) end
    if not ok then return false, tostring(why) end
    run.payout = (run.payout or 0) + amount
    Director.event(run, nodeId, 'paid', src, detail)
    return true
end

--- A pay card's `late` (ctx:call): paid after it gave up, the money is theirs, and said in the console and the run's
--- history (so one who wired its timeout back into it sees why it paid twice). `what`: the card's name.
function E.latePay(run, nodeId, src, amount, what)
    return function(pin)
        if pin ~= 'paid' or run.test then return end
        print(('[whip_core:director] run %s: %s paid %s to %s after the card had given up: kept')
            :format(tostring(run.id), what or 'a card', money(amount), tostring(src)))
        Director.event(run, nodeId, 'paid (late)', src, money(amount))
    end
end

--- Charge a player, the run's way: the receipt, or nil and why (they have not got it). A test charges nothing: true
--- when they could have paid (and says so), nil when not.
---@param opts table|nil  { method ('auto' | 'cash' | 'bank'), reason }
function E.charge(run, nodeId, src, amount, opts)
    opts = opts or {}
    local method = opts.method or 'auto'
    if run.test then
        local could = method ~= 'bank' and Director.carried(src, 'cash', run) >= amount
        if not could and method ~= 'cash' then could = (E.bankBalance(src) or 0) >= amount end
        NotifyPlayer(src, could and ('Test: this would take %s (%s)'):format(money(amount), method)
            or ('Test: they could not pay %s'):format(money(amount)), 'info')
        Director.event(run, nodeId, could and 'charged (test)' or 'could not pay (test)', src, money(amount))
        if not could then return nil, 'they could not pay' end
        return true
    end
    local receipt, why = Money.charge(src, amount, { method = method, reason = opts.reason }, CORE, Director.reason(run))
    if not receipt then
        Director.event(run, nodeId, 'could not pay', src, money(amount))
        return nil, tostring(why)
    end
    Director.event(run, nodeId, 'charged', src, money(amount))
    return receipt
end

--- A charge card's `late` (ctx:call): charged after it gave up (the run went on as Took Too Long), the money goes
--- back, never paid for nothing. `receiptOf()`: the receipt, once taken (a test's `true` refunds nothing).
function E.lateCharge(run, amount, receiptOf)
    return function()
        local receipt = receiptOf()
        if not receipt or receipt == true then return end
        local back, why = Money.refund(receipt, nil, CORE)
        if not back then
            print(('[whip_core:director] run %s: a late charge of %s could not be refunded: %s')
                :format(tostring(run.id), money(amount), tostring(why)))
        end
    end
end

-- ============================================
-- Taken back
-- ============================================
--
-- What a TEST handed out goes back when it ends (a package, a test car's key); a live run's items are real, and stay.
-- Items a test made carry its stamp ({ director = runId }); every such stack in its players' pockets is taken back,
-- with a word to say so.
-- One dropped on the ground goes with the run's ground items (main.lua's runEnded finds those by the stamp too). A
-- player who LEFT the run (logged out, disconnected, or whip restarted under it) is no longer in it when it ends:
-- their stamped stacks go when their character next loads (E.takeBackStale), since by then no run can be theirs.
--
-- What is theirs inside it goes back to them: a gun a run dropped can hold the player's own magazine, a run's bag their
-- own things. So before a stamped stack goes, whatever inside it is not a run's comes out to the player (AddItem: their
-- pockets, or the ground at their feet). What is inside is read the way whip weighs an item (its panel:
-- RegisterPanelItem's read hook or its stored slots), so this knows no item in particular.

--- What is inside an item, as whip reads it for weight (Inventory's readContents).
local function contentsOf(itemKey, metadata)
    if type(metadata) ~= 'table' then return nil end
    local cfg = Panels and Panels.itemConfigs and Panels.itemConfigs[itemKey]
    if not cfg then return nil end
    if cfg.read then
        local ok, projected = pcall(cfg.read, { item = itemKey, metadata = metadata })
        return (ok and type(projected) == 'table') and projected or nil
    end
    local stored = metadata[cfg.storageKey or 'slots']
    return type(stored) == 'table' and stored or nil
end

--- The player's own things inside a stack: everything not stamped as a run's, and inside what is,
--- its contents too (a run's bag holding their gun). Three levels at most, as whip nests.
local function ownInside(itemKey, metadata, out, depth)
    depth = (depth or 0) + 1
    if depth > 3 then return out end
    for _, e in pairs(contentsOf(itemKey, metadata) or {}) do
        if type(e) == 'table' and type(e.item) == 'string' then
            if type(e.metadata) == 'table' and e.metadata.director ~= nil then
                ownInside(e.item, e.metadata, out, depth)
            else
                out[#out + 1] = e
            end
        end
    end
    return out
end

--- Take one stamped stack (a FindAllItems entry) off a player, giving them back what of theirs is in it.
---@return boolean taken
local function takeStamped(src, key, f, reason)
    local own = ownInside(key, f.metadata, {})
    if not Stores.takeAt(f.addr, f.amount, { reason = reason }) then return false end
    for _, e in ipairs(own) do
        Inventory.give(src, e.item, tonumber(e.amount) or 1, e.metadata, reason .. ' (theirs, from inside it)')
    end
    return true
end

--- Every stack of this run's on a player, taken back. Waits (their pockets).
---@return number amount
---@return string|nil what  the item names, for the notification
function E.takeBack(run, src)
    local keys = {}
    for _, w in pairs(run.graph.world) do
        if w.kind == 'groundItem' and type(w.def) == 'table' and type(w.def.item) == 'string' then keys[w.def.item] = true end
    end
    for key in pairs(run.handedOut or {}) do keys[key] = true end
    local n, names = 0, {}
    for key in pairs(keys) do
        for _, f in ipairs(Inventory.findAll(src, key) or {}) do
            local md = f.metadata
            if type(md) == 'table' and md.director == run.id then
                if takeStamped(src, key, f, Director.reason(run) .. ' (taken back: the run ended)') then
                    n = n + f.amount
                    names[DirectorKit.itemName(key)] = true
                end
            end
        end
    end
    local list = {}
    for name in pairs(names) do list[#list + 1] = name end
    table.sort(list)
    return n, #list > 0 and table.concat(list, ', ') or nil
end

--- Every stamped stack on a player whose run is over for them, taken back: the login sweep (main.lua). Waits.
---@return string[] names  what was taken, sorted
function E.takeBackStale(src)
    local keys = {}
    for _, slots in pairs(Inventory.pocketsCopy(src) or {}) do
        for _, d in pairs(type(slots) == 'table' and slots or {}) do
            if type(d) == 'table' and type(d.item) == 'string' and type(d.metadata) == 'table' and d.metadata.director ~= nil then
                keys[d.item] = true
            end
        end
    end
    local names = {}
    for key in pairs(keys) do
        for _, f in ipairs(Inventory.findAll(src, key) or {}) do
            local md = f.metadata
            local run = type(md) == 'table' and md.director ~= nil and DirectorRuntime.get(md.director) or nil
            if type(md) == 'table' and md.director ~= nil and not (run and run.players[src]) then
                if takeStamped(src, key, f, ('director run %s (taken back: the run is over)'):format(tostring(md.director))) then
                    names[#names + 1] = DirectorKit.itemName(key)
                end
            end
        end
    end
    table.sort(names)
    return names
end

--- Where a test's own items may go (a live run's carry no stamp, and go anywhere): only where its end looks for them —
--- its players' pockets (takeBack), its own car's trunk, glovebox and ignition, and its own containers
--- (both go with the run). Anywhere else (a stash, a car of the player's, a bag, a shop, someone
--- outside the run) is refused, or "taken back when the run ends" could be kept: put in a car boot,
--- the run let fail, and again. The ground is not a store: a pile there is cleared at the run's end.
--- A stamp whose run is over may only stay in pockets, where the next login takes it back.
local function runHas(run, field, id)
    if id == nil then return false end
    for _, h in pairs(run.world or {}) do
        -- (A claimed car is the player's own now: what goes in it would be kept.)
        if type(h) == 'table' and h[field] == id and not h.claimed then return true end
    end
    return false
end

Stores.placementVeto = function(kindId, h, _, md)
    local run = DirectorRuntime.get(md.director)
    if kindId == 'player' then
        if not run then return false end
        local src = type(h) == 'table' and type(h.player) == 'table' and h.player.source or nil
        return not (src ~= nil and run.players[src])
    end
    if not run then return true end
    if kindId == 'vehicle' then return not runHas(run, 'vehicleId', type(h) == 'table' and h.vehicleId or nil) end
    if kindId == 'container' then
        -- Its own by its tag too: a run container made under the run's tag goes with it. The vault's
        -- cash is put in WHILE the safe is made (Containers.create's items), before Create Container
        -- remembers it.
        local def = type(h) == 'table' and h.def or nil
        if def and Containers.isRuntime(def) and def.tag ~= nil and def.tag == run.tag then return false end
        return not runHas(run, 'containerId', type(h) == 'table' and h.containerId or nil)
    end
    return true
end
