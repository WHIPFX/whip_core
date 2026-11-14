-- ============================================
-- Item holds — how an item sits in a hand
-- ============================================
--
-- Where an item is held when a player holds it out to give or throw (give mode: server/events_inventory.lua
-- giveHold): its offset and rotation from the hand's bone, for the right hand and for the left (a vehicle's
-- left-hand seat throws left-handed out of its window). Set in game: /whip → Items → an item → Edit hand
-- position (tools/hand_edit.lua). An item with none is held as every item always was (GIVE_OFFSET / GIVE_ROT).
-- A thrown one leaves the hand turned as it is held (client/inventory.lua).
--
-- Kept in the database (whip_item_holds). Saving is a permanent admin's (whip.devtools from server.cfg, as
-- settings are), and so is reading through the editor's callback (whip_core:itemHolds:get). Everyone else gets a
-- hold where it is used: the server puts it on the prop it gives (giveHold), so nobody's game has to ask.

ItemHolds = {}

local DEVTOOLS = 'whip.devtools'
local HANDS = { right = true, left = true }
local MAX_OFFSET = 1.0   -- metres from the hand: a hold further out is a mistake

local holds = {}   -- [item][hand] = { offset = {x,y,z}, rot = {x,y,z} }

function ItemHolds.ensureTable()
    return CreateTable('whip_item_holds', [[
        CREATE TABLE IF NOT EXISTS `whip_item_holds` (
            `item`      VARCHAR(64)  NOT NULL,
            `hand`      VARCHAR(5)   NOT NULL,
            `ox` FLOAT NOT NULL, `oy` FLOAT NOT NULL, `oz` FLOAT NOT NULL,
            `rx` FLOAT NOT NULL, `ry` FLOAT NOT NULL, `rz` FLOAT NOT NULL,
            `updatedBy` VARCHAR(100) NULL,
            `updatedAt` TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`item`, `hand`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
end

--- A boot loader (server/player_lifecycle.lua). False on a failed read.
---@return boolean
function ItemHolds.loadAll()
    local ok, res = pcall(MySQL.query.await, 'SELECT * FROM `whip_item_holds`', {})
    if not ok or type(res) ~= 'table' then
        print(('[whip_core:items] ^1the saved hand positions could not be read: %s^0'):format(tostring(res)))
        return false
    end
    holds = {}
    for _, r in ipairs(res) do
        if HANDS[r.hand] then
            holds[r.item] = holds[r.item] or {}
            holds[r.item][r.hand] = {
                offset = { tonumber(r.ox) or 0.0, tonumber(r.oy) or 0.0, tonumber(r.oz) or 0.0 },
                rot    = { tonumber(r.rx) or 0.0, tonumber(r.ry) or 0.0, tonumber(r.rz) or 0.0 },
            }
        end
    end
    return true
end

--- How `item` sits in `hand` ('right' | 'left'), or nil when it has no hold of its own. The left takes the
--- right's when it has none of its own (a start, nudged in the editor).
---@return table|nil  { offset = {x,y,z}, rot = {x,y,z} }
function ItemHolds.get(item, hand)
    local h = holds[item]
    if not h then return nil end
    return h[hand] or (hand == 'left' and h.right) or nil
end

local function round(v) return math.floor(v * 10000 + 0.5) / 10000 end

SecureCallback('whip_core:itemHolds:get', {
    ace = DEVTOOLS, rateLimit = 500, burst = 4, params = { { 'item', 'key', 64 } },
}, function(_, _, item)
    if not Config.Items[item] then return false, 'There is no item called ' .. item end
    local h = holds[item] or {}
    return { right = h.right or false, left = h.left or false, walk = Config.Items[item].playerWalk == true,
             grab = Config.Items[item].grab == '2h' and '2h' or '1h' }
end)

--- One of the item's settings from the editor (server/item_settings.lua): changed as any setting is, logged and with
--- Reset, a permanent admin's. config.lua's items keep theirs in Config.
local function changeItemSetting(source, item, key, value)
    local change = ItemSettings.inConfig(item)
        and { owner = GetCurrentResourceName(), path = 'Items.' .. item .. '.' .. key, value = value }
        or { owner = ItemSettings.ownerOf(item), path = key, value = value }
    return Settings.change(source, { change })
end

--- The item's "Allow player walk animation" (its playerWalk setting), from the editor.
SecureCallback('whip_core:itemHolds:walk', {
    ace = DEVTOOLS, rateLimit = 1000, burst = 3, params = { { 'item', 'key', 64 }, { 'on', 'bool' } },
}, function(source, _, item, on)
    if not Config.Items[item] then return false, 'There is no item called ' .. item end
    local ok, why = changeItemSetting(source, item, 'playerWalk', on)
    if not ok then return false, why or 'It was not saved' end
    return { walk = on }
end)

--- Whether the item is picked up with both hands (its grab setting, '2h' or '1h'), from the editor.
SecureCallback('whip_core:itemHolds:grab', {
    ace = DEVTOOLS, rateLimit = 1000, burst = 3, params = { { 'item', 'key', 64 }, { 'twoHands', 'bool' } },
}, function(source, _, item, twoHands)
    if not Config.Items[item] then return false, 'There is no item called ' .. item end
    local ok, why = changeItemSetting(source, item, 'grab', twoHands and '2h' or '1h')
    if not ok then return false, why or 'It was not saved' end
    return { grab = twoHands and '2h' or '1h' }
end)

--- Every item, for the editor's list (html/js/hand-edit.js): { key, name, resource, img, set }, by name. `set`: it has
--- a hand position of its own.
SecureCallback('whip_core:itemHolds:list', {
    ace = DEVTOOLS, rateLimit = 2000, burst = 2,
}, function()
    local out = {}
    for key, def in pairs(Config.Items) do
        out[#out + 1] = {
            key = key, name = tostring(def.name or key), resource = Inventory.itemOwner(key) or 'whip_core',
            img = Inventory.resolveItemImage(key, def), set = holds[key] ~= nil,
        }
    end
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    return out
end)

SecureCallback('whip_core:itemHolds:save', {
    ace = DEVTOOLS, rateLimit = 1000, burst = 3,
    params = {
        { 'item', 'key', 64 }, { 'hand', 'enum', { 'right', 'left' } },
        { 'ox', 'number', -MAX_OFFSET, MAX_OFFSET }, { 'oy', 'number', -MAX_OFFSET, MAX_OFFSET },
        { 'oz', 'number', -MAX_OFFSET, MAX_OFFSET },
        { 'rx', 'number', -360.0, 360.0 }, { 'ry', 'number', -360.0, 360.0 }, { 'rz', 'number', -360.0, 360.0 },
    },
}, function(source, _, item, hand, ox, oy, oz, rx, ry, rz)
    if not Settings.mayEdit(source) then return false, 'Only a permanent admin can change how items are held' end
    if not Config.Items[item] then return false, 'There is no item called ' .. item end
    return ItemHolds.store(item, hand, ox, oy, oz, rx, ry, rz, GetPlayerName(source))
end)

--- Save how `key` sits in `hand`: an item's key, or a resource's held prop by its set's tag ('whip_fuel:nozzle',
--- server/held_props.lua; the colon keeps it apart from every item). The row as saved, or false and why.
---@return table|false row
---@return string|nil why
function ItemHolds.store(key, hand, ox, oy, oz, rx, ry, rz, by)
    local row = { offset = { round(ox), round(oy), round(oz) }, rot = { round(rx), round(ry), round(rz) } }
    local ok, err = pcall(MySQL.update.await, [[
        INSERT INTO `whip_item_holds` (`item`, `hand`, `ox`, `oy`, `oz`, `rx`, `ry`, `rz`, `updatedBy`)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE `ox` = VALUES(`ox`), `oy` = VALUES(`oy`), `oz` = VALUES(`oz`),
            `rx` = VALUES(`rx`), `ry` = VALUES(`ry`), `rz` = VALUES(`rz`), `updatedBy` = VALUES(`updatedBy`)
    ]], { key, hand, row.offset[1], row.offset[2], row.offset[3], row.rot[1], row.rot[2], row.rot[3], by })
    if not ok then
        print(('[whip_core:items] saving the hand position of %s failed: %s'):format(key, tostring(err)))
        return false, 'Could not save it (the database said no)'
    end
    holds[key] = holds[key] or {}
    holds[key][hand] = row
    return row
end
