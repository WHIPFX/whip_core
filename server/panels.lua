-- ============================================
-- Universal Panel Framework (OpenPanel)
-- ============================================
-- Server-side session management with weight validation, allowed items, read-only mode, and
-- structured callbacks. Manifest constraints: after secure.lua (the SecureEvent at the bottom
-- registers at file scope) and before server/items/*.lua (duffle_bag and wallet call
-- RegisterPanelItem at file scope). Everything else resolves at call time.

--- The panel system, as one module. The underscore fields are this file's own: other files ask
--- through Panels.hasOpen, Panels.sessionById and Panels.findSlot.
Panels = {}

--- [source] = { [panelId] = { id, items, config, onClose, resource } }
---
--- `onClose` on a session is whip_core's own: a RegisterPanelItem panel's fold-back into its item.
--- A resource's hooks — onValidate, onChange, onClose — belong to the PANEL, not to one viewer, and
--- live on its instance (see panelInstanceFor).
---
--- A player can hold several panels at once: `Panels._sessions[source]` is a SET, removed entirely
--- when its last panel closes, so `if Panels._sessions[source]` reads as "has any panel open". A
--- specific session is named: Panels.sessionFor.
Panels._sessions = {}

--- One player's session for one panel, or nil. With panelId nil this answers only if there is
--- exactly one: several is a question the caller has to ask properly.
---@param source number
---@param panelId any|nil
---@return table|nil
function Panels.sessionFor(source, panelId)
    local mine = Panels._sessions[source]
    if not mine then return nil end
    if panelId ~= nil then return mine[panelId] end

    local only, count = nil, 0
    for _, s in pairs(mine) do
        only = s
        count = count + 1
        if count > 1 then return nil end
    end
    return only
end

--- Has this player any panel open at all?
---@param source number
---@return boolean
function Panels.hasOpen(source)
    return Panels._sessions[source] ~= nil
end

--- This player's session for the panel whose id READS as `idText` — a client names a panel by
--- text, and an id may be a number — or nil when they hold no such panel. The authorisation for
--- moving into a panel (Stores.fromWire) and GetOpenStores' naming both ask this.
---@param source number
---@param idText string
---@return table|nil session
function Panels.sessionById(source, idText)
    for id, s in pairs(Panels._sessions[source] or {}) do
        if tostring(id) == idText then return s end
    end
    return nil
end

--- The longest panel id a client can name back: the close event's limit, and the move's. OpenPanel
--- refuses a longer one (it could never be dragged into or out of).
Panels.ID_MAX = 80

--- A panel id as a client sent it, as text, or nil. A number is a legal id (OpenPanel) and arrives
--- as a number.
---@param raw any
---@return string|nil
function Panels.wireId(raw)
    if type(raw) == 'number' then raw = tostring(raw) end
    if type(raw) ~= 'string' or raw == '' or #raw > Panels.ID_MAX then return nil end
    return raw
end

--- The first slot, in any open panel, whose item passes `test` — as panelId, slot — or nil. For
--- FindItemByUid (server/stores.lua), which looks through everything loaded.
---@param test fun(d: table): boolean
---@return any|nil panelId
---@return number|nil slot
function Panels.findSlot(test)
    for panelId, inst in pairs(Panels._instances) do
        for slot, d in pairs(inst.items or {}) do
            if test(d) then return panelId, slot end
        end
    end
    return nil
end

--- Deep copy a panel items table
---@param items table
---@return table
local function deepCopyPanelItems(items)
    if not items then return {} end
    local copy = {}
    for slot, data in pairs(items) do
        if type(data) == 'table' then
            local metaCopy = nil
            if data.metadata then
                metaCopy = json.decode(json.encode(data.metadata))
            end
            copy[slot] = {
                item     = data.item,
                amount   = data.amount,
                metadata = metaCopy,
            }
        end
    end
    return copy
end

--- Who put what in, for a panel closed with things left in it. Each player's deposits are counted:
--- in adds, out takes away (their own first), and at the last close each gets back what they put in
--- and did not take out, as far as it is still there. What the resource stocked the panel with stays
--- the resource's. Called by the panel kind's afterMove (stores.lua) for a panel a resource opened;
--- a RegisterPanelItem panel lives in its item instead.
---
--- By character, not server id: a depositor may be at the character select by the last close.
---@param session table  the mover's panel session
---@param ctx table      the afterMove ctx: direction, item, amount, metadata, source, destroyed, detail
function Panels.noteMove(session, ctx)
    local inst = session and Panels._instances[session.id]
    local src = ctx and tonumber(ctx.source)
    local mover = src and Players[src]
    local charId = mover and mover.charId
    if not inst or not charId or not ctx.item or ctx.direction == 'within' then return end
    inst.deposits = inst.deposits or {}
    local mine = inst.deposits[charId]
    if not mine then mine = {}; inst.deposits[charId] = mine end

    local function add(item, amount, metadata)
        mine[#mine + 1] = { item = item, amount = amount, metadata = Inventory.copyMetadata(metadata) }
    end
    -- Their own deposits of that item go down — the same state first, then any. Taking out what the
    -- resource stocked (or someone else put in) with none of their own left changes nothing.
    local function take(item, amount, metadata)
        for pass = 1, 2 do
            for i = #mine, 1, -1 do
                if amount <= 0 then return end
                local d = mine[i]
                if d.item == item and (pass == 2 or Stores.stacksWith(d.metadata, metadata)) then
                    local n = math.min(amount, d.amount)
                    d.amount, amount = d.amount - n, amount - n
                    if d.amount <= 0 then table.remove(mine, i) end
                end
            end
        end
    end

    local amount = math.max(1, math.floor(tonumber(ctx.amount) or 1))
    -- The other half of a swap is not told separately: what it put back is `replacing`.
    local swapped = type(ctx.detail) == 'table' and ctx.detail.replacing or nil
    if ctx.direction == 'in' then
        add(ctx.item, amount, ctx.metadata)
        if swapped then take(swapped.item, swapped.amount or 1, swapped.metadata) end
    elseif ctx.direction == 'out' then
        take(ctx.item, amount, ctx.metadata)
        if swapped and not ctx.destroyed then add(swapped.item, swapped.amount or 1, swapped.metadata) end
    end
end

--- Nobody's onClose will take what is left in a panel a resource opened: every character gets back
--- what they put in and did not take out (Panels.noteMove); what remains — the stock the resource put
--- in — goes with the panel, logged as lost. A depositor whose character is no longer in the game
--- cannot be handed anything: theirs is logged as lost against that character, and said.
---
--- The one way a panel's leftovers go back, in three cases: the last one out of a panel with no
--- working onClose; the last one out after the resource that opened it stopped (orphaned); whip_core
--- itself stopping.
---
--- `opts.inPockets`: the pockets only, never the ground. whip_core's own stop cannot wait on the
--- database (a drop is an INSERT), so there anything that does not fit is lost — and said so.
---@param inst table     the panel instance
---@param session table  a viewer's session (for the label)
---@param opts table|nil { why = the log line's reason, inPockets = boolean, closer = the last viewer's source }
local function returnDeposits(inst, session, opts)
    opts = opts or {}
    local left = inst.items or {}
    local label = ('panel "%s" (%s)'):format(tostring(session.id), tostring(inst.hookOwner or inst.owner))
    local why = opts.why or ('back from %s, which closed with it in'):format(label)
    for charId, list in pairs(inst.deposits or {}) do
        local player = PlayersByCharId[charId]
        local src = player and player.source
        local gave = false
        for _, dep in ipairs(list) do
            local want = dep.amount
            for slot, entry in pairs(left) do
                if want <= 0 then break end
                if type(entry) == 'table' and entry.item == dep.item and Stores.stacksWith(entry.metadata, dep.metadata) then
                    local n = math.min(want, entry.amount or 1)
                    local given = false
                    if src and player.inventory then
                        if opts.inPockets then
                            given = Inventory.addItemWithFallback(player.inventory, entry.item, n, entry.metadata) == true
                            if given then Log.gained(charId, entry.item, n, why) end
                        else
                            given = Inventory.giveOrDrop(src, player, entry.item, n, entry.metadata, { reason = why }) and true or false
                        end
                    end
                    if given then
                        gave = true
                    else
                        print(('[whip_core:panel] %s x%s put in %s could not go back to character %s — lost')
                            :format(tostring(entry.item), tostring(n), label, tostring(charId)))
                        Log.lost(charId, entry.item, n, why .. (src and ' — it did not fit' or ' — its owner had left'))
                    end
                    entry.amount = (entry.amount or 1) - n
                    if entry.amount <= 0 then left[slot] = nil end
                    want = want - n
                end
            end
        end
        if gave then
            -- Owed, not awaited: saveAll marks the pockets dirty without yielding, so on whip_core's
            -- own stop the dispatch that follows (player_lifecycle.lua) sends these gives too.
            if opts.inPockets then
                local pockets = Stores.player(src, 'player')
                if pockets then pcall(Stores.saveAll, { pockets }) end
            end
            Inventory.syncToClient(src, player)
        end
    end

    -- What nobody put in: the resource's own stock. Nothing is left to keep it, so it goes.
    local closerPlayer = opts.closer and Players[opts.closer]
    for _, entry in pairs(left) do
        if type(entry) == 'table' and entry.item then
            Log.lost(closerPlayer and closerPlayer.charId or nil, entry.item, entry.amount or 1,
                ('left in %s, with nothing to keep it — the resource\'s own stock'):format(label))
        end
    end
    inst.items, inst.deposits = {}, nil
end

--- The host item as every panel hook receives it: { source, container, slot, addr, item, amount,
--- metadata }. One builder, because it is made in three places.
---
--- `addr` is its whip address — { kind = 'player', id, sub, slot }, what GetItemAt, SetItemMetadata
--- and StoreTake take.
---@param source number
---@param container string  the pocket
---@param slot number
---@param sd table  the slot's contents
---@return table host
local function panelHost(source, container, slot, sd)
    return {
        source    = source,
        container = container,
        slot      = slot,
        addr      = { kind = 'player', id = source, sub = container, slot = slot },
        item      = sd.item,
        amount    = sd.amount,
        metadata  = sd.metadata or {},
    }
end

--- What a RegisterPanelItem panel shows for its host item: the registration's read(), or the
--- plain slot array at meta[storageKey]. Returns nil plus the error when read() fails.
---@param reg table  the registration
---@param storageKey string
---@param host table  { item, metadata, ... }
---@return table|nil items
---@return any err
local function projectHost(reg, storageKey, host)
    local items = {}
    if reg.read then
        local ok, projected = pcall(reg.read, host)
        if not ok then return nil, projected end
        for k, v in pairs(projected or {}) do
            if v then items[tonumber(k) or k] = v end
        end
    else
        -- Normalize stored items (Lua arrays from JSON may have gaps)
        for k, v in pairs((host.metadata or {})[storageKey] or {}) do
            if v then items[tonumber(k) or k] = v end
        end
    end
    return items
end

--- A private copy of panel contents to compare against later. Structural rather than a JSON round
--- trip like deepCopyPanelItems: JSON turns a sparse table's number keys into strings, and the
--- comparison would then report a change that never happened.
---@param items table
---@return table
local function snapshotItems(items)
    local copy = {}
    for slot, data in pairs(items or {}) do
        if type(data) == 'table' then
            copy[slot] = {
                item     = data.item,
                amount   = data.amount or 1,
                metadata = Inventory.copyMetadata(data.metadata),
            }
        end
    end
    return copy
end

--- Do two sets of panel contents hold the same items?
---@param a table
---@param b table
---@return boolean
local function sameItems(a, b)
    for slot, x in pairs(a) do
        local y = b[slot]
        if not y or y.item ~= x.item or (y.amount or 1) ~= (x.amount or 1)
            or not Stores.metadataEquivalent(x.metadata, y.metadata) then
            return false
        end
    end
    for slot in pairs(b) do
        if a[slot] == nil then return false end
    end
    return true
end

-- ============================================
-- Panel instances — one set of contents per panel, however many people are looking
-- ============================================
--
-- The items table belongs to the PANEL, and every session for that panel id points at it (as
-- containers share one Containers.invCache): two viewers drag out of one table, so the second finds
-- what the first left. A private copy per viewer would let both drag out everything.
--
-- whip_core owns the table from the moment the panel opens. The caller supplies INITIAL CONTENTS,
-- copied in once, and reads state back through StoreRead.

--- [panelId] = { items = <the one shared table>, viewers = <count>, owner = <resource that opened it>,
--- hooks = { onValidate?, onChange?, onClose? }, hookOwner = <resource> }
Panels._instances = {}

--- The names of a panel's hooks — the same three for a panel a resource opens and (bar onClose) for
--- a RegisterPanelItem panel, each handed ONE table, `ctx`. See the panel kind in stores.lua.
local PANEL_HOOKS = { 'onValidate', 'onChange', 'onClose' }

--- Get the shared contents for a panel id, seeding it the first time anyone opens it.
---
--- The hooks are the panel's, like its contents: passed to OpenPanel and kept on the instance. The
--- opener that brings hooks first sets them, and every viewer's moves are asked.
---@param panelId string
---@param initialItems table|nil  used ONLY when the panel is not already open
---@param config table|nil  the OpenPanel config, for its hooks
---@param resource string|nil  who is opening it
---@return table items
local function panelInstanceFor(panelId, initialItems, config, resource)
    local inst = Panels._instances[panelId]
    if not inst then
        -- Copied, not adopted: from here on this table is whip_core's, and the caller cannot
        -- change the panel's contents behind its back by mutating what they passed in.
        -- `owner`: the resource that opened it first, and the only one that may open it again
        -- while it is open (OpenPanelInternal).
        inst = { items = deepCopyPanelItems(initialItems or {}), viewers = 0, owner = resource or 'whip_core' }
        Panels._instances[panelId] = inst
    end
    -- A second opener's `items` are deliberately ignored: the panel already has contents, and
    -- re-seeding from a stale caller-side copy would duplicate them.

    if config and not inst.hooks then
        local hooks, any = {}, false
        -- `~= nil`, never a type test: a function from another resource arrives as a callable table.
        for _, name in ipairs(PANEL_HOOKS) do
            if config[name] ~= nil then hooks[name], any = config[name], true end
        end
        if any then
            inst.hooks, inst.hookOwner = hooks, resource or 'whip_core'
        end
    end
    return inst.items
end

--- The panel's hooks and whose they are, for the panel store kind. A RegisterPanelItem panel's are
--- its registration's; any other panel's are its instance's. Both nil when it has none.
---@param session table
---@return table|nil hooks
---@return string|nil owner
function Panels.hooksFor(session)
    if session.registration then
        return session.registration, session.registration._resource
    end
    local inst = Panels._instances[session.id]
    if inst and inst.hooks then return inst.hooks, inst.hookOwner end
    return nil, nil
end

--- An allowedItems list as a lookup set. Either spelling works — a list of item names
--- `{ 'cash', 'id_card' }` or a table keyed by name `{ cash = {...}, id_card = true }`. One normaliser
--- for both openers (OpenPanel and RegisterPanelItem).
---@param list table|nil
---@return table|nil
local function allowedSet(list)
    if type(list) ~= 'table' then return nil end
    local set = {}
    for k, v in pairs(list) do
        if type(k) == 'number' then set[v] = true else set[k] = true end
    end
    return set
end

--- Close one player's view of a panel, and tear the panel down if they were the last one in.
---
--- onClose means "the last person has left, here is the final state": with several viewers, firing
--- it per close would hand the owning resource the contents while others are still moving them.
--- Anything a resource wants sooner belongs in a per-move hook.
---
--- A panel id, or nil for every panel this player has open (disconnect and the inventory-wide close).
---@param source number
---@param panelId any|nil  which panel, or nil for every panel this player has open
---@param notifyClient boolean|nil  send the close message to that player's UI
---@return boolean closed
function Panels.closeFor(source, panelId, notifyClient)
    local mine = Panels._sessions[source]
    if not mine then return false end

    if panelId == nil then
        -- Close-all. Collect first: Panels.closeFor mutates the table it would be iterating.
        local ids = {}
        for id in pairs(mine) do ids[#ids + 1] = id end
        local any = false
        for _, id in ipairs(ids) do
            if Panels.closeFor(source, id, notifyClient) then any = true end
        end
        return any
    end

    -- Direct hit first, then a tostring scan: a satellite's id may be a number, and one that has
    -- crossed the wire arrives as a string.
    local session = mine[panelId]
    if not session then
        local want = tostring(panelId)
        for id, s in pairs(mine) do
            if tostring(id) == want then panelId, session = id, s break end
        end
    end
    if not session then return false end

    mine[panelId] = nil
    if next(mine) == nil then Panels._sessions[source] = nil end

    Stores.removeViewer(source, 'panel:' .. tostring(session.id))
    if notifyClient then
        -- The id goes with it, so the client closes THIS panel and leaves the others up.
        TriggerClientEvent('whip_core:client:closeExternalPanel', source, session.id)
    end

    local inst = Panels._instances[session.id]
    if not inst then return true end

    inst.viewers = inst.viewers - 1
    if inst.viewers > 0 then return true end

    -- Forgotten first, then closed: the hooks and the hand-back below can wait, and a re-open of the
    -- same id meanwhile must start a fresh instance rather than join this dying one (its items are
    -- being handed back). This close works on `inst` alone.
    Panels._instances[session.id] = nil

    -- Last one out: hand the final contents back and forget the panel. A COPY, never the live
    -- table: a consumer may keep it as its own state.
    --
    -- Two onCloses: the SESSION's is whip_core's own (a RegisterPanelItem panel folding into its
    -- item); the INSTANCE's is the opener's hook from the OpenPanel config, run for whoever leaves
    -- last, and an error is said. Actions.call, not pcall: what the hook gives back through whip
    -- saves with this action.
    if session.onClose then Actions.call(session.resource, session.onClose, source, deepCopyPanelItems(inst.items)) end
    -- A RegisterPanelItem panel's contents live in its item (folded on every move), so they are never
    -- left behind, even when its resource stopped and took the fold's onClose with it.
    local handedOver = session.onClose ~= nil or session.registration ~= nil
    if inst.hooks and inst.hooks.onClose ~= nil then
        local ok, err = Actions.call(inst.hookOwner, inst.hooks.onClose, {
            panel  = session.id,
            source = source,
            items  = deepCopyPanelItems(inst.items),
        })
        if not ok then
            print(('[whip_core:panel] onClose for panel "%s" (%s) errored: %s')
                :format(tostring(session.id), tostring(inst.hookOwner), tostring(err)))
        end
        handedOver = handedOver or ok
    end
    -- The resource that opened it has stopped (see onResourceStop below): nobody's onClose will
    -- take the contents, so each player gets back what they put in (returnDeposits). A read-only
    -- panel had nothing put in it.
    local readOnly = session.config and session.config.readOnly
    if inst.orphaned and not readOnly then
        returnDeposits(inst, session, { why = inst.orphaned, closer = source })
    elseif not handedOver and not readOnly then
        -- Nobody took what was left in it (no onClose, or one that errored): each player gets back
        -- what they put in (returnDeposits); only the resource's own stock goes, logged.
        returnDeposits(inst, session, { closer = source })
    end
    return true
end

--- Current weight of this player's open panel (Stores.weightOf, which fails closed for an
--- unregistered item).
---@param source number
---@param panelId any|nil  which panel; nil resolves only when the player has exactly one open
---@return number
local function calculatePanelWeight(source, panelId)
    local store = Stores.panel(source, panelId)
    if not store then return 0 end
    return Stores.weightOf(store)
end

--- OpenPanelInternal — core logic for opening a server-managed panel.
--- Called directly by internal code (RegisterPanelItem) and wrapped by the OpenPanel export.
---@param source number
---@param config table { id, label?, slots?, items?, maxWeight?, readOnly?, allowedItems?, onValidate?, onChange?, onClose? }
---@param resource string|nil  invoking resource name (export wrapper passes GetInvokingResource())
---@return boolean ok
---@return string|nil err
local function OpenPanelInternal(source, config, resource)
    if type(config) ~= 'table' or config.id == nil then return false, 'a panel needs a config with an id' end
    if not Panels.wireId(config.id) then
        return false, ('a panel id is a string or number of 1 to %d characters'):format(Panels.ID_MAX)
    end
    local player = Players[source]
    if not player then return false, 'Player not loaded' end

    -- Opening a panel that is already open is a no-op: no second viewer, no close message, no
    -- reorder (a close-and-reopen would close the inventory, or reorder the stack, on the client).
    if Panels._sessions[source] and Panels._sessions[source][config.id] then
        return true
    end

    -- One resource's panel id is not another's: ids are one namespace ('panel:<id>'). The same
    -- resource opening its own id again joins it; another resource is refused, with the owner named.
    local existing = Panels._instances[config.id]
    local opener = resource or 'whip_core'
    if existing and existing.owner and existing.owner ~= opener then
        return false, ('Panel id "%s" is already open by %s. Pick an id only your resource uses, like "%s:%s"')
            :format(tostring(config.id), existing.owner, opener, tostring(config.id))
    end

    -- A list of names or a keyed table, as a lookup set (allowedSet).
    local allowedItems = allowedSet(config.allowedItems)

    -- The SHARED contents for this panel id — not a private copy — and its hooks. See panelInstanceFor.
    local items = panelInstanceFor(config.id, config.items, config, resource)

    local inst = Panels._instances[config.id]
    inst.viewers = inst.viewers + 1
    -- Register with the store viewer set, so a move inside this panel is broadcast to everyone
    -- else looking at it exactly as it is for a stash. The id matches the panel kind's
    -- instanceId ('panel:' .. session.id), which is what makes one registry cover both.
    Stores.addViewer(source, 'panel:' .. tostring(config.id))

    -- Store session, keyed by panel id within this player's set.
    if not Panels._sessions[source] then Panels._sessions[source] = {} end
    Panels._sessions[source][config.id] = {
        id       = config.id,
        items    = items,
        config   = {
            id           = config.id,
            label        = config.label or 'Panel',
            slots        = config.slots or 10,
            maxWeight    = config.maxWeight,
            readOnly     = config.readOnly,
            allowedItems = allowedItems,
        },
        onClose  = nil,
        resource = resource or 'whip_core',
    }

    local session = Panels._sessions[source][config.id]

    -- Calculate initial weight
    local initialWeight = calculatePanelWeight(source, config.id)

    -- Build player inventory data (so panel + inventory open together)
    -- Client decides whether to do a full open or overlay (if inventory is already open)
    local payload = Inventory.buildPayload(player)

    -- Which items it takes, as a list of names (nil = anything). The client uses it only to choose
    -- where a shift-clicked item goes — a wallet open beside Nearby should not be picked for a
    -- burger — and the server still decides every move (the panel kind's `allows`).
    local allowedNames = nil
    if allowedItems then
        allowedNames = {}
        for name in pairs(allowedItems) do allowedNames[#allowedNames + 1] = name end
    end

    payload.panel = {
        id           = config.id,
        label        = config.label or 'Panel',
        slots        = config.slots or 10,
        items        = session.items,
        allowedItems = allowedNames,
    }
    TriggerClientEvent('whip_core:client:openPanel', source, payload)

    -- Send weight info if maxWeight is configured. `panelId` says which panel it describes —
    -- without it a player holding two would have this written into whichever the UI happened
    -- to be pointing at.
    if session.config.maxWeight then
        TriggerClientEvent('whip_core:client:panelWeightInfo', source, {
            panelId       = session.id,
            maxWeight     = session.config.maxWeight,
            currentWeight = initialWeight,
        })
    end

    -- Send readOnly flag if configured
    if session.config.readOnly then
        TriggerClientEvent('whip_core:client:panelReadOnly', source, true, session.id)
    end

    return true
end

--- Open a panel — an extra grid beside the player's inventory that your resource owns: a workbench,
--- a trade window, a mailbox.
---
---     exports.whip_core:OpenPanel(source, {
---         id = 'bench_' .. source, label = 'Workbench', slots = 6,
---         onValidate = function(ctx) if ctx.item == 'cash' then return false, 'No cash on the bench' end end,
---         onChange   = function(ctx) --[[ ctx.items: what is in it now ]] end,
---         onClose    = function(ctx) --[[ ctx.items: what was left in it ]] end,
---     })
---
--- The hooks are the panel's (see panelInstanceFor) and each gets one table — the same shapes a
--- RegisterPanelItem panel's hooks get (the panel kind in stores.lua):
---   onValidate(ctx)  before a player's move: return false, 'why' to refuse
---   onChange(ctx)    after a player's move landed
---   onClose(ctx)     when the last viewer has left: { panel, source, items }
--- Your own StoreGive / StoreTake into a panel are not asked: your resource is the one deciding.
--- Answers `true` or `false, reason`. The same id opened twice by one player is a no-op.
---@param source number
---@param config table { id, label?, slots?, items?, maxWeight?, readOnly?, allowedItems?, onValidate?, onChange?, onClose? }
---@return boolean ok
---@return string|nil err
exports('OpenPanel', function(source, config)
    return OpenPanelInternal(source, config, GetInvokingResource() or 'unknown')
end)

--- Close a panel for a player. Leave `panelId` out to close every panel they have open.
--- Answers `true`, or `false, 'No such panel open'`.
---@param source number
---@param panelId any|nil
---@return boolean ok
---@return string|nil err
exports('ClosePanel', function(source, panelId)
    if Panels.closeFor(source, panelId, true) then return true end
    return false, 'No such panel open'
end)

-- A panel is a store like any other: a resource fills and empties it with StoreGive / StoreTake /
-- GetItemAt and the address `{ kind = 'panel', id = panelId, slot = n }`, with a stash's rules and log.

--- Finish a SERVER-SIDE write into a panel slot: make it durable, and show it to every viewer.
---
--- The one ending for every server write into a panel (StoreGive / StoreTake / SetItemMetadata with
--- a panel address, through finishDirectWrite in stores.lua).
---@param source number  a viewer of the panel (whose session was written through)
---@param session table
---@param slot number
function Panels.serverWrote(source, session, slot)
    -- A server-initiated change is still a change: durable, like a player's drag. Cheap: for an
    -- unchanged host the fold produces no rows.
    if session.registration then
        Panels.persistToHost(source, session)
    end

    -- Every viewer, not just the caller: session.items is the shared table, so all of them repaint
    -- the slot. What the slot now HOLDS, not what was asked for: the store may have normalised it.
    local now = session.items[slot]
    for viewer in pairs(Stores.viewersOf('panel:' .. tostring(session.id))) do
        -- The panel id rides along on both messages: a viewer may hold several panels.
        TriggerClientEvent('whip_core:client:updateExternalPanelSlot', viewer, slot, now, session.id)

        if session.config.maxWeight then
            TriggerClientEvent('whip_core:client:panelWeightInfo', viewer, {
                panelId       = session.id,
                maxWeight     = session.config.maxWeight,
                -- Named: each viewer may have several open.
                currentWeight = calculatePanelWeight(viewer, session.id),
            })
        end
    end
end

--- action -> { [itemKey] = opener }, so several items can hang a panel off one context action.
local _panelItemActions = {}

--- itemKey -> the registration config, for anything that needs an item's SHAPE (weight asks an item
--- what is inside it: Inventory.effectiveWeight). On the module: server/inventory.lua loads first
--- and reads it at runtime.
Panels.itemConfigs = {}

--- The panel items, on the one registration rule (shared/registry.lua): a second resource registering
--- the same item is refused, with the first one's name. `same = false`: a config carries functions
--- that arrive as new references every time, so a re-registration always swaps the config in.
---
--- A stopping satellite takes its panel items with it (onRemove, run by the registry's sweep): its
--- read/write/onValidate would be calls into a dead resource. The restarted resource registers again
--- from whip_core:onReady.
local _panelItems = Registry.new('PanelItem', {
    label = 'panel item',
    store = Panels.itemConfigs,
    same  = false,
    onRemove = function(itemKey)
        for _, byItem in pairs(_panelItemActions) do byItem[itemKey] = nil end
        Inventory.invalidateItemDefs()   -- a holder gone: the games' copy of what counts inside one (holds, insideOf)
    end,
})

--- The "empty slots" metadata generators RegisterPanelItem made itself, so a re-registration can
--- tell its own from one the satellite registered with RegisterItemDefaultMetadata. Weak: a generator
--- the registry has dropped needs no remembering.
local _panelGenerators = setmetatable({}, { __mode = 'k' })

-- A stopping resource's open panels are closed too (onResourceStop below). An ITEM's panel (a wallet,
-- a bag) loses nothing: its contents were folded into the host item on every change. An OPENED panel
-- (a bench, a trade window) has its contents nowhere else, so each player gets back what they put in
-- (returnDeposits).
-- whip_core itself stopping: every opened panel's deposits go back to the characters who put them in,
-- in their pockets only (nothing here may wait on the database); the resource's own stock goes,
-- logged. Step 20 of whip_core's stop (server/lifecycle.lua), before step 60 sends every owed save,
-- these gives included.
CoreStop.add(20, 'panels: return opened panels', function()
    for panelId, inst in pairs(Panels._instances) do
        if next(inst.items or {}) then
            for src, mine in pairs(Panels._sessions) do
                local session = mine[panelId]
                if session and not session.registration then
                    if not (session.config and session.config.readOnly) then
                        returnDeposits(inst, session,
                            { why = 'returned from a panel when whip_core stopped', inPockets = true, closer = src })
                    end
                    break
                end
            end
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then return end   -- whip_core's own: the step above

    -- A panel's hooks go with the resource that set them, even while the panel stays open for
    -- someone another resource let in: they point into a resource that is gone.
    for _, inst in pairs(Panels._instances) do
        if inst.hookOwner == res then inst.hooks, inst.hookOwner = nil, nil end
    end

    -- Collected first: Panels.closeFor mutates the tables being walked. The session's callbacks are
    -- dropped before closing — they point into the resource that just stopped. An opened panel is
    -- marked orphaned, so the last close hands its contents back instead of dropping them.
    local toClose = {}
    for src, mine in pairs(Panels._sessions) do
        for id, session in pairs(mine) do
            if session.resource == res then
                session.onClose = nil
                if not session.registration then
                    local inst = Panels._instances[session.id]
                    if inst then inst.orphaned = ('returned from a panel when %s stopped'):format(res) end
                end
                toClose[#toClose + 1] = { src, id }
            end
        end
    end
    for _, c in ipairs(toClose) do Panels.closeFor(c[1], c[2], true) end
end)

--- Shut a panel whose host item no longer exists: a RegisterPanelItem panel is a VIEW of an item,
--- and with the item destroyed, consumed or traded it describes nothing. (The panel kind's
--- beforeMove checks the host for every panel that has one.)
---@param source number
---@param session table
---@return boolean closed
function Panels.closeIfHostGone(source, session)
    if not (session and session.host) then return false end
    if Panels.resolveHost(source, session) then return false end

    -- Through the shared close (refcount and viewer set stay honest), naming the id: anyone else
    -- inside, and this player's other panels, are unaffected.
    Panels.closeFor(source, session.id, true)
    ShowError(source, 'That item is no longer in your inventory')
    return true
end

--- Resolve the item a RegisterPanelItem panel belongs to, read FRESH from the inventory (the panel
--- store kind in stores.lua calls it at runtime). Re-read, not captured at open: the host can be
--- moved, split or consumed while its panel is on screen. A nil return means the host is gone:
--- refuse, never "empty".
---@param source number
---@param session table
---@return table|nil host { source, container, slot, addr, item, amount, metadata } (panelHost)
function Panels.resolveHost(source, session)
    local h = session and session.host
    if not h then return nil end

    local player = Players[source]
    if not player or not player.inventory then return nil end

    -- Identity is the uid, not the slot: a host opened with a uid must still carry that uid (a
    -- different duffle swapped into the slot is not this host).
    local function isHost(sd)
        if not sd or sd.item ~= h.itemKey then return false end
        if h.uid == nil then return true end
        return sd.metadata ~= nil and sd.metadata.uid == h.uid
    end

    local slotData = Inventory.getSlot(player.inventory, h.container, h.slot)
    if not isHost(slotData) then
        -- Follow it around the player's own pockets: a bag dragged to another slot is the same bag,
        -- and its panel should keep working rather than slam shut. Out of the pockets altogether —
        -- a stash, the floor, another player — and it is gone as far as this panel is concerned.
        if h.uid == nil then return nil end
        slotData = nil
        for _, container in ipairs(PlayerContainers) do
            local slots = player.inventory[container]
            if slots then
                for s, sd in pairs(slots) do
                    if isHost(sd) then
                        h.container, h.slot, slotData = container, s, sd
                        break
                    end
                end
            end
            if slotData then break end
        end
        if not slotData then return nil end
    end

    -- (isHost(nil) is false, and the search above returned if it found none.)
    ---@cast slotData -nil
    return panelHost(source, h.container, h.slot, slotData)
end

--- Bring a RegisterPanelItem panel back in line with its host item, if the host changed without
--- going through the panel.
---
--- The panel is a view, and a view can go stale: the host changes by routes that never touch the
--- panel (gunny's shots rewrite the magazine; a bag can leave, be emptied, and come back with the
--- same uid). Folding the old view back over that would hand out the difference.
---
--- So `session.base` records what the host looked like when the panel last read or wrote it. If
--- the host no longer matches, the panel is re-read from it, the player's grid is repainted, and
--- the caller treats the panel as stale. The host always wins; it is where the items live.
---@param source number
---@param session table
---@param host table|nil  an already-resolved host, or nil to resolve it here
---@return boolean refreshed  true when the panel was stale and has been re-read
function Panels.refreshFromHost(source, session, host)
    local reg = session and session.registration
    if not (reg and session.host) then return false end
    host = host or Panels.resolveHost(source, session)
    if not host then return false end

    local fresh = projectHost(reg, session.host.storageKey, host)
    if not fresh then return false end   -- read() errored; there is nothing better to show
    if session.base and sameItems(fresh, session.base) then return false end

    -- In place: session.items is the panel instance's table, and other references to it exist.
    local items, touched = session.items, {}
    for slot in pairs(items) do touched[slot] = true end
    for slot in pairs(fresh) do touched[slot] = true end
    for slot in pairs(touched) do items[slot] = nil end
    for slot, v in pairs(fresh) do
        items[slot] = { item = v.item, amount = v.amount or 1, metadata = Inventory.copyMetadata(v.metadata) }
    end
    session.base = snapshotItems(items)

    for slot in pairs(touched) do
        TriggerClientEvent('whip_core:client:updateExternalPanelSlot', source, slot, items[slot], session.id)
    end
    return true
end

--- Fold a panel's current contents back into the item that owns it, and persist.
---
--- On every change, not just at close: the panel kind has no persistence of its own (its contents
--- are a VIEW of the host's metadata), so a dragged-in item would otherwise live in memory alone for
--- as long as the screen stays up. Write-behind coalesces the repeated writes.
---@param source number
---@param session table
---@param asReply boolean|nil  true only when this fold's inventoryUpdate answers a pending NUI drag
---@return boolean ok
---@return string|nil reason
function Panels.persistToHost(source, session, asReply)
    if not (session and session.registration and session.host) then return false, 'not a panel item' end

    local host = Panels.resolveHost(source, session)
    if not host then return false, 'host item is gone' end

    local player = Players[source]
    if not player or not player.inventory then return false, 'no player' end

    local reg = session.registration
    local newMeta

    if reg.write then
        -- A declared write() folds into the host's OWN shape.
        local ok, result = pcall(reg.write, host, session.items or {})
        if not ok then
            print(('[whip_core:panel] write() errored for "%s": %s — contents NOT saved')
                :format(tostring(session.host.itemKey), tostring(result)))
            return false, 'write() errored'
        end
        -- A table or nothing: a write() that forgot to return would wipe the host's metadata.
        if type(result) ~= 'table' then
            print(('[whip_core:panel] write() for "%s" returned %s, not a metadata table — contents NOT saved')
                :format(tostring(session.host.itemKey), type(result)))
            return false, 'write() returned no metadata'
        end
        newMeta = result
        -- Keep the host's identity even when a write() builds its metadata from scratch.
        if host.metadata and host.metadata.uid and newMeta.uid == nil then
            newMeta.uid = host.metadata.uid
        end
    else
        newMeta = host.metadata
        newMeta[session.host.storageKey] = session.items or {}
    end

    Inventory.setSlot(player.inventory, host.container, host.slot,
        host.item, host.amount, newMeta)

    -- What the host holds NOW is what the panel last wrote, so it is the new baseline for
    -- Panels.refreshFromHost. Read back through the projection rather than copied from the panel:
    -- write() may add to what it was given (gunny mints a magazine's serial here).
    local stored = Inventory.getSlot(player.inventory, host.container, host.slot)
    local after = stored and projectHost(reg, session.host.storageKey,
        panelHost(source, host.container, host.slot, stored))
    session.base = after and snapshotItems(after) or nil

    -- A reply only when this fold IS the answer the NUI is waiting for (see the panel kind's
    -- afterMove); any other fold is unsolicited (Inventory.syncAndSave's default).
    Inventory.syncAndSave(source, player, asReply)
    return true
end

--- Would the item take what this move leaves in it? A RegisterPanelItem's write() packs the panel
--- into its item AFTER the move has landed, so it is tried FIRST, on copies of the contents as the
--- move would leave them. If it fails, the move is refused, nothing changes, and the console names
--- the item: a broken write() blocks a move instead of corrupting one. Nothing is asked of a panel
--- without a write() (whip's own packing can't fail) or of a swap's returning half.
---
--- write() must therefore only build and return metadata: whip may call it to check a move.
---@param session table  the panel session (a RegisterPanelItem one)
---@param host table     the host item (Panels.resolveHost)
---@param ctx table      the panel kind's beforeMove ctx
---@return string|nil why  the refusal, or nil when the item can take it
function Panels.writeWouldFail(session, host, ctx)
    local reg = session and session.registration
    if not (reg and reg.write and host) or ctx.swap then return nil end

    local items = {}
    for slot, d in pairs(session.items or {}) do
        if type(d) == 'table' then
            items[slot] = { item = d.item, amount = d.amount or 1, metadata = Inventory.copyMetadata(d.metadata) }
        end
    end
    local function copyOf(e, amount)
        return { item = e.item, amount = amount or e.amount or 1, metadata = Inventory.copyMetadata(e.metadata) }
    end
    local amount = math.max(1, math.floor(tonumber(ctx.amount) or 1))
    local swap = ctx.replacing
    -- A slot gives up `amount` — or, in a swap, takes what is swapped back into it.
    local function leave(slot)
        local d = items[slot]
        if not d then return end
        if swap and not ctx.destroyed then items[slot] = copyOf(swap) return end
        d.amount = d.amount - amount
        if d.amount <= 0 then items[slot] = nil end
    end
    -- A slot takes the moving item — onto the same item a merge, onto another a swap.
    local function arrive(slot)
        local d = items[slot]
        if d and not swap and d.item == ctx.item then d.amount = d.amount + amount
        else items[slot] = copyOf(ctx, amount) end
    end
    if ctx.direction == 'in' then
        arrive(ctx.slot)
    elseif ctx.direction == 'out' then
        leave(ctx.slot)
    elseif ctx.direction == 'within' then
        leave(ctx.slot)
        arrive(ctx.otherSlot)
    end

    local trial = {}
    for k, v in pairs(host) do trial[k] = v end
    trial.metadata = Inventory.copyMetadata(host.metadata) or {}
    local ok, result = pcall(reg.write, trial, items)
    local itemKey = tostring(session.host and session.host.itemKey or host.item)
    if not ok or type(result) ~= 'table' then
        print(('[whip_core:panel] the write() registered for "%s" %s when checking a move — the move is refused, so nothing is lost or copied. Fix that write().')
            :format(itemKey, ok and ('returned ' .. type(result) .. ', not a metadata table') or ('errored: ' .. tostring(result))))
        return ('The %s could not take that'):format(session.config and session.config.label or itemKey)
    end
    return nil
end

--- A fold that failed with its host still there. The move was already saved (commitMove saves, then
--- the panel folds in afterMove), so the item has moved and its host doesn't know. Undoing a
--- committed move here is not safe (hooks, merges, a second viewer), so:
---   * the move is written down — 'gained' out of it, 'lost' into it — so the timeline shows it;
---   * the panel is shut, and that item's panel does not open again until whip_core restarts, so the
---     one bad fold cannot be repeated into a dupe;
---   * the console says whose write() it was.
--- Only a write() that passed Panels.writeWouldFail (above) and then failed on the real contents gets
--- here: the last resort behind the check.
local _foldBlocked = {}   -- [host uid] = true

---@param uid any
---@return boolean
function Panels.foldBlocked(uid)
    return uid ~= nil and _foldBlocked[uid] == true
end

---@param source number
---@param session table
---@param ctx table  the afterMove ctx: direction, item, amount
---@param reason string|nil  the fold's reason
function Panels.foldFailed(source, session, ctx, reason)
    local uid = session.host and session.host.uid
    if uid ~= nil then _foldBlocked[uid] = true end
    local itemKey = session.host and session.host.itemKey or '?'
    local player = Players[source]
    local charId = player and player.charId or nil
    if ctx and ctx.item then
        -- A destroy is 'out' too, and nobody gained it (the destroy writes its own row). Only an item
        -- that went into the pockets is written down as gained here.
        if ctx.direction == 'out' and not ctx.destroyed then
            Log.gained(charId, ctx.item, ctx.amount or 1,
                ('taken out of a %s whose contents could not be saved — it may still show inside it'):format(itemKey))
        elseif ctx.direction == 'in' then
            Log.lost(charId, ctx.item, ctx.amount or 1,
                ('put into a %s whose contents could not be saved'):format(itemKey))
        end
    end
    print(('[whip_core:panel] CRITICAL: a move in the %s panel of %s stood but could not be folded into the item (%s). The panel is shut and that item will not open again until whip_core restarts. Fix the write() of whoever registered "%s".')
        :format(itemKey, tostring(source), tostring(reason), itemKey))
    Panels.closeFor(source, session.id, true)
    ShowError(source, 'That could not be saved. The item has been shut.')
end

-- ============================================
-- RegisterPanelItem — Declarative item-as-panel
-- ============================================
-- Registers an item whose context action opens a panel (using OpenPanel internally).
-- Auto-registers: metadata generator, context action, onClose handler (saves items back).
-- Uses OpenPanelInternal directly (no export boundary, avoids function-in-table stripping).
--
-- config = {
--   slots        = number (default 3),
--   label        = string | function(host) (default item name),
--   storageKey   = string (default 'slots'),
--   allowedItems = { 'cash', 'id_card' } or { cash = {...}, id_card = true } (optional; only the
--                  names count — a per-item maxPerSlot is not enforced, see the note below),
--   allowedFlag  = string (optional): also every item whose definition has this field set to true
--                  (the wallet's 'wallet'). Plain slot array only. HasItem, GetItemCount and FindItem
--                  look inside such an item for the items its flag lets in.
--
--   -- How the contents are kept in the item. Both absent = a plain slot array at
--   -- meta[storageKey], so a wallet stays four lines.
--   canOpen    = function(host) -> ok, why        may it open at all?
--   read       = function(host) -> items          what the panel SHOWS
--   write      = function(host, items) -> meta    how a change folds back
--
--   -- The panel's hooks — the same two, with the same one-table argument, as OpenPanel's
--   -- (ctx.host, ctx.items):
--   onValidate = function(ctx) -> ok, why         may this move happen?
--   onChange   = function(ctx)                    after it landed
-- }
--
-- read/write: without them a panel item stores one shape, a slot array at meta[storageKey]. A
-- magazine is {item, ammo, serial}; a chambered round is a NUMBER. read renders the host's own
-- shape as slots and write folds slots back, so the panel is a PROJECTION of the host's metadata
-- and needs no persistence of its own.
--
-- onValidate, not allowedItems, for a rule that needs the HOST ("does this magazine fit THIS gun").
---@param itemKey string
---@param config table
---@return boolean
exports('RegisterPanelItem', function(itemKey, config)
    return Panels.registerItem(itemKey, config, Registry.caller())   -- the caller first
end)

--- RegisterPanelItem's body, with its owner. whip_core's own panel items (server/items/*.lua) call this.
---@param resource string
function Panels.registerItem(itemKey, config, resource)
    if type(config) ~= 'table' then
        return false, ('RegisterPanelItem("%s"): expected a config table'):format(tostring(itemKey))
    end
    if type(itemKey) ~= 'string' or itemKey == '' then
        return false, 'RegisterPanelItem: the item key must be a string'
    end

    -- Asked first, before anything below changes a table: another running resource's panel item
    -- is theirs (the registry's rule), and a refusal must leave nothing half-registered.
    local holder = _panelItems:ownerOf(itemKey)
    if holder and holder ~= resource and Registry.alive(holder) then
        local reason = ('panel item "%s" belongs to %s'):format(itemKey, holder)
        print(('[whip_core:panel] RegisterPanelItem refused for %s: %s'):format(resource, reason))
        return false, reason
    end
    -- Whose callbacks these are, so the panel kind hands onValidate/onChange a satellite-safe ctx
    -- when they belong to another resource. The table is whip_core's own copy by now.
    config._resource = resource
    local storageKey = config.storageKey or 'slots'
    local itemDef = Config.Items[itemKey]

    -- Which action opens the panel: config.action, or the item's defaultAction (what happens when it
    -- is USED). A phone's "Open" is a context option, and the phone has no defaultAction.
    local action = config.action or (itemDef and itemDef.defaultAction)

    if not action then
        local reason = ('item "%s" has no defaultAction and the registration named no action')
            :format(tostring(itemKey))
        print(('[whip_core:panel] RegisterPanelItem FAILED: %s'):format(reason))
        return false, reason
    end
    if not itemDef then
        local reason = ('item "%s" is not registered'):format(tostring(itemKey))
        print(('[whip_core:panel] RegisterPanelItem FAILED: %s'):format(reason))
        return false, reason
    end

    -- Not a stacking item: a stack shares one metadata table, so every split would copy the
    -- contents. Refused rather than quietly changed: the item's definition is its owner's to fix.
    if itemDef.stack then
        local reason = ('item "%s" stacks, and a panel item cannot: every split would copy its contents. Register it with stack = false'):format(itemKey)
        print(('[whip_core:panel] RegisterPanelItem FAILED: %s'):format(reason))
        return false, reason
    end

    -- allowedFlag: items whose definition carries this field take a place too (the wallet's `wallet = true`),
    -- so another resource's card fits without whip_core naming it. Only for the plain slot array: a
    -- read/write registration keeps its own shape, which HasItem and FindItem cannot look into.
    if config.allowedFlag ~= nil then
        local flag = config.allowedFlag
        local why = (type(flag) ~= 'string' or not flag:match('^[%a_][%w_]*$'))
                and 'allowedFlag must be the name of an item field (letters, digits, _)'
            or (config.read or config.write) and 'allowedFlag needs the plain slot array (no read or write)'
            or nil
        if why then
            local reason = ('item "%s": %s'):format(itemKey, why)
            print(('[whip_core:panel] RegisterPanelItem FAILED: %s'):format(reason))
            return false, reason
        end
    end

    -- Auto-generate empty metadata on item creation, only for the plain slot-array registrations
    -- that use storageKey (a read/write registration owns its shape, and says so with
    -- RegisterItemDefaultMetadata).
    --
    -- Through the owned registry, as the registering resource: it only fills an EMPTY place (or one
    -- this function filled before), and it goes with its owner.
    if not (config.read or config.write) then
        local existing = Inventory.MetaGenerators[itemKey]
        if existing == nil or _panelGenerators[existing] then
            local generator = function()
                return { [storageKey] = {} }
            end
            _panelGenerators[generator] = true
            local okGen, whyGen = Inventory.registerMetaGeneratorFor(resource, itemKey, generator)
            if not okGen then
                print(('[whip_core:panel] "%s": no empty-slots default, %s'):format(itemKey, tostring(whyGen)))
            end
        end
    end

    -- The opener for THIS item. Registered into a per-action table below rather than straight
    -- onto the action, so a family of items can share one context action.
    local function openThisItem(source, _, slotData, container, slot)
        if not slotData or slotData.item ~= itemKey then return end

        local host = panelHost(source, container, slot, slotData)
        local meta = host.metadata

        -- Not an item whose contents could not be saved (Panels.foldFailed): its metadata still shows
        -- what the failed fold should have taken out.
        if meta.uid ~= nil and Panels.foldFailed and Panels.foldBlocked(meta.uid) then
            ShowError(source, 'This could not be saved properly and stays shut until the server restarts.')
            return
        end

        -- May this open at all? Checked before anything is read, so an item that must stay shut (a
        -- locked box) never has its contents projected. Same contract as onValidate; an erroring
        -- hook fails CLOSED.
        if config.canOpen then
            local ok, allowed, reason = pcall(config.canOpen, host)
            if not ok then
                print(('[whip_core:panel] canOpen() errored for "%s": %s')
                    :format(itemKey, tostring(allowed)))
                ShowError(source, 'You cannot open that right now.')
                return
            end
            if allowed == false then
                ShowError(source, reason or 'You cannot open that.')
                return
            end
        end

        -- What the panel shows. A declared `read` projects the host's OWN metadata shape into
        -- slots; without one, fall back to reading meta[storageKey] as a plain slot array.
        local items, readErr = projectHost(config, storageKey, host)
        if not items then
            print(('[whip_core:panel] read() errored for "%s": %s')
                :format(itemKey, tostring(readErr)))
            return
        end

        -- Build panel config. A label is a string or something callable taking the host, tried with
        -- pcall rather than type-checked (another resource's function arrives as a callable table).
        -- Only a string is ever sent on.
        local label = config.label
        if label ~= nil and type(label) ~= 'string' then
            local ok, resolved = pcall(label, host)
            label = (ok and type(resolved) == 'string') and resolved or nil
        end

        -- The id identifies the ITEM: Panels._instances is keyed by it and IS the shared contents
        -- table, so two wallets sharing an id would share contents. The item's own uid when it has
        -- one (customContextAction stamps it before dispatching here), else container and slot.
        -- `source` stays: a RegisterPanelItem panel is one player's own. Where the item is NOW is
        -- session.host plus Panels.resolveHost.
        local hostUid = meta.uid
        local panelConfig = {
            id    = hostUid and (action .. '_' .. source .. '_' .. tostring(hostUid))
                or (action .. '_' .. source .. '_' .. tostring(container) .. '_' .. tostring(slot)),
            label = label or itemDef.name or 'Panel',
            slots = config.slots or 3,
            items = items,
        }

        -- allowedItems, as a list of names or a keyed table — allowedSet reads both. Only the NAMES
        -- are enforced: a keyed shape's per-item options (maxPerSlot) are not implemented.
        panelConfig.allowedItems = allowedSet(config.allowedItems)
        -- And every item that opts in by its allowedFlag field, read at each opening, so an item
        -- registered after this one (another resource's card) fits too.
        if config.allowedFlag then
            panelConfig.allowedItems = panelConfig.allowedItems or {}
            for key, def in pairs(Config.Items) do
                if type(def) == 'table' and def[config.allowedFlag] == true then
                    panelConfig.allowedItems[key] = true
                end
            end
        end

        -- Open the panel (handles both fresh open and overlay). Asked first: opening a panel that
        -- is already open is a no-op in OpenPanelInternal, and this one then has to re-read its host.
        local alreadyOpen = Panels.sessionFor(source, panelConfig.id) ~= nil
        local opened = OpenPanelInternal(source, panelConfig, resource)
        if not opened then return end

        -- Hand the session what the store kind's hooks (beforeMove/afterMove) need to find the host
        -- item. Named by id: the player may hold several panels.
        local session = Panels.sessionFor(source, panelConfig.id)
        if session then
            session.registration = config
            session.host = {
                container = container,
                slot      = slot,
                itemKey   = itemKey,
                storageKey = storageKey,
                uid       = hostUid,   -- what Panels.resolveHost matches on; see there
            }

            -- The baseline Panels.refreshFromHost compares against. A panel that was already open
            -- kept its old contents, so it is checked against the host instead.
            if alreadyOpen then
                Panels.refreshFromHost(source, session)
            else
                session.base = snapshotItems(items)
            end

            -- Close is a backstop, not the moment contents are saved: every change is already folded
            -- into the host (Panels.persistToHost). It still runs for a server-side mutation that
            -- bypassed both hooks; an unchanged panel folds to nothing.
            session.onClose = function(src)
                -- The live session for this panel if one is still registered, else the captured one.
                local live = Panels.sessionFor(src, panelConfig.id) or session
                -- A host that changed outside the panel wins: re-read it, so the fold below writes
                -- back the host's own contents rather than the panel's old copy of them.
                Panels.refreshFromHost(src, live)
                -- Refused with 'host item is gone' when the host was consumed, destroyed, or moved out of
                -- reach. Nothing is lost: contents travel folded into the host's metadata, so they went
                -- where it went. An ordinary outcome, not logged.
                Panels.persistToHost(src, live)
            end
        end
    end

    -- One context handler per action, dispatching on the item being used: an item FAMILY shares one
    -- action (whip_gunny's weapons all use 'whip_gunny:open_weapon').
    --
    -- Owned by whip_core, so a satellite can't take the action over; a name another resource already
    -- holds is a refusal.
    local byItem = _panelItemActions[action]
    if not byItem then
        local newByItem = {}
        -- Context actions are handed the item's address; the opener keeps its pocket + slot.
        local okAct, whyAct = Inventory.registerCoreContextAction(action, function(source, player, slotData, addr)
            if not slotData or not addr then return end
            local opener = newByItem[slotData.item]
            if opener then opener(source, player, slotData, addr.sub, addr.slot) end
        end)
        if not okAct then
            local reason = ('panel item "%s" cannot use action "%s": %s'):format(itemKey, action, tostring(whyAct))
            print(('[whip_core:panel] RegisterPanelItem FAILED: %s'):format(reason))
            return false, reason
        end
        byItem = newByItem
        _panelItemActions[action] = byItem
    end
    byItem[itemKey] = openThisItem

    -- Recorded so weight can ask this item what is inside it. Stored AFTER every validation
    -- above, so a refused registration never leaves a shape behind for the weight code to
    -- believe in.
    local okItem, whyItem = _panelItems:add(resource, itemKey, config)
    if not okItem then return false, whyItem end
    -- A holder of items that stay the player's: the games learn it with the item definitions (holds, insideOf).
    if config.allowedFlag then Inventory.invalidateItemDefs() end

    return true
end

-- Panel moves are the panel store kind's beforeMove hook in stores.lua, reached through storeMove
-- like any other move.

-- ============================================
-- OpenPanel Close Event (client → server)
-- ============================================

SecureEvent('whip_core:server:closePanelSession', {
    whileDead = true,   -- dying closes the panel, and it has to fold back into its item
    rateLimit = 500,
    -- Burst 3; see the note on openInventory in server/events_inventory.lua. This close also repays
    -- a declined open (client/inventory.lua fires it when ConfirmPanel refuses), so two can arrive
    -- close together. The empty id means "all of them", so closing an inventory holding twenty
    -- wallets is one event (see ReleasePanels in client/inventory.lua).
    burst     = 3,
    -- Default '' so an absent id validates rather than being rejected as an empty string.
    params    = { {'panelId', 'string', 80, ''} },
}, function(source, _, panelId)
    -- The client told us it closed the panel(s). No UI message back — it already knows.
    -- '' is the close-everything form; anything else names one panel.
    Panels.closeFor(source, (panelId ~= '' and panelId or nil), false)
end)
