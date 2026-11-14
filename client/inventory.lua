-- Client inventory (F2). Other client files use Inventory.*.
-- Globals on purpose: the screen gates (IsAnyUIOpen, IsAnyScreenOpen, IsGameInputFree, MayOpenScreen,
-- FocusScreenUp, ExternalUIOpenForOthers), the hook registry (RegisterClientHook / RunClientHook), ThrowModeActive.
Inventory = {}

local invOpen = false

-- Declared here: used above their definitions.
local hasItem
local isGiveModeActive
local activePlayerInv = nil  -- an admin is looking at a player's inventory

--- Resource panels open now: [panelId] = panelConfig. Never nil (IsAnyUIOpen calls `next` on it).
local activePanels = {}

--- The store in the right-hand grid, when it is not a resource panel:
---   Inventory.activeContainerId     a stash's containerId
---   Inventory.activeVehicleStorage  { vehicleId, storageType }, as the server confirmed it
---   activeStore                     { kind, id, sub, storeId }, a resource's own store kind (a safe, a body)
--- Written only in this file; other files use the setters below. Inventory.close hands each back to the server.
Inventory.activeContainerId    = nil
Inventory.activeVehicleStorage = nil
local activeStore              = nil

--- Record (or, with nil, forget) the stash on screen. Forgetting does not release it.
---@param containerId number|nil
function Inventory.setActiveContainerId(containerId)
    Inventory.activeContainerId = containerId
end

--- Record (or, with nil, forget) the vehicle compartment on screen. Forgetting does not release it;
--- Inventory.releaseVehicleStorage does both.
---@param storage table|nil  { vehicleId, storageType }
function Inventory.setActiveVehicleStorage(storage)
    Inventory.activeVehicleStorage = storage
end

--- A resource took a store away (CloseStore): forget it without telling the server. Answers whether the screen was showing it.
---@param storeId string
---@return boolean wasShowing
function Inventory.forgetOpenStore(storeId)
    if activeStore and activeStore.storeId == storeId then
        activeStore = nil
        return true
    elseif Inventory.activeContainerId and ('container:' .. tostring(Inventory.activeContainerId)) == storeId then
        Inventory.activeContainerId = nil
        return true
    elseif Inventory.activeVehicleStorage and ('vehicle:%s:%s'):format(tostring(Inventory.activeVehicleStorage.vehicleId),
            tostring(Inventory.activeVehicleStorage.storageType)) == storeId then
        Inventory.activeVehicleStorage = nil
        return true
    end
    return false
end

--- Did a panel bring the inventory up (not the player)? If so, closing the last panel closes the inventory too.
local panelDrivenOpen = false

--- Is any resource panel open?
---@return boolean
local function hasActivePanel()
    return next(activePanels) ~= nil
end

--- Remember a panel the server opened, keyed by its id. A panel without an id is ignored.
---@param panel table  the OpenPanel config { id, label, slots, items, ... }
local function trackPanel(panel)
    if not panel or not panel.id then return end
    activePanels[panel.id] = panel
end

--- Release one panel, or every panel with no id: one event, since closePanelSession is rate limited (burst 3).
---@param panelId any|nil
local function releasePanels(panelId)
    if panelId ~= nil then
        if activePanels[panelId] then
            TriggerServerEvent('whip_core:server:closePanelSession', tostring(panelId))
            activePanels[panelId] = nil
        end
        return
    end
    if next(activePanels) == nil then return end
    TriggerServerEvent('whip_core:server:closePanelSession', '')
    activePanels = {}
end

-- Item flags: whether the player holds an item, for an action's canInteract etc.
--   exports.whip_core:RegisterItemFlag('lockpick')
--   exports.whip_core:RegisterItemFlag('my_valet_key', 'vehicle_key', function(meta) return meta and meta.vehicleId == id end)
--   exports.whip_core:HasItemFlag('lockpick')  --> true/false
local _itemFlagRegistry = {}  -- { [flagName] = { item = 'itemKey', filter = fn|nil } }
Inventory.itemFlags = {}           -- { [flagName] = true/false }
local _cachedInventory = nil   -- latest inventory table from server

-- The last full payload the server sent for a plain open, rendered at once on the next open while the fresh copy is in flight.
local _lastOpenPayload = nil

--- Does this client hold the item definitions yet? Sent with each open request so the server can leave them out. Set only when they arrive.
local _haveItemDefs = false

-- Is an open wanted? Set when F2 asks the server, cleared by any close, so a late reply does not reopen it.
local inventoryOpenRequested = false

-- Client hooks: whip_core names a moment, resources subscribe. A handler may return milliseconds for whip_core to wait.
-- Handlers are pcall'd. Keyed `<resource>:<id>` (id defaults to the hook name); registering again replaces; cleared when the resource stops.

local _clientHooks = {}   -- [hookName] = { ['<resource>:<id>'] = { fn, owner } }

--- The moments whip_core runs (RunClientHook). Any other name is refused.
local CLIENT_HOOKS = {
    beforeGiveMode  = true,   -- the inventory's give mode is opening (client/inventory.lua)
    beforePlaceMode = true,   -- an emote is being placed (client/emote_place.lua)
    freeHands       = true,   -- something is about to go in the player's hands (client/hands.lua)
}

--- Subscribe to a whip_core client moment.
---@param hookName 'beforeGiveMode'|'beforePlaceMode'|'freeHands'
---@param handler function  optionally returns a delay in ms
---@param id string|nil     defaults to hookName; pass one to hold two handlers on one hook
function RegisterClientHook(hookName, handler, id)
    -- Not a type check: a handler passed through the export is callable but not of type 'function'.
    if type(hookName) ~= 'string' or handler == nil then
        return false, 'RegisterClientHook: a hook name and a handler are required'
    end
    if not CLIENT_HOOKS[hookName] then
        local names = {}
        for n in pairs(CLIENT_HOOKS) do names[#names + 1] = n end
        table.sort(names)
        local why = ("RegisterClientHook: no moment called '%s' (whip_core runs %s)"):format(hookName, table.concat(names, ', '))
        print(('^3[whip_core] %s: %s^7'):format(GetInvokingResource() or GetCurrentResourceName(), why))
        return false, why
    end
    local owner = GetInvokingResource() or GetCurrentResourceName()
    _clientHooks[hookName] = _clientHooks[hookName] or {}
    _clientHooks[hookName][owner .. ':' .. tostring(id or hookName)] = { fn = handler, owner = owner }
    return true
end

exports('RegisterClientHook', RegisterClientHook)

-- In GetRegistrations with the registries (Registry.addLister).
Registry.addLister('clientHook', function()
    local out = {}
    for hookName, handlers in pairs(_clientHooks) do
        for key, reg in pairs(handlers) do out[#out + 1] = { key = hookName .. ' ' .. key, owner = reg.owner } end
    end
    return out
end)

AddEventHandler('onResourceStop', function(res)
    for hookName, handlers in pairs(_clientHooks) do
        for key, reg in pairs(handlers) do
            if reg.owner == res then handlers[key] = nil end
        end
        if next(handlers) == nil then _clientHooks[hookName] = nil end
    end
end)

-- How long one handler that waits itself may hold the moment up; past this whip goes on without it.
local HOOK_DEADLINE_MS = 1000
local _saidHookLate = {}

--- One handler in its own thread: (ok, result), or (true, nil) if still waiting after HOOK_DEADLINE_MS.
local function runHookHandler(reg, hookName, ...)
    local args = table.pack(...)
    local done, ok, result = false, nil, nil
    local p = promise.new()
    Citizen.CreateThreadNow(function()
        ok, result = pcall(reg.fn, table.unpack(args, 1, args.n))
        done = true
        p:resolve(true)
    end)
    if not done then
        SetTimeout(HOOK_DEADLINE_MS, function() p:resolve(false) end)
        Citizen.Await(p)
        if not done then
            local key = tostring(reg.owner) .. '|' .. hookName
            if not _saidHookLate[key] then
                _saidHookLate[key] = true
                print(('^3[whip_core] %s\'s client hook "%s" waited past %d ms: whip went on without it. Answer a delay (a number of ms) instead of waiting^7')
                    :format(tostring(reg.owner), hookName, HOOK_DEADLINE_MS))
            end
            return true, nil
        end
    end
    return ok, result
end

--- Run every handler for a moment; answers the longest delay asked (clamped to a second).
---@param hookName string
---@return integer ms
local function runHookHandlers(hookName, ...)
    local handlers = _clientHooks[hookName]
    if not handlers then return 0 end

    local longestWait = 0
    for _, reg in pairs(handlers) do
        local ok, result = runHookHandler(reg, hookName, ...)
        if not ok then
            ErrorTap.caught(('[whip_core] %s\'s client hook "%s" errored: %s'):format(tostring(reg.owner), hookName,
                tostring(result)), reg.owner)
        elseif type(result) == 'number' and result > longestWait then
            -- Clamped so a bad handler cannot freeze the player.
            longestWait = math.min(result, 1000)
        end
    end
    return longestWait
end

--- Run every handler registered for a moment, honouring the longest delay any asked for.
---@param hookName string
---@param ... any  passed to each handler
function RunClientHook(hookName, ...)
    local longestWait = runHookHandlers(hookName, ...)
    if longestWait > 0 then Wait(longestWait) end
end

-- FreeHands, the 'freeHands' moment's export, and blocking the hands: client/hands.lua.

--- Flags whose filter already threw (reported once).
local _itemFlagReported = {}

--- The flags (shared/registry.lua): another resource registering a held name is refused. A stopping resource's flags go with it.
local _itemFlags = Registry.new('ItemFlag', {
    label = 'item flag',
    store = _itemFlagRegistry,
    onAdd = function(flagName, flag)
        _itemFlagReported[flagName] = nil
        -- Answered from what is held now; pcall'd because the filter is another resource's code.
        local ok, held = pcall(hasItem, flag.item, flag.filter)
        Inventory.itemFlags[flagName] = ok and held == true
    end,
    onRemove = function(flagName)
        _itemFlagReported[flagName] = nil
        Inventory.itemFlags[flagName] = nil
    end,
})

--- Register an item flag; it goes when the registering resource stops. Answers `true`, or `false, reason`.
--- @param flagName string   Unique name for this flag (often the item key)
--- @param itemOrFilter string|function|nil   Item key (if different from flagName), or filter function
--- @param filter function|nil   Optional metadata filter: function(metadata) -> bool
--- @return boolean ok
--- @return string|nil err
function Inventory.registerItemFlag(flagName, itemOrFilter, filter)
    return Inventory.registerItemFlagFor(Registry.caller(), flagName, itemOrFilter, filter)   -- the caller first
end

--- The same, with its owner named (whip_core's own files).
---@param owner string
function Inventory.registerItemFlagFor(owner, flagName, itemOrFilter, filter)
    if type(flagName) ~= 'string' or flagName == '' then
        return false, 'an item flag needs a string name'
    end

    local itemKey = flagName
    local filterFn = nil

    -- Dispatch on the string: an exported filter is callable but not type 'function'.
    if type(itemOrFilter) == 'string' then
        -- Inventory.registerItemFlag('bounty_key', 'vehicle_key', function(meta) ... end)
        itemKey = itemOrFilter
        filterFn = filter
    elseif itemOrFilter ~= nil then
        -- Inventory.registerItemFlag('lockpick', function(meta) ... end)
        filterFn = itemOrFilter
    end

    local ok, why = _itemFlags:add(owner, flagName, { item = itemKey, filter = filterFn })
    if not ok then
        print(('[whip_core:inv] item flag refused for %s: %s'):format(owner, tostring(why)))
        return false, why --[[@as string]]   -- a refusal's reason
    end
    return true
end

function Inventory.hasItemFlag(flagName)
    return Inventory.itemFlags[flagName] == true
end

exports('RegisterItemFlag', Inventory.registerItemFlag)
exports('HasItemFlag', Inventory.hasItemFlag)

--- Does the player hold the item? A number in place of the filter is a minimum amount.
--- @param itemKey string
--- @param filter function|number|nil   Optional metadata filter, or a minimum amount
--- @return boolean
function hasItem(itemKey, filter)
    if not _cachedInventory then return false end
    if type(filter) == 'number' then
        return Inventory.getItemCount(itemKey) >= filter
    end
    for _, container in pairs(PlayerContainers) do
        local slots = _cachedInventory[container]
        if slots then
            for _, slot in pairs(slots) do
                if slot and slot.item == itemKey then
                    if filter then
                        if filter(slot.metadata) then return true end
                    else
                        return true
                    end
                end
            end
        end
    end
    return false
end

--- Count an item across all containers (a number in the filter's place is ignored).
--- @param itemKey string
--- @param filter function|nil   Optional metadata filter
--- @return number
---@diagnostic disable-next-line: duplicate-set-field -- the server's Inventory is a different table
function Inventory.getItemCount(itemKey, filter)
    if not _cachedInventory then return 0 end
    if type(filter) == 'number' or type(filter) == 'string' or type(filter) == 'boolean' then filter = nil end
    local count = 0
    for _, container in pairs(PlayerContainers) do
        local slots = _cachedInventory[container]
        if slots then
            for _, slot in pairs(slots) do
                if slot and slot.item == itemKey then
                    if filter then
                        if filter(slot.metadata) then
                            count = count + (slot.amount or 1)
                        end
                    else
                        count = count + (slot.amount or 1)
                    end
                end
            end
        end
    end
    return count
end

exports('HasItem', hasItem)
exports('GetItemCount', Inventory.getItemCount)

-- The item in the hand: the server keeps it (SetHeldItem) and tells this client on each change. An action's `require = { held = ... }` reads it here.

--- { item, pocket, slot } while something is held, else nil. Read-only: the server's word.
local _held = nil

RegisterNetEvent('whip_core:client:heldItem', function(h)
    if type(h) == 'table' and type(h.item) == 'string' then
        _held = { item = h.item, pocket = h.sub or 'player', slot = tonumber(h.slot) }
    else
        _held = nil
    end
end)

--- The held item as last told: { item, pocket, slot }, or nil. The live table: read only.
---@return table|nil
function Inventory.heldItem() return _held end

--- GetHeldItem(): what this player holds ({ item, pocket, slot }, a copy), or nil. For metadata use the server's GetHeldItem(source).
exports('GetHeldItem', function()
    if not _held then return nil end
    return { item = _held.item, pocket = _held.pocket, slot = _held.slot }
end)

--- The whole inventory, for a resource drawing its own inventory UI. A deep copy: editing it changes nothing.
--- To move an item fire `whip_core:server:storeMove`; the server validates.
---@return table inventory  { [container] = { [slot] = { item, amount, metadata } } }
---@return string|nil why  'Player not loaded' before the first sync
exports('GetInventory', function()
    if not _cachedInventory then return {}, 'Player not loaded' end

    local out = {}
    for container, slots in pairs(_cachedInventory) do
        local c = {}
        for slot, data in pairs(slots) do
            if data and data.item then
                local meta
                if type(data.metadata) == 'table' then
                    meta = {}
                    for k, v in pairs(data.metadata) do meta[k] = v end
                end
                c[slot] = { item = data.item, amount = data.amount, metadata = meta }
            end
        end
        out[container] = c
    end
    return out
end)

local function UpdateItemFlags(data)
    local inv = data and data.inventory
    if not inv then return end
    -- Reset all flags
    for flagName in pairs(_itemFlagRegistry) do
        Inventory.itemFlags[flagName] = false
    end
    -- Scan inventory for registered items
    for _, container in pairs(PlayerContainers) do
        local slots = inv[container]
        if slots then
            for _, slot in pairs(slots) do
                if slot then
                    for flagName, reg in pairs(_itemFlagRegistry) do
                        if not Inventory.itemFlags[flagName] and slot.item == reg.item then
                            if reg.filter then
                                -- pcall: a filter is another resource's code; a throw is a "no", reported once per flag.
                                local ok, held = pcall(reg.filter, slot.metadata)
                                if ok then
                                    if held then Inventory.itemFlags[flagName] = true end
                                elseif not _itemFlagReported[flagName] then
                                    _itemFlagReported[flagName] = true
                                    print(('[whip_core:inv] item flag "%s" (%s): its filter errored: %s')
                                        :format(flagName, tostring(_itemFlags:ownerOf(flagName)), tostring(held)))
                                end
                            else
                                Inventory.itemFlags[flagName] = true
                            end
                        end
                    end
                end
            end
        end
    end
end

-- Menu ped: the player's 3D character via the pause menu scene, beside the inventory.
local menuPed       = nil
local menuPedActive = false

--- Did the current show start the preview stage (frontend, ped, lighting)? A hide only undoes what a show did.
local menuPedStageUsed = false

--- Is the page's dim (#inv-wash) up? The preview-off way of dimming the screen.
local pageWashOn = false

--- Did the current show apply MENU_PED_TIMECYCLE? Only then does hideMenuPed clear it.
local menuPedTimecycleSet = false

-- HUD colour 117 (HUD_COLOUR_PAUSE_BG) is the pause menu's panel colour. Blanking it is global and lets the NUI show
-- through the ped scene; it must be put back or the real pause menu stays transparent.
local PAUSE_BG_HUD_INDEX = 117
local savedPauseBg = nil

-- Bumped on every show start and hide. An in-flight showMenuPed aborts if it changed, so a close while it sleeps
-- cannot leave a ped on a closed UI.
local menuPedGeneration = 0

-- The 3D character is off (the grid needs its column); MENU_PED_ENABLED = true brings it back. The screen dim stays either way.
-- A graphics pack can tint the character; SetPauseMenuPedLighting affects it.
local MENU_PED_ENABLED   = false
--- Where the preview body is built, below the player (a ped built beside a parked car deletes the car). Negative buries it in terrain, positive stands it in open air.
local MENU_PED_OFFSET    = -100.0
--- The pause menu's own ped light (SetPauseMenuPedLighting); false leaves it flat grey.
local MENU_PED_LIGHTING  = true
--- A timecycle modifier held while the inventory is open, or nil for the world's own.
local MENU_PED_TIMECYCLE = nil

--- How far and which way from the player the character is built (MENU_PED_OFFSET).
local function menuPedOffset()
    return MENU_PED_OFFSET
end

--- Build the 3D character away from the player. Not ClonePed: a ped created beside a parked street car deletes the car.
--- The pause menu destroys the ped on close, so it is not cached.
local function BuildMenuPed()
    local player = PlayerPedId()
    local model  = GetEntityModel(player)

    -- Already loaded (the player wears it); requested anyway so a null ped cannot happen.
    if not LoadModel(model, 2000) then return nil end

    local c = GetEntityCoords(player)
    local ped = CreatePed(4, model, c.x, c.y, c.z + menuPedOffset(), 0.0, false, false)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return nil end

    -- Display only: cannot be pushed, hurt or ragdolled.
    FreezeEntityPosition(ped, true)
    SetEntityCollision(ped, false, false)
    SetEntityInvincible(ped, true)
    SetPedCanRagdoll(ped, false)
    SetEntityVisible(ped, false, false)

    -- Dress it; on failure it warns and shows a bare body.
    local appearance = PlayerData and PlayerData.metadata and PlayerData.metadata.appearance
    if appearance then
        ApplyAppearance(ped, appearance)
    else
        print('[whip_core:inventory] no appearance data — inventory character will be a default ped')
    end

    return ped
end

--- The screen dim behind the inventory as one RGBA, for both paths. Lower alpha shows more world.
local INVENTORY_WASH = { r = 10, g = 12, b = 18, a = 200 }

local function showMenuPed()
    if menuPedActive then return end

    menuPedGeneration = menuPedGeneration + 1
    local myGeneration = menuPedGeneration

    --- Has a hide or another show happened meanwhile?
    local function superseded()
        return menuPedGeneration ~= myGeneration
    end

    -- Ped off: the page draws the dim (#inv-wash), no per-frame thread. With the preview on, the dim is script gfx
    -- behind the pausemenu layer (NUI composites last), the path below.
    -- Called directly, not from a thread: an open and close in one frame would otherwise leave the dim up.
    -- menuPedActive is still set so hideMenuPed's bookkeeping and the guards are unchanged.
    if not MENU_PED_ENABLED then
        pageWashOn = true
        SendNUIMessage({
            action = 'inventoryWash',
            show   = true,
            color  = ('rgba(%d, %d, %d, %.3f)'):format(
                INVENTORY_WASH.r, INVENTORY_WASH.g, INVENTORY_WASH.b, INVENTORY_WASH.a / 255),
        })
        menuPedActive = true
        return
    end

    -- Before the first native of the stage, so a hide knows there is a stage to take down.
    menuPedStageUsed = true
    SetFrontendActive(true)
    -- _NO_BACKGROUND: plain FE_MENU_VERSION_EMPTY draws a stray dark plate mid-screen.
    ActivateFrontendMenu(GetHashKey('FE_MENU_VERSION_EMPTY_NO_BACKGROUND'), false, -1)

    -- The backdrop: one rect per frame, under the frontend ped and over the world. Colour from INVENTORY_WASH.
    -- Stops on the next frame after a hide or newer show (generation check).
    CreateThread(function()
        while not superseded() do
            SetScriptGfxDrawBehindPausemenu(true)
            DrawRect(0.5, 0.5, 1.0, 1.0,
                INVENTORY_WASH.r, INVENTORY_WASH.g, INVENTORY_WASH.b, INVENTORY_WASH.a)
            SetScriptGfxDrawBehindPausemenu(false)
            Wait(0)
        end
    end)

    -- Cursor suppression in its own thread. 0x98215325A695E78A is SET_MOUSE_CURSOR_VISIBLE; the menu turns the cursor
    -- back on after the first call, so it is held down for about half a second.
    CreateThread(function()
        Wait(200)
        for _ = 1, 10 do
            if superseded() then return end
            Citizen.InvokeNative(0x98215325A695E78A, false)
            Wait(50)
        end
    end)

    -- How long the frontend gets to come up before the ped is handed over. Too short and GivePedToPauseMenu does nothing (no ped).
    Wait(50)

    -- A superseded show leaves the frontend alone: whoever bumped the generation owns it.
    if superseded() then return end

    local clone = BuildMenuPed()
    if not clone then
        SetFrontendActive(false)
        return
    end

    -- Last check: building can yield, so the UI may have closed. The ped is still ours to delete.
    if superseded() then
        DeleteEntity(clone)
        return
    end

    menuPed = clone

    GivePedToPauseMenu(clone, 0)         -- column 0 = left side
    -- A graphics pack can tint the ped light; MENU_PED_LIGHTING is the only switch over it.
    SetPauseMenuPedLighting(MENU_PED_LIGHTING)
    SetPauseMenuPedSleepState(true)

    -- Optional (off by default): pin the scene's lighting while the inventory is up, for the whole frame.
    if MENU_PED_TIMECYCLE then
        SetTimecycleModifier(MENU_PED_TIMECYCLE)
        menuPedTimecycleSet = true
    end
    -- Remember the pause menu's real background before blanking it. Captured once: re-reading could save our own transparent value.
    if not savedPauseBg then
        local r, g, b, a = GetHudColour(PAUSE_BG_HUD_INDEX)
        if a and a > 0 then
            savedPauseBg = { r = r, g = g, b = b, a = a }
        else
            -- Zero alpha means a crash or reload left it blanked: fall back to the default HUD_COLOUR_PAUSE_BG.
            savedPauseBg = { r = 0, g = 0, b = 0, a = 186 }
        end
    end

    ReplaceHudColourWithRgba(PAUSE_BG_HUD_INDEX, 0, 0, 0, 0) -- transparent background

    -- menuPed is assigned early so a show that loses the race can still delete its ped.
    menuPedActive = true
end

local function hideMenuPed()
    -- Cancel any in-flight show first, even when menuPedActive is still false.
    menuPedGeneration = menuPedGeneration + 1

    -- The page's dim, if this show used it.
    if pageWashOn then
        pageWashOn = false
        SendNUIMessage({ action = 'inventoryWash', show = false })
    end

    -- Below takes down the preview stage, only if a show started one (ClearTimecycleModifier would wipe others' filters).
    if not menuPedStageUsed then
        menuPed = nil
        menuPedActive = false
        return
    end
    menuPedStageUsed = false

    -- Not guarded on menuPedActive: the show turns the frontend on long before it sets that flag.
    SetFrontendActive(false)

    -- Give the pause menu its background back, unconditionally (the colour is global).
    if savedPauseBg then
        ReplaceHudColourWithRgba(PAUSE_BG_HUD_INDEX,
            savedPauseBg.r, savedPauseBg.g, savedPauseBg.b, savedPauseBg.a)
    end

    -- Undo the two ped display settings (global switches).
    SetPauseMenuPedLighting(false)
    SetPauseMenuPedSleepState(false)

    -- Give the world its lighting back if this show took it (guarded on what the show did, not the setting).
    if menuPedTimecycleSet then
        menuPedTimecycleSet = false
        ClearTimecycleModifier()
    end

    -- Releases the pause menu's hold on the ped (counterpart of GivePedToPauseMenu).
    ClearPedInPauseMenu()

    -- The menu usually destroys the ped itself; this covers when it did not.
    if menuPed and DoesEntityExist(menuPed) then
        DeleteEntity(menuPed)
    end

    menuPed = nil
    menuPedActive = false
end

--- The ped outlives the UI, so a resource stop deletes it by hand.
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if menuPed and DoesEntityExist(menuPed) then DeleteEntity(menuPed) end
    menuPed = nil
end)

function Inventory.isOpen()
    return invOpen
end

-- A death closes it (and any shop or stash), or it would hold focus over the death screen. Inventory.close also releases the server side.
AddEventHandler('whip_core:player:died', function()
    if invOpen then Inventory.close() end
end)

-- Satellite UIs: resources that declared their own screen open, so IsAnyUIOpen covers them.
-- Keyed from the calling resource (Registry.caller) and dropped when it stops.
--- [resource] = { [key] = { keepHud = bool } }; a resource with one screen passes no key.
local externalUIs = {}

--- Declare that this resource's own UI is open or closed; whip then treats it like one of its own screens.
---     exports.whip_core:SetUIOpen(true)  /  SetUIOpen(false)
--- With more than one screen, name each: SetUIOpen(true, 'shop'). No need to unset on stop or restart.
--- `{ keepHud = true }` (the phone) leaves the status HUD, minimap and vehicle dial up; chat, prompts and hotkeys
--- still make way. If it sits where the HUD is, say where with SetUIArea (client/hud.lua).
---@param open boolean
---@param key string|nil  which of your screens; leave it out if you only have one
---@param opts table|nil  { keepHud = true }: the HUD stays up for this screen
---@return boolean accepted  false if there was no calling resource to attribute this to
exports('SetUIOpen', function(open, key, opts)
    local res = GetInvokingResource()
    -- nil means the call came from inside whip_core, which sets its own state directly.
    if not res then return false end
    key = key ~= nil and tostring(key) or 'default'
    local mine = externalUIs[res]
    if open then
        if not mine then mine = {} externalUIs[res] = mine end
        mine[key] = { keepHud = type(opts) == 'table' and opts.keepHud == true }
    elseif mine then
        mine[key] = nil
        if next(mine) == nil then externalUIs[res] = nil end
    end
    return true
end)

--- Does a resource other than `owner` have a screen open? Dialogs ask before opening (client/ui.lua).
---@param owner string|nil
---@return boolean
function ExternalUIOpenForOthers(owner)
    for res in pairs(externalUIs) do
        if res ~= owner then return true end
    end
    return false
end


AddEventHandler('onResourceStop', function(res)
    externalUIs[res] = nil
end)

--- The inventory's own screens (inventory, container, boot or glovebox, panel, shop, another player's pockets): what the inventory key toggles and Inventory.close tears down.
---@return boolean|nil
local function inventoryScreenOpen()
    return invOpen or Inventory.activeContainerId ~= nil or Inventory.activeVehicleStorage ~= nil
        or hasActivePanel() or ActiveShopId ~= nil or activePlayerInv
end

--- A satellite's screen is open. forHud: only one that hides the HUD (not keepHud).
---@param forHud boolean|nil
---@return boolean
local function externalOpen(forHud)
    if not forHud then return next(externalUIs) ~= nil end
    for _, screens in pairs(externalUIs) do
        for _, s in pairs(screens) do
            if not s.keepHud then return true end
        end
    end
    return false
end

--- The screens: whip's own and the satellites'. A dialog or a bar is not a screen.
---@param exceptEditors boolean|nil  leave the in-world editors out (the prompts' question)
---@param forHud boolean|nil  the HUD's question: a keepHud screen is left out
---@return boolean
local function screensOpen(exceptEditors, forHud)
    return inventoryScreenOpen()
        or CreatorIsOpen or FurnishModeActive
        or (Emotes ~= nil and Emotes.isMenuOpen())
        or DirectorEditorOpen == true   -- the Director's hub and editor (client/director.lua)
        or SystemsEditorOpen == true    -- the Systems Creator's (client/systems_editor.lua)
        -- The in-world editors: their keys are read as game controls, so their number keys would also use hotbar slots.
        or (not exceptEditors
            and (ZoneEditorActive == true or DoorEditorActive == true or PropertyEditorActive == true
                 or CameraCreatorActive == true))
        or PauseMenuOpen == true        -- whip's pause menu (client/pause.lua)
        or externalOpen(forHud)
end

--- Is any UI open: whip's screens, a satellite's, or a progress bar or dialog? The guard every client module asks.
---@return boolean
function IsAnyUIOpen()
    return screensOpen() or (UI ~= nil and UI.IsBusy ~= nil and UI.IsBusy())
end

--- Is a screen up (anything that takes the player's eyes off the world)? IsAnyUIOpen minus a bare progress bar.
--- forHud: the HUD's own question; a keepHud screen (the phone) does not count.
---@param forHud boolean|nil
---@return boolean
function IsAnyScreenOpen(forHud)
    return screensOpen(nil, forHud == true)
        or (UI ~= nil and UI.IsBusy ~= nil and UI.IsBusy() and not UI.IsProgressActive())
end

exports('IsAnyUIOpen', IsAnyUIOpen)

-- Exported so an overlay resource (whip_chat) can seed from it, then follow the push below.
exports('IsAnyScreenOpen', IsAnyScreenOpen)

--- May a hotkey act on the world right now? No while any screen or bar is up, or a mode owns the keys (placing,
--- throwing, an emote's ghost). Exported for satellites' own keys.
--- `forPrompts`: the E prompts' question; their own typing mode is not counted against them.
--- `exceptBar`: a bare progress bar does not count (a dialog still does).
--- `forHotbar`: the hotbar's number keys; a mode that lets them through (BlockControls' `hotbar`) does not count.
---@param forPrompts boolean|nil
---@param exceptBar boolean|nil
---@param forHotbar boolean|nil
---@return boolean
function IsGameInputFree(forPrompts, exceptBar, forHotbar)
    local busy = UI ~= nil and UI.IsBusy ~= nil and UI.IsBusy()
        and not (exceptBar and UI.IsProgressActive ~= nil and UI.IsProgressActive())
    -- An editor with its own prompt group (Interactions.setSolo) is not a screen for the prompts' question.
    if forPrompts and Interactions ~= nil and Interactions.getSolo ~= nil and Interactions.getSolo() ~= nil then
        if screensOpen(true) or busy then return false end
    elseif screensOpen() or busy then
        return false
    end
    -- Typing an amount into a prompt (ctx.beginInput): digits are read raw, so key mappings would fire too.
    if not forPrompts and Interactions ~= nil and Interactions.inputActive ~= nil
        and Interactions.inputActive() then
        return false
    end
    if PlacingModeActive or ThrowModeActive then return false end
    -- Give mode too: the item in hand owns the keys until thrown.
    if isGiveModeActive ~= nil and isGiveModeActive() then return false end
    if Emotes ~= nil and Emotes.isPlacing ~= nil and Emotes.isPlacing() then return false end
    -- Nor while another resource's mode runs (BlockControls { mode = true }): its E is its confirm.
    if ControlBlocks ~= nil and ControlBlocks.modeHeld ~= nil and ControlBlocks.modeHeld(forHotbar) then return false end
    -- Nor while another screen holds the focus (FocusScreenUp): a key mapping still fires under KeepInput.
    if FocusScreenUp('none') then return false end
    -- Whatever holds the NUI focus, prompts close and hotkeys do nothing, so a key on a screen never lands in the world.
    if IsNuiFocused() then return false end
    return true
end

-- `forPrompts` is whip's own prompts' alone.
exports('IsGameInputFree', function() return IsGameInputFree() end)

--- Does another screen hold the NUI focus? A screen about to take it asks this, leaving itself out (`except`). Holds come from client/focus.lua with `screen = true`.
---@param except string|nil  'composer' | 'radial' | 'panel' | 'ovPanel' | 'none' (nothing left out)
---@return boolean
function FocusScreenUp(except)
    if Focus.screenUp(except) then return true end
    -- Screens open longer than their focus is held (composer, character select, creator, the Director's editor while placing): their own flags.
    if except ~= 'composer' and ComposerIsOpen ~= nil and ComposerIsOpen() then return true end
    if CharSelect ~= nil and CharSelect.IsActive ~= nil and CharSelect.IsActive() then return true end
    if CreatorIsOpen == true then return true end
    if DirectorEditorOpen == true then return true end                                    -- director.lua
    if SystemsEditorOpen == true then return true end                                     -- systems_editor.lua
    return false
end

--- May a new screen take the focus now (F1 wheel, /whip panel)? Not over another UI or focus holder.
---@param me? string  the screen asking ('radial', 'panel', 'ovPanel'), left out of the check
---@return boolean
function MayOpenScreen(me)
    if FocusScreenUp(me) then return false end
    if IsAnyUIOpen() then return false end
    return true
end

-- Push side: calling the export across resources is costly, so the answer is pushed.
--     local uiOpen = exports.whip_core:IsAnyScreenOpen()      -- once, to seed
--     AddEventHandler('whip_core:ui:stateChanged', function(e) uiOpen = e.open end)
-- It follows screens, not bars (a progress bar must not hide chat). It polls because the flags are written in many places.

local _uiWasOpen = false
local _hudWasHidden = false   -- IsAnyScreenOpen(true), the HUD's own answer

CreateThread(function()
    while true do
        -- 150ms: reads as instant against a panel's entrance animation.
        Wait(150)

        local now = IsAnyScreenOpen() and true or false
        if now ~= _uiWasOpen then
            _uiWasOpen = now
            -- Local TriggerEvent: every listener is on this client. whip_core:ui:stateChanged { open }.
            WhipEmit('whip_core:ui:stateChanged', { open = now })
        end
        -- The HUD's answer can change without the answer above changing (a screen opening over the keepHud phone).
        local hudNow = IsAnyScreenOpen(true) and true or false
        if hudNow ~= _hudWasHidden then
            _hudWasHidden = hudNow
            if WhipRefreshHudVisibility then WhipRefreshHudVisibility() end
        end
    end
end)

--- Is the open UI one whose secondary panel may be live-swapped between ground and glovebox?
--- Narrower than IsAnyUIOpen: a boot opened from outside stays a boot after the player climbs in.
---@return boolean
function Inventory.isSwappable()
    if not invOpen then return false end
    -- An open panel is no reason to refuse: the swap touches only the container/ignition panels.
    if Inventory.activeContainerId or ActiveShopId or activePlayerInv then
        return false
    end
    -- Nor a compartment an admin opened from the Vehicle Manager.
    if Inventory.activeVehicleStorage and (Inventory.activeVehicleStorage.storageType ~= 'glovebox'
                                           or Inventory.activeVehicleStorage.admin) then
        return false
    end
    return true
end


--- Hand a vehicle storage session back to the server and forget it. A missed release leaves the store "in use" until restart.
--- Takes the id explicitly so a caller that already cleared the global releases the right vehicle.
---@param vehicleId number|nil    defaults to the active session's id
---@param storageType string|nil  defaults to the active session's type
function Inventory.releaseVehicleStorage(vehicleId, storageType)
    local id   = vehicleId or (Inventory.activeVehicleStorage and Inventory.activeVehicleStorage.vehicleId)
    local kind = storageType or (Inventory.activeVehicleStorage and Inventory.activeVehicleStorage.storageType)

    Inventory.activeVehicleStorage = nil

    -- No real id means no session was held.
    if not id or id == 0 or not kind then return end

    TriggerServerEvent('whip_core:server:closeVehicleStorage', id, kind)
end

--- The item-definition table the page already holds: the last one handed to it.
local _nuiItemDefs = nil

--- The server's item list merged into this client's (Config.Items lacks runtime-registered items). Never replaces config entries.
---@param defs table|nil
local function adoptServerItemDefs(defs)
    if type(defs) ~= 'table' then return end
    for key, def in pairs(defs) do
        local have = Config.Items[key]
        if type(def) == 'table' and (have == nil or have._fromServer) then
            def._fromServer = true
            Config.Items[key] = def
        end
    end
end

--- `data` as the page should receive it: without `itemDefs` when the page already holds that exact set (resending causes an icon flicker).
--- Compared by identity; a copy is made because `data` is usually the cached payload.
---@param data any
---@return any
function Inventory.withoutHeldItemDefs(data)
    local defs = type(data) == 'table' and data.itemDefs or nil
    if defs == nil then return data end
    if defs ~= _nuiItemDefs then
        _nuiItemDefs = defs
        adoptServerItemDefs(defs)
        return data
    end
    local copy = {}
    for k, v in pairs(data) do
        if k ~= 'itemDefs' then copy[k] = v end
    end
    return copy
end

-- Which right-click options the player may use: an item option's `require` (job, onDuty, item...) is worked out here
-- (Actions.requirementsMet) while a screen is open, every GATE_MS, and sent when an answer changes: ['<item>|<action>'] = true.
-- The server asks again before an option runs.

local GATE_MS = 500
local gateLoopRunning = false
local lastGates = nil
local gated, gatedFor = {}, nil   -- the options that have a require, and the defs they came from

--- The answers for every option with a require, in the definitions the page holds.
local function workOutGates()
    local defs = _nuiItemDefs
    if defs ~= gatedFor then
        gatedFor, gated = defs, {}
        for key, def in pairs(type(defs) == 'table' and defs or {}) do
            if type(def) == 'table' and type(def.contextOptions) == 'table' then
                for _, opt in ipairs(def.contextOptions) do
                    if type(opt) == 'table' and opt.require ~= nil then
                        gated[#gated + 1] = { key = key .. '|' .. tostring(opt.action), require = opt.require }
                    end
                end
            end
        end
    end
    local gates = {}
    for _, g in ipairs(gated) do
        if Actions.requirementsMet(g.require) == true then gates[g.key] = true end
    end
    return gates
end

local function sameGates(a, b)
    if a == nil or b == nil then return false end
    for k in pairs(a) do if not b[k] then return false end end
    for k in pairs(b) do if not a[k] then return false end end
    return true
end

--- While a screen is open: the answers, sent when they change. Waits last, so a close ends it at once.
local function startGateLoop()
    if gateLoopRunning then return end
    gateLoopRunning = true
    CreateThread(function()
        while invOpen do
            local gates = workOutGates()
            if not sameGates(gates, lastGates) then
                lastGates = gates
                SendNUIMessage({ action = 'itemOptionGates', gates = gates })
            end
            Wait(GATE_MS)
        end
        gateLoopRunning = false
    end)
end

--- A car's maker, for an item picture with {make} in its path: the page sends models, the game names their makers ('pegassi', '' for none).
RegisterNUICallback('itemVehicleMakes', function(data, cb)
    local out = {}
    local models = type(data) == 'table' and data.models
    if type(models) == 'table' then
        for i, model in ipairs(models) do
            if i > 100 then break end
            if type(model) == 'string' and model ~= '' and #model <= 40 then
                local ok, make = pcall(GetMakeNameFromVehicleModel, GetHashKey(model))
                out[model] = (ok and type(make) == 'string' and make ~= '' and make ~= 'CARNOTFOUND')
                    and make:lower() or ''
            end
        end
    end
    cb({ makes = out })
end)

--- Items are locked while the server cannot reach its database: an open screen closes and none opens until it is back.
local itemsLocked = false
local lockedToastAt = 0
local LOCKED_MSG = "Your items are locked: the server can't save right now. Try again in a moment."

RegisterNetEvent('whip_core:client:dbHealth', function(up)
    itemsLocked = up == false
    if itemsLocked then
        if inventoryScreenOpen() then Inventory.close() end
        lockedToastAt = GetGameTimer()
        UI.Notify(LOCKED_MSG, 'error', 8000)
    else
        UI.Notify('Your items are unlocked.', 'success')
    end
end)

--- Open the inventory UI with a NUI action + data, setting context. False if any UI is open (caller aborts) or items are locked.
---@param action string   NUI action name
---@param data table      NUI payload
---@param context table|nil  { containerId, vehicleStorage, externalPanel, shopId, playerInv }
---@return boolean opened  true if UI was opened, false if blocked
function Inventory.openUI(action, data, context)
    if itemsLocked then
        -- Once per few seconds: a remembered panel and the server's answer both arrive here.
        if GetGameTimer() - lockedToastAt > 3000 then
            lockedToastAt = GetGameTimer()
            UI.Notify(LOCKED_MSG, 'error')
        end
        return false
    end
    if IsAnyUIOpen() then return false end

    invOpen = true
    if data and data.inventory then _cachedInventory = data.inventory end
    if data then UpdateItemFlags(data) end
    TriggerScreenblurFadeIn(200)
    Focus.take('inventory')

    -- A panel in the context means the panel brought this screen up (see panelDrivenOpen).
    panelDrivenOpen = not not (context and context.externalPanel)

    if context then
        if context.containerId then Inventory.activeContainerId = context.containerId end
        if context.vehicleStorage then Inventory.activeVehicleStorage = context.vehicleStorage end
        if context.store then activeStore = context.store end   -- OpenStore, a resource's own kind
        if context.externalPanel then trackPanel(context.externalPanel) end
        if context.shopId then ActiveShopId = context.shopId end
        if context.playerInv then activePlayerInv = true end
    end

    SendNUIMessage({ action = action, data = Inventory.withoutHeldItemDefs(data) })
    startGateLoop()   -- which options with a `require` the player meets, while it is open
    -- The preview path waits so it needs a thread; the preview-off path runs now so a close in this frame cannot land before it.
    if not MENU_PED_ENABLED then
        showMenuPed()
    else
        Citizen.CreateThread(showMenuPed)
    end

    return true
end

-- Optimistic open: the last confirmed payload of each panel is replayed at once on the next open, and the server's
-- answer folds in behind it. A stale grid is safe: a move sends addresses only and the server reads its own state;
-- a rejection echoes opId so the NUI rolls back that drag. OpenPanel goes through the same handler.

local optimisticMemory = {}    -- [key] = the last confirmed payload for that panel
local optimisticContext = {}   -- [key] = what that payload was confirmed as (which boot, stash or store)
local optimisticOrder  = {}    -- insertion order, for eviction
local OPTIMISTIC_MAX   = 32

--- What each trigger opened, learned from the payload that comes back; the next press draws it early.
--- A trigger that opens a different panel each time is marked `false` and never predicted again.
local triggerPanels = {}   -- [triggerId] = { key, open } | false
local lastTrigger   = { id = nil, at = 0 }

--- How long after a trigger a panel can arrive and still count as its doing.
local TRIGGER_WINDOW_MS = 4000

--- Forward declaration (Inventory.confirmPanel is defined above).
local learnTrigger

--- Key of the panel last drawn on spec. Not cleared on close, so an in-flight reply can tell a dismissal from a server-pushed panel.
--- It can go stale; read it through drawnKey.
local optimisticKey = nil

--- When that panel was drawn. See drawnKey.
local optimisticAt = 0

--- Key the player is waiting to see, for client-initiated opens only. Cleared by Inventory.close (a dismissal cancels the open in flight). Nil for server-pushed panels.
local panelWanted = nil

--- When that intent was recorded. See wantedKey.
local panelWantedAt = 0

--- How long an unanswered intent is believed. A stale one makes Inventory.confirmPanel refuse every other panel; this is the backstop (request timeouts are 5s).
local PANEL_WANT_TTL_MS = 10000

--- The intent, if still believable. Read this, never `panelWanted` directly: it expires on read.
---@return string|nil
local function wantedKey()
    if panelWanted == nil then return nil end
    if GetGameTimer() - panelWantedAt > PANEL_WANT_TTL_MS then
        panelWanted = nil
        return nil
    end
    return panelWanted
end

--- The panel drawn on spec, if still current. A draw whose request died leaves it set; a new ask with nothing on screen retires it.
---@return string|nil
local function drawnKey()
    if optimisticKey == nil then return nil end
    if GetGameTimer() - optimisticAt > PANEL_WANT_TTL_MS then
        optimisticKey = nil
        return nil
    end
    return optimisticKey
end

--- Refresh the player's own parts of a remembered payload (pockets have a live cache; an old copy would show spent items).
local function withCurrentPlayerHalf(payload)
    local fresh = {}
    for k, v in pairs(payload) do fresh[k] = v end

    if _lastOpenPayload then
        fresh.inventory = _lastOpenPayload.inventory or fresh.inventory
        fresh.weights   = _lastOpenPayload.weights   or fresh.weights
        fresh.maxSlots  = _lastOpenPayload.maxSlots  or fresh.maxSlots
        fresh.maxWeight = _lastOpenPayload.maxWeight or fresh.maxWeight
    end
    return fresh
end

--- Draw a remembered panel before asking the server. True if something is on screen.
--- `spec.key` identifies the thing opened ('vehicle:8:trunk', 'container:42'): unique per thing, stable per thing.
---@param spec table  { key, open, context? }
---@return boolean drawn
function Inventory.drawRememberedPanel(spec)
    if not spec or not spec.key then return false end

    -- Intent is recorded even with nothing to draw, so a close can cancel a first-ever open. Stamped so it expires.
    panelWanted   = spec.key
    panelWantedAt = GetGameTimer()

    if IsAnyUIOpen() then return false end

    -- Nothing is on screen: retire the old drawn record before it refuses this reply.
    optimisticKey = nil

    local remembered = optimisticMemory[spec.key]
    if not remembered then return false end   -- never opened this one; wait for the server

    if not Inventory.openUI(spec.open, withCurrentPlayerHalf(remembered), spec.context) then
        return false
    end

    optimisticKey = spec.key
    optimisticAt  = GetGameTimer()
    return true
end

--- The server's confirmed payload arrived: fold it into the panel drawn on spec, or cold-open.
--- False only when the caller still owes the server a release; a second value says why (silent on screen).
---@param spec table  { key, open, sync, context? }
---@param payload table  the server's own payload; remembered verbatim
---@return boolean shown
---@return string|nil why  when not shown
function Inventory.confirmPanel(spec, payload)
    if not spec or not payload then return false, 'no spec or no payload' end

    -- No key: no stable identity, so no instant second open.
    if not spec.key then
        if Inventory.openUI(spec.open, payload, spec.context) then return true end
        return false, 'another screen is already open (IsAnyUIOpen)'
    end

    -- Remembered before display can fail: it is real server state either way.
    if not optimisticMemory[spec.key] then
        optimisticOrder[#optimisticOrder + 1] = spec.key
        if #optimisticOrder > OPTIMISTIC_MAX then
            local evicted = table.remove(optimisticOrder, 1)
            optimisticMemory[evicted] = nil
            optimisticContext[evicted] = nil
        end
    end
    optimisticMemory[spec.key] = payload
    optimisticContext[spec.key] = spec.context

    -- Tie this panel to its trigger so the next press can draw it before the server is asked.
    learnTrigger(spec)

    -- A learned prediction can be for the wrong instance (the last boot): the reconcile below repairs anything drawn on spec.
    -- drawnKey(), not optimisticKey: a draw whose request died does not count.
    local drewSomething = (drawnKey() ~= nil)
    optimisticKey = nil

    -- The player is no longer waiting: do not show it, and tell the caller to release the session. Two cases:
    --   * they asked for something else since (panelWanted names another panel);
    --   * they asked for this, then closed (panelWanted cleared, but something was drawn for it).
    -- panelWanted nil with nothing drawn is a server-pushed panel, not a cancellation.
    -- wantedKey(), not panelWanted: an expired intent is a leak, not a cancellation.
    local wanted = wantedKey()
    if wanted ~= nil and wanted ~= spec.key then
        return false, ('the player is waiting for %s, not %s'):format(wanted, spec.key)
    end
    if wanted == nil and drewSomething then
        return false, 'the player closed it before the reply arrived'
    end
    panelWanted = nil

    -- Nothing drawn on spec: ordinary cold open.
    if not drewSomething then
        if Inventory.openUI(spec.open, payload, spec.context) then return true end
        return false, 'another screen is already open (IsAnyUIOpen)'
    end

    -- Drawn on spec but gone now: the server counted us as a viewer, so the caller owes it a release.
    -- (The inventory's own screens, not IsAnyUIOpen: a dialog on screen does not mean the panel still is.)
    if not inventoryScreenOpen() then
        return false, 'something was drawn for it, but nothing is on screen now'
    end

    -- Drawn on spec and still up: fold the payload in (openUI would refuse and the caller would close the panel).
    if spec.context then
        if spec.context.containerId then Inventory.activeContainerId = spec.context.containerId end
        if spec.context.vehicleStorage then Inventory.activeVehicleStorage = spec.context.vehicleStorage end
        if spec.context.store then activeStore = spec.context.store end
        if spec.context.externalPanel then trackPanel(spec.context.externalPanel) end
    end

    -- Some repaint actions take the whole payload, others one field; `syncField` says which.
    local syncData = spec.syncField and payload[spec.syncField] or payload

    -- `noFlash`: nothing swapped. The panel did not change identity, it finished loading.
    if type(syncData) == 'table' then syncData.noFlash = true end
    SendNUIMessage({ action = spec.sync, data = Inventory.withoutHeldItemDefs(syncData) })
    return true
end

--- A whip-owned trigger fired: draw whatever it opened last time. Called just before the satellite's callback runs.
---@param triggerId string|nil
function Inventory.notePanelTrigger(triggerId)
    if not triggerId then return end

    lastTrigger.id = triggerId
    lastTrigger.at = GetGameTimer()

    local learned = triggerPanels[triggerId]
    if not learned then return end   -- never seen, or poisoned

    Inventory.drawRememberedPanel({ key = learned.key, open = learned.open })
end

--- Record what the trigger that just ran opened.
---@param spec table
function learnTrigger(spec)
    local id = lastTrigger.id
    if not id or not spec.key or spec.noLearn then return end
    if GetGameTimer() - lastTrigger.at > TRIGGER_WINDOW_MS then return end

    local learned = triggerPanels[id]

    -- Already known not to be one-to-one.
    if learned == false then return end

    -- A different answer than last time: stop guessing.
    if learned and learned.key ~= spec.key then
        triggerPanels[id] = false
        return
    end

    triggerPanels[id] = { key = spec.key, open = spec.open }
end

--- The player is no longer waiting for a panel (Inventory.close). Clears the intent, not the record of what was drawn.
function Inventory.cancelPanelOpen()
    panelWanted = nil
end

--- Is a panel drawn that the server has not confirmed? Refusal handlers use this.
---@return boolean
function Inventory.hasOptimisticPanel()
    return drawnKey() ~= nil
end

--- Update part of a remembered payload so a reopen shows what happened while it was open.
---@param key string|nil
---@param patch table  field names to overwrite in the remembered payload
function Inventory.patchRememberedPanel(key, patch)
    local remembered = key and optimisticMemory[key]
    if not remembered or type(patch) ~= 'table' then return end

    for field, value in pairs(patch) do
        if value ~= nil then remembered[field] = value end
    end
end

--- The same, from a delta: the changed slots of a remembered stash or boot, and its weight. Keys are the server's store ids ('container:<id>', 'vehicle:<id>:<type>').
---@param key string   the store id
---@param slots table  { ['<slot>'] = { item, amount, metadata } or false }
---@param weight number|nil
local function patchRememberedSlots(key, slots, weight)
    local remembered = key and optimisticMemory[key]
    if not remembered or type(slots) ~= 'table' or type(remembered.containerInv) ~= 'table' then return end

    for slot, v in pairs(slots) do
        remembered.containerInv[tostring(slot)] = v or nil
    end
    if type(weight) == 'number' then remembered.containerWeight = weight end
end

-- No satellite-facing API: every panel opened from a whip-owned trigger is remembered automatically.

--- Close inventory (and any container/vehicle storage/external panel).
--- Safe to call even when inventory is not open (no-ops).
function Inventory.close()
    -- Two jobs with separate guards: (1) tear down the local UI, only if it is up; (2) release the server-side
    -- session, whenever one is held (the server locks a container before the client decides to display it).
    -- Cancel any open still in flight: its reply would reopen what was just dismissed.
    inventoryOpenRequested = false

    -- The same for every other panel (stash, boot, glovebox, a satellite's).
    Inventory.cancelPanelOpen()

    -- The inventory's own screens, not IsAnyUIOpen: other screens are not this one's to tear down.
    if inventoryScreenOpen() then
        invOpen = false
        -- Defensive: cleared so a path that sets invOpen without openUI cannot leave a panel owning the screen.
        panelDrivenOpen = false
        hideMenuPed()
        TriggerScreenblurFadeOut(200)
        Focus.release('inventory')
        SendNUIMessage({ action = 'closeInventory' })
        -- Activity log's close marker, inside the UI-was-up guard (no phantom close on a bare release).
        TriggerServerEvent('whip_core:server:inventoryClosed')
    end

    if Inventory.activeContainerId then
        TriggerServerEvent('whip_core:server:closeContainer', Inventory.activeContainerId)
        Inventory.activeContainerId = nil
    end
    if activeStore then
        TriggerServerEvent('whip_core:server:closeStore', activeStore.storeId)
        activeStore = nil
    end
    Inventory.releaseVehicleStorage()
    -- Every panel this player has open (closePanelSession with no id).
    releasePanels()
    if ActiveShopId then
        TriggerServerEvent('whip_core:server:closeShop')
        ActiveShopId = nil
    end
    if activePlayerInv then
        TriggerServerEvent('whip_core:server:closePlayerInventory')
        activePlayerInv = false
    end
end

-- Give mode state
local giveMode       = false

--- Is give mode on (the item in hand, before it is thrown)? For IsGameInputFree.
---@return boolean
function isGiveModeActive() return giveMode end
Inventory.isGiveModeActive = isGiveModeActive   -- (client/ped_hold.lua: the function above is this file's own local)
local giveContainer  = nil
local giveSlot       = nil
local giveItemName   = ''
local giveItemAmount = 0
local giveStartTime  = 0
local giveItemKey    = ''
local GIVE_TIMEOUT   = 30000  -- 30 seconds
local GIVE_MAX_DIST  = 8.0    -- metres

-- Throw-mode state: global, read by emotes and IsGameInputFree. A throw ends give mode as it leaves the hand.
ThrowModeActive        = false
local throwArmed       = false   -- true once we confirm ped has ammo (prevents false positive on equip)
local giveProp         = nil     -- the model (hash) of the held prop give mode asked the server for, or nil
local giveHand         = nil     -- the hand it asked for it in ('left' | 'right'): giveHandNow's answer then
local giveSeenHand     = nil     -- the hand the game was seen holding the ball in while aiming in this seat
local giveSide         = nil     -- throwHand's answer when giveSeenHand was seen: another seat forgets it
local giveSteady       = nil     -- aiming in a vehicle: the hand the ball is in now, and since when (giveSteadyAt)
local giveSteadyAt     = 0
local giveSeq          = 0       -- counts give modes started: a give's late cleanup is for its own only

local THROW_MAX_TRACK_TIME = 10000  -- 10 seconds max to track thrown prop
local STILL_THRESHOLD      = 0.04   -- velocity magnitude threshold for "stopped"
local STILL_FRAMES_REQ     = 8      -- consecutive still frames before declaring landed

-- Cached hashes (avoid GetHashKey every frame)
local WEAPON_BALL_HASH = nil  -- set on first use

-- Give-mode raycast cache (throttled to every ~200ms instead of every frame)
local giveRayTarget     = nil   -- { serverId, name } or nil
local giveRayLastCheck  = 0

RegisterKeyMapping('inventory', 'Open Inventory', 'keyboard', 'F2')


--- What the inventory key does, from either device (the pad's is below the command).
local function inventoryKey()
    -- A server replacing the inventory UI turns whip's off here. The keybind stays registered (a custom key would be stranded).
    -- Stores, weight, persistence and storeMove are untouched: it disables the screen, not the system.
    if Config.EnableInventoryUI == false then return end
    if PlayerIsDead then return end
    if giveMode then return end  -- block inventory while giving
    if PlacingModeActive then return end  -- and while a placement ghost is up
    if Emotes ~= nil and Emotes.isPlacing and Emotes.isPlacing() then return end  -- an emote's ghost too
    -- A progress bar or dialog is up: the key does nothing.
    if UI and UI.IsBusy and UI.IsBusy() then return end
    -- The key toggles its own screen only; under another screen it does nothing.
    if inventoryScreenOpen() then
        Inventory.close()
    elseif IsAnyUIOpen() then
        return
    else
        -- In a vehicle with a known vehicleId: glovebox instead of ground.
        local ped = PlayerPedId()
        if IsPedInAnyVehicle(ped, false) and Vehicles and Vehicles.tryOpenGlovebox() then
            return  -- glovebox handled
        end

        -- Render at once from the cache (refreshed at login and every change; ground from local proximity), then reconcile; the server's reply wins.
        -- No cached payload (first open since joining) waits for the server.
        inventoryOpenRequested = true
        if _lastOpenPayload then
            Inventory.openUI('openInventory', _lastOpenPayload, nil)
        end

        -- Tell the server whether it must include the item definitions.
        TriggerServerEvent('whip_core:server:openInventory', _haveItemDefs)
    end
end

RegisterCommand('inventory', inventoryKey, false)

-- F1 wheel entry: the same as F2. Hidden when a server turns whip's inventory screen off. Re-adding the same id replaces it.
AddEventHandler('whip_core:onReady', function()
    Actions.add(GetCurrentResourceName(), {
        id          = 'inventory',
        at          = { radial = true },
        label       = 'Inventory',
        icon        = 'bag',
        description = 'Your pockets and bag',
        canInteract = function() return Config.EnableInventoryUI ~= false end,
        onSelect    = function() inventoryKey() end,
    })
end)

-- D-pad right on a pad, run by client/pad.lua's reader. Its own command: inside a panel D-pad right is the panel's "right". A pad closes with B.
RegisterCommand('whip_inventory_pad', function()
    if WhipPadDebugFire then WhipPadDebugFire('bind', 'inventory', WhipNavScopeOpen and 'ignored: a panel is open' or nil) end
    if WhipNavScopeOpen then return end
    inventoryKey()
end, false)

--- Server sends back full inventory data -> open UI, or reconcile one already open
RegisterNetEvent('whip_core:client:openInventory', function(data)
    if not data then return end

    -- The server lists every pile in reach; the Nearby panel shows only those in sight.
    if data.groundItems and GroundSlotsInSight then data.groundItems = GroundSlotsInSight(data.groundItems) end

    -- Item definitions arrive once per session; carry the last set forward so the cached payload stays self-contained.
    if data.itemDefs then
        _haveItemDefs = true
    elseif _lastOpenPayload then
        data.itemDefs = _lastOpenPayload.itemDefs
    end

    -- Always keep the payload: it makes the next open instant.
    _lastOpenPayload = data
    _cachedInventory = data.inventory or _cachedInventory

    -- The player closed (or never asked) meanwhile: cache and stop.
    if not inventoryOpenRequested then return end

    if invOpen then
        -- Already opened from cache: openUI would refuse, so fold the authoritative copy in as an update.
        -- The ground panel must come from here (proximity-dependent). Unsolicited, and only what updateInventory reads:
        -- it is not the reply to a drag.
        UpdateItemFlags(data)
        SendNUIMessage({ action = 'inventoryUpdate', data = {
            inventory   = data.inventory,
            weights     = data.weights,
            unsolicited = true,
        } })
        SendNUIMessage({ action = 'groundItemsRefresh', data = data.groundItems or {} })
        return
    end

    -- First open since joining: this reply opens the UI.
    inventoryOpenRequested = false
    Inventory.openUI('openInventory', data, nil)
end)

--- Server sends updated inventory (after move/use/give)
RegisterNetEvent('whip_core:client:inventoryUpdate', function(data)
    if not data then
        return
    end
    if data.inventory then _cachedInventory = data.inventory end
    UpdateItemFlags(data)

    -- Keep the instant-open payload current (inventory and weights are the only fields that change).
    if _lastOpenPayload then
        _lastOpenPayload.inventory = data.inventory or _lastOpenPayload.inventory
        _lastOpenPayload.weights   = data.weights   or _lastOpenPayload.weights
    end

    SendNUIMessage({
        action = 'inventoryUpdate',
        data   = data,
    })
end)

-- The weight limits changed in /whip → Settings: the replayed copy takes the new Config.MaxWeight.
Settings.onChange('MaxWeight', function()
    if _lastOpenPayload then _lastOpenPayload.maxWeight = Settings.copy(Config.MaxWeight) end
end)

--- Some slots of a store this player is looking at changed. A delta, not a resync (a resync would destroy an in-flight drag): `false` is now empty, an unmentioned slot is unchanged.
RegisterNetEvent('whip_core:client:storeDelta', function(data)
    if not data or not data.storeId then return end
    -- The remembered copy too.
    patchRememberedSlots(data.storeId, data.slots, data.weight)
    SendNUIMessage({
        action = 'storeDelta',
        data   = data,
    })
end)

--- Server rejected a move: revert the UI. opId is nil for handlers without one; the NUI then unwinds its oldest pending operation.
RegisterNetEvent('whip_core:client:inventoryRevert', function(err, opId)
    SendNUIMessage({
        action = 'inventoryRevert',
        error  = err,
        opId   = (opId and opId > 0) and opId or nil,
    })
end)

--- The server accepted a drag whose answer is not an inventory push (stash to stash, a panel another resource handled): it names the op.
RegisterNetEvent('whip_core:client:moveAck', function(opId)
    if not opId or opId <= 0 then return end
    SendNUIMessage({ action = 'moveAck', opId = opId })
end)

RegisterNUICallback('closeInventory', function(_, cb)
    Inventory.close()
    cb('ok')
end)

--- Turn a UI slot reference into a store address for whip_core:server:storeMove.
--- The NUI calls both a world stash and a vehicle's trunk or glovebox "container"; the address names which, and the server checks it against its open lock.
---@param container string  'player' | 'accessory' | 'container'
---@param slot number|nil
---@param containerId number|nil  the open stash, when container == 'container'
---@return table
function Inventory.storeAddr(container, slot, containerId)
    if container ~= 'container' then
        return { kind = container, slot = slot }
    end
    if Inventory.activeVehicleStorage then
        return {
            kind = 'vehicle',
            id   = Inventory.activeVehicleStorage.vehicleId,
            sub  = Inventory.activeVehicleStorage.storageType,
            slot = slot,
        }
    end
    -- A resource's own store kind (OpenStore): the right-hand grid answers to its address.
    if activeStore then
        return { kind = activeStore.kind, id = activeStore.id, sub = activeStore.sub, slot = slot }
    end
    if containerId or Inventory.activeContainerId then
        return { kind = 'container', id = containerId or Inventory.activeContainerId, slot = slot }
    end
    -- Drawn from memory: the grid answers to what this panel was confirmed as last time.
    local key = drawnKey()
    local early = key and optimisticContext[key]
    if early and early.vehicleStorage then
        return { kind = 'vehicle', id = early.vehicleStorage.vehicleId, sub = early.vehicleStorage.storageType, slot = slot }
    end
    if early and early.store then
        return { kind = early.store.kind, id = early.store.id, sub = early.store.sub, slot = slot }
    end
    return { kind = 'container', id = early and early.containerId, slot = slot }
end

--- NUI requests a move (drag-drop)
RegisterNUICallback('moveItem', function(data, cb)
    TriggerServerEvent('whip_core:server:storeMove',
        Inventory.storeAddr(data.fromContainer, data.fromSlot),
        Inventory.storeAddr(data.toContainer, data.toSlot),
        0, 'move', data.opId or 0
    )
    cb('ok')
end)

--- NUI requests drop-one-item (right-click during drag)
RegisterNUICallback('dropOneItem', function(data, cb)
    TriggerServerEvent('whip_core:server:storeMove',
        Inventory.storeAddr(data.fromContainer, data.fromSlot),
        Inventory.storeAddr(data.toContainer, data.toSlot),
        0, 'one', data.opId or 0
    )
    cb('ok')
end)

--- NUI requests item use (context menu)
RegisterNUICallback('useItem', function(data, cb)
    TriggerServerEvent('whip_core:server:useItemFromMenu',
        data.container, data.slot
    )
    cb('ok')
end)

--- NUI requests custom context action (from external resources)
RegisterNUICallback('customContextAction', function(data, cb)
    TriggerServerEvent('whip_core:server:customContextAction',
        data.action, data.container, data.slot
    )
    cb('ok')
end)

--- An address for any grid the NUI draws, panels included. A panel slot's gesture sends its panel id as `panelId`; the rest is Inventory.storeAddr's.
---@param container string
---@param slot number|nil  nil for a whole store (quickMove's destination)
---@param containerId number|nil
---@param panelId any|nil
---@return table
local function nuiStoreAddr(container, slot, containerId, panelId)
    if panelId ~= nil then return { kind = 'panel', id = panelId, slot = slot } end
    return Inventory.storeAddr(container, slot, containerId)
end
Inventory.nuiStoreAddr = nuiStoreAddr

--- NUI: an item's `anywhere` option, chosen on a slot that is not in the pockets (a boot, a stash, a bag).
RegisterNUICallback('storeContextAction', function(data, cb)
    TriggerServerEvent('whip_core:server:storeContextAction',
        data.action, nuiStoreAddr(data.container, data.slot, data.containerId, data.panelId)
    )
    cb('ok')
end)

--- NUI requests item destroy (context menu) — from the pockets or anything open on the right.
--- Optimistic: opId is the op the NUI opened when it took the item off the screen.
RegisterNUICallback('destroyItem', function(data, cb)
    TriggerServerEvent('whip_core:server:destroyItem',
        nuiStoreAddr(data.container, data.slot, data.containerId, data.panelId),
        data.opId or 0
    )
    cb('ok')
end)

--- NUI requests item split (context menu "Split")
RegisterNUICallback('splitItem', function(data, cb)
    -- One address, no destination: the framework picks the slot.
    TriggerServerEvent('whip_core:server:splitItem',
        nuiStoreAddr(data.container, data.slot, data.containerId, data.panelId),
        data.splitAmount,
        data.opId or 0
    )
    cb('ok')
end)

--- NUI shift-click: the whole stack to wherever it fits in one other store (no slot; the server picks).
RegisterNUICallback('quickMove', function(data, cb)
    TriggerServerEvent('whip_core:server:quickMove',
        nuiStoreAddr(data.fromContainer, data.fromSlot, data.containerId, data.fromPanelId),
        nuiStoreAddr(data.toContainer, nil, data.containerId, data.toPanelId),
        data.opId or 0
    )
    cb('ok')
end)

-- Player inventory: an admin viewing another player's inventory

activePlayerInv = false  -- true when admin is viewing another player's inventory

RegisterNetEvent('whip_core:client:openPlayerInventory', function(data)
    if not data then return end
    -- A declined open still owes a release: the server locked the target's inventory.
    if not Inventory.openUI('openInventoryWithPlayer', data, { playerInv = true }) then
        TriggerServerEvent('whip_core:server:closePlayerInventory')
    end
end)

RegisterNetEvent('whip_core:client:closePlayerInventory', function()
    SendNUIMessage({ action = 'closePlayerInventory' })
end)

RegisterNetEvent('whip_core:client:playerInvUpdate', function(data)
    SendNUIMessage({
        action = 'playerInvUpdate',
        data = data,
    })
end)

--- Address one side of an admin inspect drag. The target's charId is not sent: the server takes it from the inspect session.
---@param side string
---@param slot number
---@return table
local function inspectAddr(side, slot)
    if side == 'targetPlayer'   then return { kind = 'target', sub = 'player',   slot = slot } end
    return { kind = side, slot = slot }
end

RegisterNUICallback('playerInvMoveItem', function(data, cb)
    TriggerServerEvent('whip_core:server:storeMove',
        inspectAddr(data.fromType, data.fromSlot),
        inspectAddr(data.toType, data.toSlot),
        0, 'move', data.opId or 0)
    cb('ok')
end)

RegisterNUICallback('playerInvDropOneItem', function(data, cb)
    TriggerServerEvent('whip_core:server:storeMove',
        inspectAddr(data.fromType, data.fromSlot),
        inspectAddr(data.toType, data.toSlot),
        0, 'one', data.opId or 0)
    cb('ok')
end)

RegisterNUICallback('closePlayerInventory', function(_, cb)
    Inventory.close()
    cb('ok')
end)

-- External panel: a generic N-slot panel for other resources

-- Combined panel open (inventory + panel in one shot). If the inventory is already open, the panel overlays it.
RegisterNetEvent('whip_core:client:openPanel', function(data)
    if not data or not data.panel then return end

    if invOpen then
        -- Overlay: the panel joins the stack.
        trackPanel(data.panel)
        SendNUIMessage({ action = 'openExternalPanel', data = data.panel })
    else
        -- Full open: inventory + panel together. Server-pushed, so nothing is drawn on spec, but confirmPanel remembers the payload by the config's `id`.
        -- A declined open still owes a release: the owning resource waits on its onClose callback.
        if not Inventory.confirmPanel({
            key       = data.panel.id and ('panel:' .. tostring(data.panel.id)) or nil,
            open      = 'openInventoryWithPanel',
            sync      = 'openExternalPanel',
            syncField = 'panel',   -- openExternalPanel takes the panel, not the whole payload
            context   = { externalPanel = data.panel },
        }, data) then
            TriggerServerEvent('whip_core:server:closePanelSession', tostring(data.panel.id))
        end
    end
end)

--- The server closed one panel (`panelId` nil means all).
RegisterNetEvent('whip_core:client:closeExternalPanel', function(panelId)
    -- A panel opens as an overlay or as a full open; closing undoes whichever happened (a stale `invOpen` would refuse every later open).
    if panelId ~= nil then
        activePanels[panelId] = nil
    else
        activePanels = {}
    end

    SendNUIMessage({ action = 'closeExternalPanel', data = { id = panelId } })

    -- Needs all three: invOpen (a screen to close), panelDrivenOpen (a panel opened it; the player's own inventory outlives its panels), not hasActivePanel (all panels gone).
    if invOpen and panelDrivenOpen and not hasActivePanel() then
        Inventory.close()
    end
end)

RegisterNetEvent('whip_core:client:panelWeightInfo', function(data)
    SendNUIMessage({ action = 'panelWeightInfo', data = data })
end)

--- `panelId` says which panel went read-only (nil: the only open one).
RegisterNetEvent('whip_core:client:panelReadOnly', function(readOnly, panelId)
    SendNUIMessage({ action = 'panelReadOnly', data = { readOnly = readOnly, panelId = panelId } })
end)

RegisterNetEvent('whip_core:client:updateExternalPanelSlot', function(slot, data, panelId)
    SendNUIMessage({
        panelId  = panelId,
        action   = 'updateExternalPanelSlot',
        slot     = slot,
        slotData = data,
    })
end)

RegisterNUICallback('externalPanelMove', function(data, cb)
    -- An ordinary storeMove: the panel kind's beforeMove asks the panel's rules and onValidate(ctx) first. `id` is a parameter (panelToPanel names two panels).
    local function panelAddr(id, slot)
        return { kind = 'panel', id = id, slot = slot }
    end

    local from, to
    if data.direction == 'toPanel' then
        from = Inventory.storeAddr(data.invContainer, data.invSlot, data.containerId)
        to   = panelAddr(data.panelId, data.panelSlot)
    elseif data.direction == 'fromPanel' then
        from = panelAddr(data.panelId, data.panelSlot)
        to   = Inventory.storeAddr(data.invContainer, data.invSlot, data.containerId)
    elseif data.direction == 'withinPanel' then
        from = panelAddr(data.panelId, data.panelSlot)
        to   = panelAddr(data.panelId, data.toPanelSlot)
    elseif data.direction == 'panelToPanel' then
        -- One panel into another (a wallet into a duffle bag): two ordinary 'panel' addresses.
        from = panelAddr(data.panelId, data.panelSlot)
        to   = panelAddr(data.toPanelId, data.toPanelSlot)
    else
        cb('ok')
        return
    end

    -- `mode = 'one'` is the right-click drop-one; every other panel drag moves the stack.
    TriggerServerEvent('whip_core:server:storeMove',
        from, to, data.amount or 0, data.mode == 'one' and 'one' or 'move', data.opId or 0)
    cb('ok')
end)

-- Give mode: right-click Give, raycast to a player, E confirms, C cancels

--- Reported once per item, not per use.
local propWarned = {}

--- Which prop model stands for this item, dropped in the world or offered in the hand.
--- A model missing from this client's archives (IsModelInCdimage) would time out, so it falls back to Config.DefaultGroundProp.
---@param itemKey string
---@return string
function Inventory.itemPropModel(itemKey)
    local def = Config.Items[itemKey]
    local want = def and def.prop or nil

    if want then
        if IsModelInCdimage(GetHashKey(want)) then return want end

        if not propWarned[itemKey] then
            propWarned[itemKey] = true
            print(('[whip_core:items] item "%s" wants prop "%s", which does not exist in this '
                .. 'build — falling back to %s.')
                :format(tostring(itemKey), tostring(want), tostring(Config.DefaultGroundProp)))
        end
    end

    return Config.DefaultGroundProp
end

--- The offered item in the hand is a server-made held prop (like an emote's bottle), shown a moment after give mode starts.
--- This game picks the model (Inventory.itemPropModel) and requests it so a throw finds it loaded.
--- The hand GTA throws with: the right on foot; in a vehicle the one at its window (the side the seat is on).
---@return 'left'|'right'
local function throwHand()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 then return 'right' end
    local pos = GetEntityCoords(ped)
    return GetOffsetFromEntityGivenWorldCoords(veh, pos.x, pos.y, pos.z).x < 0.0 and 'left' or 'right'
end

--- Which hand holds give mode's ball (the nearer hand bone), or nil. In a car GTA throws with the hand on the side it aims at, not the seat's, so it is watched while aiming.
local BALL_IN_HAND_M = 0.35   -- further than this from both hands, the ball is in neither
local function ballHand(ped)
    local ball = GetCurrentPedWeaponEntityIndex(ped)
    if not ball or ball == 0 or not DoesEntityExist(ball) then return nil end
    local at = GetEntityCoords(ball)
    local dr = #(at - GetPedBoneCoords(ped, 57005, 0.0, 0.0, 0.0))   -- SKEL_R_Hand
    local dl = #(at - GetPedBoneCoords(ped, 18905, 0.0, 0.0, 0.0))   -- SKEL_L_Hand
    if math.min(dr, dl) > BALL_IN_HAND_M then return nil end
    return dr <= dl and 'right' or 'left', dr, dl
end

-- An aim's first frames can show the ball in the hand it is leaving: the item moves only once the ball has stayed this long in one.
local HAND_STEADY_MS = 250

--- The hand give mode's item belongs in now: the last seen throwing hand in this seat, else the seat's side.
local function giveHandNow()
    local side = throwHand()
    if side ~= giveSide then giveSide, giveSeenHand = side, nil end
    return giveSeenHand or side
end

local function AskForHandProp()
    local modelName = Inventory.itemPropModel(giveItemKey)
    if not modelName then return end
    modelName = modelName:lower()
    if giveProp then SetModelAsNoLongerNeeded(giveProp) end   -- an earlier give's, not let go yet
    giveProp = GetHashKey(modelName)
    giveHand = giveHandNow()
    RequestModel(giveProp)
    TriggerServerEvent('whip_core:server:giveHold', giveContainer, giveSlot, modelName, giveHand)
end

--- Give mode lets go of the hand: its held prop goes at once and the server forgets it.
local function DropHandProp()
    if not giveProp then return end
    UI.dropOwnHeldProp(giveProp, 'give')
    SetModelAsNoLongerNeeded(giveProp)
    giveProp = nil
    TriggerServerEvent('whip_core:server:heldPropsDrop', 'give')
end

--- Show give-mode HUD text (updates only when the text changes); `warn` rings it amber (no one in reach).
local _lastGiveText = nil
local function ShowGiveText(text, warn)
    if text == _lastGiveText then return end
    _lastGiveText = text
    UI.ShowText(text, { position = 'bottom', icon = 'give', tone = warn and 'warn' or nil })
end

local function HideGiveText()
    if _lastGiveText then
        _lastGiveText = nil
        UI.HideText()
    end
end

-- Weapon lock and gun turret seats: GTA hands a turret seat's gun to the ped as it sits down, and not while the weapon
-- lock (ped flag 48, ApplyWeaponLock) is on. So the lock is off while getting into and sitting in a turret seat
-- (WeaponLock.tick; seat moves lift it first via WeaponLock.beforeSeat). A player put straight into a turret seat
-- is caught on whip_core:vehicle:entered and sat down again with the lock off.
WeaponLock = {}

local function nativeYes(v) return v == true or v == 1 end   -- BOOL natives answer 1 or false

--- The gun turret seat the ped sits in or is getting into, as vehicle and seat; nil for any other.
local function TurretSeatOf(ped)
    local veh = GetVehiclePedIsIn(ped, false)
    if veh ~= 0 then
        for seat = -1, GetVehicleMaxNumberOfPassengers(veh) - 1 do
            if GetPedInVehicleSeat(veh, seat) == ped then
                if nativeYes(IsTurretSeat(veh, seat)) then return veh, seat end
                return nil
            end
        end
    end
    -- Not sat yet: the seat the get-in task is heading for.
    veh = GetVehiclePedIsTryingToEnter(ped)
    if veh ~= 0 then
        local seat = GetSeatPedIsTryingToEnter(ped)
        if nativeYes(IsTurretSeat(veh, seat)) then return veh, seat end
    end
    return nil
end

--- Cleanup all throw/give mode entities (weapon, props)
local function CleanupThrowMode()
    local ped = PlayerPedId()
    RemoveWeaponFromPed(ped, GetHashKey('WEAPON_BALL'))
    WeaponGuard.permit(GetCurrentResourceName(), 'WEAPON_BALL', false)
    SetPedConfigFlag(ped, 48, TurretSeatOf(ped) == nil)

    DropHandProp()
    -- (A thrown object is a ground item, TrackThrow's.)

    ThrowModeActive = false
    throwArmed = false
end

-- How the player moves while giving (SetGiveModeStyle): Config.GiveModeStyle unless a resource says otherwise.
-- [resource] = { walk = clipset|nil, speed = 'walk'|'jog'|nil, seq }: the latest wins; one goes when its resource stops.
-- The walk rides Emotes.overrideWalk (GIVE_WALK_KEY); the speed is the give block's (ControlBlocks walk / jog).
local giveStyles, giveStyleSeq = {}, 0
local giveStyleReg = Registry.new('GiveModeStyle', {
    label = 'give mode style',
    store = giveStyles,
    same  = function(old, new) return old.walk == new.walk and old.speed == new.speed end,
})
local GIVE_WALK_KEY = '#giveMode'   -- not a resource name: SetWalkOverride keys by those

--- The style in force: the newest set, or Config.GiveModeStyle.
local function giveStyle()
    local best
    for _, s in pairs(giveStyles) do
        if not best or s.seq > best.seq then best = s end
    end
    return best or Config.GiveModeStyle
end

--- The walk give mode puts on for `itemKey` (a clipset), or nil to keep the player's own (the item's playerWalk setting).
---@param itemKey string|nil  nil: the style's walk, whatever the item
---@return string|nil
function Inventory.giveWalkClipset(itemKey)
    local def = itemKey and Config.Items[itemKey]
    if def and def.playerWalk == true then return nil end
    local style = giveStyle()
    if not (style and style.walk and Emotes and Emotes.walkClipset) then return nil end
    return Emotes.walkClipset(style.walk)
end

--- Set how a player moves while giving, or clear with nil. `walk`: a /walk name or clipset; `speed`: 'jog' (no sprint) or 'walk'.
--- Keyed by the calling resource; takes effect from the next give.
---     exports.whip_core:SetGiveModeStyle({ walk = 'trash', speed = 'jog' })
exports('SetGiveModeStyle', function(style)
    local owner = Registry.caller()
    if style == nil or style == false then
        giveStyleReg:remove(owner, owner)
        return true
    end
    if type(style) ~= 'table' then return false, 'style must be a table: { walk?, speed? }' end
    if style.speed ~= nil and style.speed ~= 'jog' and style.speed ~= 'walk' then
        return false, "speed is 'jog' or 'walk' (or none)"
    end
    if style.walk ~= nil and (type(style.walk) ~= 'string' or style.walk == '') then
        return false, "walk is a /walk name ('trash') or a clipset"
    end
    giveStyleSeq = giveStyleSeq + 1
    local ok, why = giveStyleReg:add(owner, owner, { walk = style.walk, speed = style.speed, seq = giveStyleSeq })
    if not ok then return false, why end
    return true
end)

--- Cancel give mode (full reset)
local function CancelGiveMode()
    CleanupThrowMode()
    HideGiveText()
    giveMode        = false
    ControlBlocks.release('give')
    if Emotes and Emotes.overrideWalk then Emotes.overrideWalk(GIVE_WALK_KEY, nil) end   -- their own walk back
    giveContainer   = nil
    giveSlot        = nil
    giveItemName    = ''
    giveItemAmount  = 0
    giveItemKey     = ''
    giveRayTarget   = nil
    giveRayLastCheck = 0
end

-- Forward-declared: the give tick lives below its raycast helper.
local startGiveTick

--- NUI requests give mode (context menu "Give")
RegisterNUICallback('giveItem', function(data, cb)
    cb('ok')
    -- The ball and the item go in the hands, so not while they are blocked (client/hands.lua).
    local blocked, why = Inventory.handsBlocked()
    if blocked then UI.Notify(why --[[@as string]], 'error') return end   -- a block always has its words
    giveContainer  = data.container
    giveSlot       = tonumber(data.slot)
    giveItemName   = data.itemName or 'Item'
    giveItemAmount = data.itemAmount or 1
    giveItemKey    = data.itemKey or ''
    giveSeq        = giveSeq + 1

    -- Close inventory
    Inventory.close()

    -- Anything holding the player's hands gets a chance to let go first (RunClientHook).
    RunClientHook('beforeGiveMode')

    -- Enter give mode with tennis ball
    giveMode      = true
    -- No weapon switching while the ball is out (aiming and throwing still work). The scroll wheel is two control pairs
    -- (14/15, 16/17), both switch weapons; reload (45) is blocked because B cancels on a pad; C (26) cancels without swinging the camera.
    -- Speed and walk come from SetGiveModeStyle; an item allowing the player's walk keeps it (Inventory.giveWalkClipset).
    local style = giveStyle()
    ControlBlocks.hold('give', { groups = { 'weaponWheel' }, controls = { 37, 44, 45, 140, 26 },
        jog = style and style.speed == 'jog' or nil, walk = style and style.speed == 'walk' or nil })
    local walk = Inventory.giveWalkClipset(giveItemKey)
    if walk and Emotes and Emotes.overrideWalk then Emotes.overrideWalk(GIVE_WALK_KEY, walk) end
    giveStartTime = GetGameTimer()
    ThrowModeActive = false
    throwArmed    = false

    -- Equip tennis ball weapon
    local ped = PlayerPedId()
    SetPedConfigFlag(ped, 48, false)
    WeaponGuard.permit(GetCurrentResourceName(), 'WEAPON_BALL', true)   -- before the give: client/weapon_guard.lua
    GiveWeaponToPed(ped, GetHashKey('WEAPON_BALL'), 1, false, true)
    SetCurrentPedWeapon(ped, GetHashKey('WEAPON_BALL'), false)

    -- The item in the throwing hand (server held prop): the seat's guess until an aim shows it
    giveSeenHand, giveSide, giveSteady = nil, nil, nil
    AskForHandProp()

    startGiveTick()
end)

--- Raycast from camera to find peds
local function RaycastFromCamera(maxDist)
    local camCoords = GetGameplayCamCoord()
    local camRot    = GetGameplayCamRot(2)
    local rX = camRot.x * math.pi / 180.0
    local rZ = camRot.z * math.pi / 180.0
    local dir = vector3(
        -math.sin(rZ) * math.abs(math.cos(rX)),
         math.cos(rZ) * math.abs(math.cos(rX)),
         math.sin(rX)
    )
    local endCoords = camCoords + dir * maxDist
    -- Flag 8 = peds only, exclude own ped
    local ray = StartShapeTestRay(
        camCoords.x, camCoords.y, camCoords.z,
        endCoords.x, endCoords.y, endCoords.z,
        8, PlayerPedId(), 0
    )
    local _, hit, hitCoords, _, entity = GetShapeTestResult(ray)
    return hit == 1, entity, hitCoords
end


-- A thrown item in the air: a throw is a ground item from the moment it leaves the hand (the server makes the pile,
-- whip_core:server:throwLaunched). This follows the thrower's object until it lies still, then says how it lies
-- (throwSettled). Per frame only while a throw is in the air (ten seconds at most).

--- [netId] = { groundId = number|false|nil }: nil until the server answers, false when it refused.
local pendingThrows = {}
local THROW_ANSWER_MS = 5000   -- no answer by then: the throw is dropped, and the item never left

RegisterNetEvent('whip_core:client:throwAccepted', function(netId, groundId)
    local t = pendingThrows[netId]
    if t then t.groundId = groundId end
end)

RegisterNetEvent('whip_core:client:throwRefused', function(netId)
    local t = pendingThrows[netId]
    if t then t.groundId = false end
end)

-- Knocked over by a thrown item (Config.ThrowKnockdown). The item is not a GTA projectile, so the hit is looked for here:
--   * a player is knocked down by their own game when the item reaches them on screen (watchThrows);
--   * the thrower's game runs the flight, bounces the item off whoever it hits and knocks down people of the street.

local KNOCK_AHEAD  = 0.4   -- metres the hit ray runs past where the item got to (and half the item's size: its tip hits first)
local KNOCK_PUSH   = 0.1   -- of the item's speed, the shove the way it flew: about 2 m/s from a throw, a nudge into the fall
local KNOCK_BOUNCE = 0.2   -- of the item's speed, how fast it comes back off a body
-- metres from a player's body line (feet to head) at which an item's path counts as a hit: a body's half-width and some
-- (on the hit player's screen the item is network-smoothed and bounces back a little short)
local KNOCK_REACH  = 0.65
local WATCH_RANGE  = 30.0  -- metres: a flying throw further than this from you is not looked at
local WATCH_MAX_MS = 15000 -- a throw still "flying" after this is forgotten (its landing never reached this game)

--- Down for Config.ThrowKnockdown.RagdollMs, shoved the way the item flew. Not someone already down, in a car, or who cannot fall. The ped must be this game's.
local function knockDown(ped, dx, dy, dz, speed)
    if not DoesEntityExist(ped) or IsEntityDead(ped) or IsPedInAnyVehicle(ped, false) then return end
    if not CanPedRagdoll(ped) then return end
    local ms = math.floor(tonumber(Config.ThrowKnockdown.RagdollMs) or 2500)
    SetPedToRagdoll(ped, ms, ms, 0, false, false, false)
    local push = math.min(speed, 20.0) * KNOCK_PUSH
    ApplyForceToEntity(ped, 1, dx * push, dy * push, math.max(dz, 0.0) * push, 0.0, 0.0, 0.0, 0,
        false, true, true, false, true)
end

--- A person of the street: knocked down once this game controls them (waits 1.5 s at most). Not requested for one that cannot fall.
local function knockDownNpc(ped, dx, dy, dz, speed)
    if IsEntityDead(ped) or IsPedInAnyVehicle(ped, false) or not CanPedRagdoll(ped) then return end
    if NetworkHasControlOfEntity(ped) then return knockDown(ped, dx, dy, dz, speed) end
    NetworkRequestControlOfEntity(ped)
    CreateThread(function()
        local deadline = GetGameTimer() + 1500
        while not NetworkHasControlOfEntity(ped) and GetGameTimer() < deadline do Wait(0) end
        if NetworkHasControlOfEntity(ped) then knockDown(ped, dx, dy, dz, speed) end
    end)
end

--- The thrower's game, one frame of a flying throw: did it fly into someone? A ray along its path since the last frame,
--- people only, judged on the speed before this frame. It bounces back; a person of the street falls.
--- `k` is the throw's own { pos, vel, hit = { [ped] = true } }, each person once.
local function throwHitCheck(obj, vel, k)
    local cfg = Config.ThrowKnockdown
    if not cfg or cfg.Enabled == false then return end
    local pos = GetEntityCoords(obj)
    local last, lastVel = k.pos, k.vel
    k.pos, k.vel = pos, vel
    if not last then return end
    local speed = #lastVel
    if speed < (cfg.MinSpeed or 8.0) then return end
    local dx, dy, dz = lastVel.x / speed, lastVel.y / speed, lastVel.z / speed
    -- World, cars and props too (1 + 2 + 16), so a wall or window stops the look past it; the item itself is left out.
    -- Ahead by the item's half-size: a long gun's tip meets a body before its middle.
    local ahead = k.ahead or KNOCK_AHEAD
    local _, hit, hitPos, _, ped = GetShapeTestResult(StartExpensiveSynchronousShapeTestLosProbe(
        last.x, last.y, last.z, pos.x + dx * ahead, pos.y + dy * ahead, pos.z + dz * ahead,
        1 + 2 + 8 + 16, obj, 4))
    if hit ~= 1 or not ped or ped == 0 or k.hit[ped] or not DoesEntityExist(ped) or not IsEntityAPed(ped) then return end
    if ped == PlayerPedId() then return end
    -- Not off someone nobody can see (an invisible admin keeps collision).
if not IsEntityVisible(ped) then return end
    k.hit[ped] = true
    -- Off them, not through: back to where it met them, slowly and falling
    SetEntityCoordsNoOffset(obj, hitPos.x - dx * 0.2, hitPos.y - dy * 0.2, hitPos.z - dz * 0.2, false, false, false)
    local back = speed * KNOCK_BOUNCE
    SetEntityVelocity(obj, -dx * back, -dy * back, math.min(lastVel.z, 0.0) - 1.0)
    k.pos, k.vel = nil, nil   -- the next frame starts afresh from where it was put
    if not IsPedAPlayer(ped) and cfg.Npcs ~= false then knockDownNpc(ped, dx, dy, dz, speed) end
end

-- Every game: the flying throws near its own player (ground.lua names them as they launch)

local watched = {}   -- [netId] = { since, thrower (a player index), pos, vel, done }
local watchRunning = false

--- The nearest two points of segments AB and CD are within `r` of each other? (Each a pair of vector3s.)
local function segmentsWithin(a, b, c, d, r)
    local ux, uy, uz = b.x - a.x, b.y - a.y, b.z - a.z
    local vx, vy, vz = d.x - c.x, d.y - c.y, d.z - c.z
    local wx, wy, wz = a.x - c.x, a.y - c.y, a.z - c.z
    local aa, bb, cc = ux * ux + uy * uy + uz * uz, ux * vx + uy * vy + uz * vz, vx * vx + vy * vy + vz * vz
    local dd, ee = ux * wx + uy * wy + uz * wz, vx * wx + vy * wy + vz * wz
    local den = aa * cc - bb * bb
    local s, t = 0.0, 0.0
    if den > 1e-9 then s = math.max(0.0, math.min(1.0, (bb * ee - cc * dd) / den)) end
    t = cc > 1e-9 and (bb * s + ee) / cc or 0.0
    if t < 0.0 then
        t = 0.0
        s = aa > 1e-9 and math.max(0.0, math.min(1.0, -dd / aa)) or 0.0
    elseif t > 1.0 then
        t = 1.0
        s = aa > 1e-9 and math.max(0.0, math.min(1.0, (bb - dd) / aa)) or 0.0
    end
    local px, py, pz = wx + ux * s - vx * t, wy + uy * s - vy * t, wz + uz * s - vz * t
    return px * px + py * py + pz * pz <= r * r
end

local KNOCK_GRACE_MS = 1500   -- after getting up, this long before another throw can knock this player down
local knockedUntil = 0        -- GetGameTimer() before which this player cannot be knocked down again

--- This player knocked down by a throw. Not while dead, held in place by whip (frozen, hidden, no collision), or
--- invincible (no-PvP zone, god mode); not again until back up KNOCK_GRACE_MS.
local function knockMeDown(dx, dy, dz, speed)
    if PlayerIsDead or PedHold.wants('frozen') or PedHold.wants('hidden') or PedHold.wants('noCollision')
        or PedHold.wants('invincible') then return end
    local now = GetGameTimer()
    if now < knockedUntil then return end
    knockedUntil = now + math.floor(tonumber(Config.ThrowKnockdown.RagdollMs) or 2500) + KNOCK_GRACE_MS
    knockDown(PlayerPedId(), dx, dy, dz, speed)
end

--- Each frame while throws fly near: has one, flying fast, passed through this player's body? Not their own throw. Each throw once.
local function watchThrows()
    if watchRunning then return end
    watchRunning = true
    CreateThread(function()
        while next(watched) do
            local cfg = Config.ThrowKnockdown
            local now = GetGameTimer()
            local ped = PlayerPedId()
            local me = GetEntityCoords(ped)
            -- The body's line, short of soles and crown: with KNOCK_REACH it reaches the top of the head and a little round the feet.
            local feet, head = vector3(me.x, me.y, me.z - 0.55), vector3(me.x, me.y, me.z + 0.25)
            for netId, w in pairs(watched) do
                if now - w.since > WATCH_MAX_MS then
                    watched[netId] = nil
                elseif not w.done and cfg and cfg.Enabled ~= false and NetworkDoesNetworkIdExist(netId) then
                    local obj = NetToObj(netId)
                    -- Only an object (never a car or person) that the thrower's game runs: the id came from them, so a made-up id cannot name someone else's prop.
                    if obj ~= 0 and DoesEntityExist(obj) and GetEntityType(obj) == 3
                        and NetworkGetEntityOwner(obj) == w.thrower and not NetworkHasControlOfEntity(obj) then
                        local pos = GetEntityCoords(obj)
                        if #(pos - me) > WATCH_RANGE then
                            w.pos, w.vel = nil, nil
                        else
                            local vel = GetEntityVelocity(obj)
                            local last, lastVel = w.pos, w.vel
                            w.pos, w.vel = pos, vel
                            local speed = lastVel and #lastVel or 0.0
                            if last and speed >= (cfg.MinSpeed or 8.0) and segmentsWithin(last, pos, feet, head, KNOCK_REACH) then
                                -- No wall between it and this player: one look at the map, only on a seeming hit (not at props).
                                local _, blocked = GetShapeTestResult(StartExpensiveSynchronousShapeTestLosProbe(
                                    pos.x, pos.y, pos.z, me.x, me.y, me.z, 1, obj, 4))
                                if blocked ~= 1 then
                                    w.done = true
                                    knockMeDown(lastVel.x / speed, lastVel.y / speed, lastVel.z / speed, speed)
                                end
                            end
                        end
                    end
                end
            end
            Wait(0)
        end
        watchRunning = false
    end)
end

--- A throw was launched; watched until it lands. No thrower, no watch.
---@param netId number|nil
---@param throwerServerId number|string|nil
function Inventory.watchThrow(netId, throwerServerId)
    throwerServerId = tonumber(throwerServerId)
    if not netId or not throwerServerId or watched[netId] then return end
    -- The thrower as this game knows them (nil when not here)
    watched[netId] = { since = GetGameTimer(), thrower = GamePlatform.playerIndex(throwerServerId) }
    watchThrows()
end

--- It landed, was caught, or went.
---@param netId number|nil
function Inventory.unwatchThrow(netId)
    if netId then watched[netId] = nil end
end

-- Where a throw goes

local THROW_SPEED   = 18.0   -- m/s as it leaves the hand
local THROW_LOFT    = 2.5    -- m/s up, added to a throw at nothing in reach (every throw's arc, before)
-- The tumble a thrown thing leaves the hand with: a random turn about each axis within these bounds (radians a second, either way). It never changes the path.
local THROW_TWIST_MIN = 0.8
local THROW_TWIST_MAX = 4.0
local THROW_GRAVITY = 9.81

--- The velocity that carries a throw from `from` to land on `to` at THROW_SPEED, on the low (flatter) arc. nil when out of reach or straight above or below.
---@return number|nil vx, number|nil vy, number|nil vz
local function throwVelocity(from, to)
    local dx, dy, dz = to.x - from.x, to.y - from.y, to.z - from.z
    local d = math.sqrt(dx * dx + dy * dy)
    if d < 0.05 then return nil end
    local v, g = THROW_SPEED, THROW_GRAVITY
    local v2 = v * v
    local disc = v2 * v2 - g * (g * d * d + 2.0 * dz * v2)
    if disc < 0.0 then return nil end
    local tanA = (v2 - math.sqrt(disc)) / (g * d)
    local cosA = 1.0 / math.sqrt(1.0 + tanA * tanA)
    local h = v * cosA / d
    return dx * h, dy * h, v * tanA * cosA
end

--- Follow a thrown object to rest. `container`, `slot` and `amount` are where it came from.
---@param obj number  the networked object, already flying
---@param launchVel vector3  the velocity it left the hand with
local function TrackThrow(obj, container, slot, amount, launchVel)
    -- The hit check starts at the hand with the launch speed, so someone a metre or two ahead still counts (throwHitCheck)
    local mn, mx = GetModelDimensions(GetEntityModel(obj))
    local knock = { hit = {}, pos = GetEntityCoords(obj), vel = launchVel, ahead = KNOCK_AHEAD + #(mx - mn) * 0.5 }
    CreateThread(function()
        -- The server finds the pile's object by network id; it lands where this game saw it land.
        local waitUntil = GetGameTimer() + 1000
        while not NetworkGetEntityIsNetworked(obj) and GetGameTimer() < waitUntil do Wait(0) end
        local netId = NetworkGetNetworkIdFromEntity(obj)
        SetNetworkIdCanMigrate(netId, false)
        -- Every game nearby: hide GTA's tennis ball and watch this object (watchThrows), at once; the pile below reaches them later.
        TriggerServerEvent('whip_core:server:throwStarted', netId)
        local t = {}
        pendingThrows[netId] = t
        TriggerServerEvent('whip_core:server:throwLaunched', container, slot, amount, netId)

        local started, still = GetGameTimer(), 0
        while true do
            Wait(0)
            -- Refused or unanswered: the item never left the pockets, so neither may its object.
            local now = GetGameTimer()
            if t.groundId == false or (t.groundId == nil and now - started > THROW_ANSWER_MS) then
                if DoesEntityExist(obj) then DeleteEntity(obj) end
                break
            end
            -- Gone: picked out of the air or lost.
            if not DoesEntityExist(obj) then break end

            SetEntityMaxSpeed(obj, 100.0)   -- GTA clamps an object's speed mid-flight otherwise
            local vel = GetEntityVelocity(obj)
            if #vel < STILL_THRESHOLD then still = still + 1 else still = 0 end
            -- Flying into someone hard bounces off them (throwHitCheck)
            throwHitCheck(obj, vel, knock)
            local settled = still >= STILL_FRAMES_REQ
            if t.groundId and (settled or now - started > THROW_MAX_TRACK_TIME) then
                -- How it lies goes with it (origin and order-2 rotation, restored by the ground renderer). One that never settled is snapped upright.
                local c = GetEntityCoords(obj)
                local rot = GetEntityRotation(obj, 2)
                TriggerServerEvent('whip_core:server:throwSettled', t.groundId,
                    c.x, c.y, c.z, rot.z % 360.0, rot.x, rot.y, settled)
                -- The server deletes it once the pile is drawn; this is the backstop.
                SetTimeout(5000, function() if DoesEntityExist(obj) then DeleteEntity(obj) end end)
                break
            end
        end
        pendingThrows[netId] = nil
    end)
end

--- Give/throw mode tick, per frame while give mode lasts (started by the giveItem callback, ends with a give, throw or cancel).
local giveThreadRunning = false

local function giveTick()
    while giveMode do
        -- Give mode (ball equipped): aim and throw, give to a nearby player, or cancel. A thrown item flies on its own (TrackThrow).

        -- Death or a knockdown ends the mode at once and says so on the capsule (UI.ShowInterrupted).
        local stopped = (PlayerIsDead and 'You went down')
            or (IsPedRagdoll(PlayerPedId()) and BodyState.ragdollWhy(PlayerPedId())) or nil
        if stopped then
            UI.ShowInterrupted(stopped, 'Giving ' .. tostring(giveItemName))
            CancelGiveMode()
        end

        -- Timeout: the capsule says so.
        if giveMode and GetGameTimer() - giveStartTime > GIVE_TIMEOUT then
            UI.ShowInterrupted('Timed out', 'Giving ' .. tostring(giveItemName))
            CancelGiveMode()
        end

        -- The throwing hand: the right on foot. In a vehicle the ball is watched while aiming and the hand it stayed in for
        -- HAND_STEADY_MS is kept for this seat; changing seat resets to the seat's guess. The item moves when its hand is not that one.
        if giveMode and giveProp then
            local ped = PlayerPedId()
            if IsPedInAnyVehicle(ped, false) and (IsPlayerFreeAiming(PlayerId()) or IsPedDoingDriveby(ped)) then
                local seen, dr, dl = ballHand(ped)
                local now = GetGameTimer()
                if seen ~= giveSteady then giveSteady, giveSteadyAt = seen, now end
                if seen and seen ~= giveSeenHand and now - giveSteadyAt >= HAND_STEADY_MS then
                    giveSide, giveSeenHand = throwHand(), seen
                    if DevToolsOn and DevToolsOn() then
                        print(('[whip_core:give] the ball stayed in the %s hand (%.2f m from the right, %.2f m from the left; seat side %s): the item goes there')
                            :format(seen, dr, dl, giveSide))
                    end
                end
            else
                giveSteady = nil
            end
            if giveHandNow() ~= giveHand then AskForHandProp() end
        end

        if giveMode then
            -- Threw the ball (ammo dropped to 0); throwArmed avoids a false positive (ammo reads 0 briefly on equip)
            local ped = PlayerPedId()
            if not WEAPON_BALL_HASH then WEAPON_BALL_HASH = GetHashKey('WEAPON_BALL') end
            local ammo = GetAmmoInPedWeapon(ped, WEAPON_BALL_HASH)

            if not throwArmed then
                -- Wait until the ped has ammo before watching for throws
                if ammo > 0 then
                    throwArmed = true
                end
            elseif ammo <= 0 then
                -- Threw: make our own physics prop and launch it (GTA's ball entity cannot be found by natives).

                -- Aim at the world point under the crosshair, which corrects for the third-person camera offset.
                local camCoords = GetGameplayCamCoord()
                local camRot    = GetGameplayCamRot(2)
                local rX = camRot.x * math.pi / 180.0
                local rZ = camRot.z * math.pi / 180.0
                local camFwd = vector3(
                    -math.sin(rZ) * math.abs(math.cos(rX)),
                     math.cos(rZ) * math.abs(math.cos(rX)),
                     math.sin(rX)
                )
                -- Raycast far ahead from the camera. People count (a ray through them would aim at whatever is behind). Starts past the thrower, not at the camera, or something between would be the target.
                local pedAt = GetEntityCoords(ped)
                local fromCam = #(pedAt - camCoords) + 1.2
                local rayFrom = camCoords + camFwd * fromCam
                local farPoint = camCoords + camFwd * 200.0
                local _, rayHit, rayCoords = GetShapeTestResult(StartExpensiveSynchronousShapeTestLosProbe(
                    rayFrom.x, rayFrom.y, rayFrom.z,
                    farPoint.x, farPoint.y, farPoint.z,
                    1 + 2 + 8 + 16, ped, 4  -- world + vehicles + people + objects
                ))

                -- Target the hit, or a far point.
                local targetPoint
                if rayHit == 1 then
                    targetPoint = rayCoords
                else
                    targetPoint = farPoint
                end

                local pedCoords = GetEntityCoords(ped)

                -- How it sits in the hand (Edit hand position): the thrown one starts turned the same way.
                local held = giveProp and UI.ownHeldProp(giveProp, 'give')
                local handRot = held and GetEntityRotation(held, 2) or nil

                -- No longer holding the item: its hand prop goes.
                DropHandProp()

                -- Remove GTA's ball projectile (replaced by our prop)
                RemoveAllProjectilesOfType(GetHashKey('WEAPON_BALL'), false)

                -- The item's ground prop (requested when give mode started): the pile's model, and what the server checks the flying object against.
                local modelName = Inventory.itemPropModel(giveItemKey)
                local model = LoadModel(modelName, 2000)

                if model then
                    -- Spawn slightly in front of the player at chest height
                    local spawnPos = vector3(
                        pedCoords.x + camFwd.x * 1.2,
                        pedCoords.y + camFwd.y * 1.2,
                        pedCoords.z + 0.8
                    )

                    -- Direction from spawn toward the target, before the prop is made (both branches need it). A zero-length ray falls back to the camera's forward.
                    local toTarget = targetPoint - spawnPos
                    local dist = #toTarget
                    local dirX, dirY, dirZ
                    if dist > 0.001 then
                        dirX, dirY, dirZ = toTarget.x / dist, toTarget.y / dist, toTarget.z / dist
                    else
                        dirX, dirY, dirZ = camFwd.x, camFwd.y, camFwd.z
                    end

                    local obj = CreateObject(model, spawnPos.x, spawnPos.y, spawnPos.z, true, true, false)
                    if obj and obj ~= 0 then
                        if handRot then SetEntityRotation(obj, handRot.x, handRot.y, handRot.z, 2, true) end
                        -- Physics on: it flies and bounces.
                        SetEntityDynamic(obj, true)
                        SetEntityCollision(obj, true, true)
                        SetEntityHasGravity(obj, true)
                        ActivatePhysics(obj)

                        -- Remove GTA's heavy default air drag.
                        SetEntityMaxSpeed(obj, 100.0)

                        -- Onto the crosshair on an arc at THROW_SPEED. Out of reach (or the sky): straight along the aim with a little loft.
                        local vx, vy, vz = throwVelocity(spawnPos, targetPoint)
                        -- Never back toward the thrower.
                        if not vx or rayHit ~= 1 or (vx * camFwd.x + vy * camFwd.y) <= 0.0 then
                            vx, vy, vz = dirX * THROW_SPEED, dirY * THROW_SPEED, dirZ * THROW_SPEED + THROW_LOFT
                        end
                        SetEntityVelocity(obj, vx, vy --[[@as number]], vz --[[@as number]])   -- they come with vx
                        -- A little tumble each time (THROW_TWIST_*).
                        local function twist()
                            local t = THROW_TWIST_MIN + math.random() * (THROW_TWIST_MAX - THROW_TWIST_MIN)
                            return math.random() < 0.5 and -t or t
                        end
                        SetEntityAngularVelocity(obj, twist(), twist(), twist())

                        -- (Other games hide the ball on throwStarted.)
                        SetModelAsNoLongerNeeded(model)

                        -- It is a ground item now: give mode ends here so the hands are free.
                        TrackThrow(obj, giveContainer, giveSlot, giveItemAmount, vector3(vx, vy, vz))
                        CancelGiveMode()
                    else
                        -- Prop creation failed: raycast fallback.
                        SetModelAsNoLongerNeeded(model)
                        local endPos = vector3(pedCoords.x + dirX * 30.0, pedCoords.y + dirY * 30.0, pedCoords.z + dirZ * 30.0)
                        local _, hit, hitCoords = GetShapeTestResult(StartExpensiveSynchronousShapeTestLosProbe(
                            pedCoords.x, pedCoords.y, pedCoords.z + 0.8, endPos.x, endPos.y, endPos.z, 1 + 16, ped, 4))
                        local lx, ly, lz = pedCoords.x, pedCoords.y, pedCoords.z - 0.5
                        if hit == 1 then lx, ly, lz = hitCoords.x, hitCoords.y, hitCoords.z end
                        TriggerServerEvent('whip_core:server:throwItemLanded',
                            giveContainer, giveSlot, giveItemAmount, lx, ly, lz, GetEntityHeading(ped))

                        CancelGiveMode()
                    end
                else
                    -- Model load failed: drop at feet.
                    TriggerServerEvent('whip_core:server:throwItemLanded',
                        giveContainer, giveSlot, giveItemAmount,
                        pedCoords.x, pedCoords.y, pedCoords.z - 0.5, GetEntityHeading(ped))

                    CancelGiveMode()
                end
            else
                -- Still holding: show the give/throw HUD.

                -- Raycast from the camera for a direct handoff (every 200 ms).
                local now = GetGameTimer()
                if now - giveRayLastCheck > 200 then
                    giveRayLastCheck = now
                    giveRayTarget = nil
                    local hit, entity, _ = RaycastFromCamera(GIVE_MAX_DIST)
                    if hit and entity ~= 0 and IsEntityAPed(entity) and entity ~= PlayerPedId() then
                        local playerIdx = NetworkGetPlayerIndexFromPed(entity)
                        if playerIdx ~= -1 then
                            -- No name: GetPlayerName is the account name, not the character, so give says "player".
                            giveRayTarget = { serverId = GetPlayerServerId(playerIdx) }
                        end
                    end
                end

                -- Draw the HUD. On a pad the throw is said too (RT) and keys show button pictures.
                local throwHint = WhipPadActive and '{pad:rt} Throw  |  ' or ''
                if giveRayTarget then
                    ShowGiveText(WhipAcceptHint() .. ' Give to player  |  ' .. throwHint
                        .. WhipCancelHint() .. ' Cancel')
                else
                    -- No one to give to: said, as placing says "Aim at a surface".
                    ShowGiveText('Aim at someone within reach  |  ' .. throwHint .. WhipCancelHint() .. ' Cancel', true)
                end

                -- E (INPUT_PICKUP = 38), A on a pad but never LB + A (WhipAcceptJustPressed): confirm direct give. Disabled readers still count while another block holds them.
                if WhipAcceptJustPressed() and giveRayTarget then

                    TriggerServerEvent('whip_core:server:giveItem',
                        giveRayTarget.serverId, giveContainer, giveSlot, giveItemAmount
                    )
                    -- Stop the tick but keep the ball for the animation.
                    HideGiveText()
                    giveMode        = false
                    ControlBlocks.release('give')
                    if Emotes and Emotes.overrideWalk then Emotes.overrideWalk(GIVE_WALK_KEY, nil) end   -- their own walk back
                    giveContainer   = nil
                    giveSlot        = nil
                    giveItemName    = ''
                    giveItemAmount  = 0
                    giveItemKey     = ''
                    giveRayTarget   = nil
                    giveRayLastCheck = 0
                    -- Delayed cleanup until the give animation finishes. The hand prop stays too: a give that lands has the server
                    -- take it at the clip's middle; a refused one is let go here. Skipped if give mode restarted meanwhile.
                    local seq = giveSeq
                    CreateThread(function()
                        Wait(4000) -- 500ms face + 2000ms anim + network buffer
                        if giveSeq == seq then CleanupThrowMode() end
                    end)
                end

                -- Cancel: C (INPUT_LOOK_BEHIND = 26) on a keyboard, B on a pad.
                if WhipCancelJustPressed() then
                    CancelGiveMode()
                    UI.Notify('Give cancelled', 'error')
                end
            end
        end

        Wait(0)
    end
    giveThreadRunning = false
end

--- Start the tick unless it is running (giveItem callback only).
startGiveTick = function()
    if giveThreadRunning then return end
    giveThreadRunning = true
    CreateThread(giveTick)
end

--- Another client threw an item: remove the ball projectile so only the item prop shows.
RegisterNetEvent('whip_core:client:playerThrew', function(throwerServerId, netId)
    if GetPlayerServerId(PlayerId()) == throwerServerId then return end
    RemoveAllProjectilesOfType(GetHashKey('WEAPON_BALL'), false)
    -- ...and watch what flies (watchThrows).
    if tonumber(netId) then Inventory.watchThrow(tonumber(netId), throwerServerId) end
end)

--- Handoff animation, triggered by the server on giver and receiver. Animation only: the item moves as the server's held prop at the clip's middle.
RegisterNetEvent('whip_core:client:playGiveAnim', function(otherServerId, isGiver)
    local ped  = PlayerPedId()
    local dict = 'mp_common'
    local clip = isGiver and 'givetake1_a' or 'givetake1_b'

    -- Face the other player.
    local otherPlayerIdx = GamePlatform.playerIndex(otherServerId)
    if otherPlayerIdx then
        local otherPed = GetPlayerPed(otherPlayerIdx)
        if otherPed and otherPed ~= 0 then
            TaskTurnPedToFaceEntity(ped, otherPed, 500)
            Wait(500)
        end
    end

    -- Play the animation.
    if LoadAnimDict(dict, 2000) then
        TaskPlayAnim(ped, dict, clip, 8.0, -8.0, 2000, 0, 0, false, false, false)

        -- (The props cross at the clip's middle, on the server's clock.)
        Wait(2000)
        ClearPedTasks(isGiver and ped or PlayerPedId())
        RemoveAnimDict(dict)
    else
        RemoveAnimDict(dict)
    end
end)

-- GTA weapon wheel off, in three parts: ped config flag 48 blocks switching (ApplyWeaponLock); the wheel's UI is hidden
-- as HUD components 19/20 (client/hud.lua); the wheel still opens and plays a sound, so a suppressor below calls
-- BlockWeaponWheelThisFrame each frame, armed only after a TAB or scroll press and expiring on its own.

--- How long after an input the wheel can still be opening (too short lets the sound through).
local WHEEL_SUPPRESS_MS = 1200

--- Hard ceiling for a HELD key, so a `-` command that never arrives cannot leave this running.
local WHEEL_SUPPRESS_MAX_MS = 10000

local wheelSuppressUntil = 0
local wheelSuppressing   = false

--- Block the wheel for a while. Repeat calls extend the window rather than stacking threads.
---@param ms? number  how long to suppress for, default WHEEL_SUPPRESS_MS
function Inventory.suppressWeaponWheel(ms)
    -- This frame: the wheel opens on TAB in the same frame as the keypress, so a later start misses the sound.
    BlockWeaponWheelThisFrame()

    local now = GetGameTimer()
    local want = now + math.min(ms or WHEEL_SUPPRESS_MS, WHEEL_SUPPRESS_MAX_MS)
    if want > wheelSuppressUntil then wheelSuppressUntil = want end

    if wheelSuppressing then return end
    wheelSuppressing = true

    -- Both: BlockWeaponWheelThisFrame suppresses the wheel; control 37 is the input that asks for it, and holding it off stops the sound.
    ControlBlocks.hold('wheel', { controls = { 37 } }, function()
        if GetGameTimer() >= wheelSuppressUntil then
            wheelSuppressing = false
            ControlBlocks.release('wheel')
            return
        end
        BlockWeaponWheelThisFrame()
    end)
end

--- Stop early (letting go of TAB ends it at once).
local function releaseWeaponWheelSuppress()
    wheelSuppressUntil = 0
end


exports('IsInventoryOpen', function() return Inventory.isOpen() end)

exports('CloseInventory', function()
    Inventory.close()
end)

--- Ped config flag 48 (BlockWeaponSwitching): persistent, stops weapon switching without per-frame disables. It does not hide the wheel (client/hud.lua does).
--- Set on every ped change and kept in step with the seat: off in a gun turret seat (TurretSeatOf).
local function ApplyWeaponLock()
    local ped = PlayerPedId()
    if ped and ped ~= 0 then
        SetPedConfigFlag(ped, 48, TurretSeatOf(ped) == nil)
    end
end

-- The local whip_core:player:loaded, not the net event, which arrives before the load swaps the model (a new ped).
AddEventHandler('whip_core:player:loaded', function()
    ApplyWeaponLock()
end)

--- Every 200 ms from the vehicle tick, on foot too: the lock follows the seat. Give mode holds it off until it ends (CleanupThrowMode).
function WeaponLock.tick(ped)
    if giveMode then return end
    local want = TurretSeatOf(ped) == nil
    if nativeYes(GetPedConfigFlag(ped, 48, true)) ~= want then SetPedConfigFlag(ped, 48, want) end
end

--- whip is about to put the player into `seat` of `veh`: a turret seat's gun is handed over only if the lock is already off.
function WeaponLock.beforeSeat(ped, veh, seat)
    if nativeYes(IsTurretSeat(veh, seat)) then SetPedConfigFlag(ped, 48, false) end
end

-- Put into a turret seat by something else (lock on, no gun): after the game's moment (the gun arrives within 100 ms), sat down again.
local TURRET_GUN_WAIT_MS = 500
AddEventHandler('whip_core:vehicle:entered', function(data)
    if type(data) ~= 'table' or not data.entity or not data.seat then return end
    local veh, seat = data.entity, data.seat
    if not nativeYes(IsTurretSeat(veh, seat)) then return end
    SetTimeout(TURRET_GUN_WAIT_MS, function()
        local ped = PlayerPedId()
        if GetVehiclePedIsIn(ped, false) ~= veh or GetPedInVehicleSeat(veh, seat) ~= ped then return end
        if nativeYes((GetCurrentPedVehicleWeapon(ped))) then return end
        SetPedConfigFlag(ped, 48, false)
        ClearPedTasksImmediately(ped)   -- out and back in within one frame: the vehicle tick never sees it
        SetPedIntoVehicle(ped, veh, seat)
    end)
end)

--- A satellite registered an item: only drops the flag; the next open asks for the definitions.
RegisterNetEvent('whip_core:client:itemDefsStale', function()
    _haveItemDefs = false
end)

--- Light inventory sync on load: fills the item cache, flags and hotbar before the first open.
RegisterNetEvent('whip_core:client:inventoryFlagsSync', function(inventory, itemDefs, slotDefs)
    if not inventory then return end
    _cachedInventory = inventory

    -- The definitions arrive here, once; later opens leave them out.
    if itemDefs then
        _haveItemDefs = true
        _nuiItemDefs = itemDefs
        adoptServerItemDefs(itemDefs)
    end

    UpdateItemFlags({ inventory = inventory })
    SendNUIMessage({
        action   = 'inventoryFlagsSync',
        inventory = inventory,
        itemDefs  = itemDefs,
        -- The accessory/ignition slot registry, for players who joined after the broadcasts.
        slotDefs  = slotDefs,
    })
end)

--- The accessory-strip and ignition-key registry changed; the payload is the whole current table.
RegisterNetEvent('whip_core:client:invSlotDefs', function(payload)
    SendNUIMessage({
        action = 'registerInvSlotDefs',
        data   = payload,
    })
end)

AddEventHandler('playerSpawned', function()
    ApplyWeaponLock()
end)

-- Hotbar: Tab quick-use bar (slots 1-5)

local tabPressTime = 0
local tabShowing = false   -- the press put the hotbar up, so the release must take it down

RegisterCommand('+tabhotbar', function()
    -- Armed before the UI guard: TAB is GTA's weapon-wheel key whatever is open.
    Inventory.suppressWeaponWheel(10000)

    if not IsGameInputFree() then return end   -- the world-key question, as the slot keys
    tabPressTime = GetGameTimer()
    tabShowing = true
    SendNUIMessage({ action = 'holdHotbar' })
end, false)

RegisterCommand('-tabhotbar', function()
    -- Ended here rather than left to expire.
    releaseWeaponWheelSuppress()

    -- The release is never gated: a press that put the hotbar up always takes it down.
    if not tabShowing then return end
    tabShowing = false
    local held = GetGameTimer() - tabPressTime
    if held < 200 and IsGameInputFree() then
        SendNUIMessage({ action = 'tapHotbar' })
    else
        SendNUIMessage({ action = 'releaseHotbar' })
    end
end, false)

RegisterKeyMapping('+tabhotbar', 'Hotbar (hold/tap)', 'keyboard', 'TAB')

--- Use pocket slot 1-5 (the server uses what is in it). Called by the number keys and the pad's hotkeys wheel, which ask the world-key question first.
---@param i integer 1-5
---@param quiet boolean|nil  no hotbar: the wheel's pick (the wheel already showed the slot)
function Inventory.useHotbarSlot(i, quiet)
    -- Key bindings fire even with controls disabled on the death screen, so the hotbar asks like the inventory key.
    if PlayerIsDead then return end
    -- Said first, so what it ends (the camera viewfinder) is gone before the flash.
    WhipEmit('whip_core:hotbar:slotUsed', { slot = i })
    -- A number key shows the hotbar briefly with the slot flashed.
    if not quiet then SendNUIMessage({ action = 'useHotbarSlot', slot = i }) end
    TriggerServerEvent('whip_core:server:useItem', 'player', i)
end

-- Number keys 1-5: use hotbar slot (sends to server)
for i = 1, 5 do
    local cmd = 'hotbar_' .. i
    RegisterCommand(cmd, function()
        -- A world key: not under a placement ghost or in give mode, unless the mode lets it through (the camera item).
        if not IsGameInputFree(false, false, true) then return end
        Inventory.useHotbarSlot(i)
    end, false)
    RegisterKeyMapping(cmd, 'Hotbar Slot ' .. i, 'keyboard', tostring(i))
end

-- Cleanup menu ped on resource stop
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    hideMenuPed()
    -- A restart mid-give: CleanupThrowMode deletes the hand prop and strips WEAPON_BALL (no-op otherwise).
    CleanupThrowMode()
end)

-- Aliases for client/shops.lua only; everything else uses Inventory.openUI / Inventory.close.
OpenInventoryUI = Inventory.openUI
CloseInventory  = Inventory.close
