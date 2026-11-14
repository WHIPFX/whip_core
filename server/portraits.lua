-- ============================================
-- Portraits — each character's face, as GTA's own headshot
-- ============================================
--
-- GTA makes a headshot of a ped for its pause menu (RegisterPedheadshot). whip takes one of each
-- character whenever they are put into the world — every load, and again when the appearance
-- creator closes (client/portrait.lua) — the page turns it into a small picture (html/js/portrait.js),
-- and it is kept here, one row per character, for anything in whip that shows a person: the /whip
-- panel's people (Jobs, Players) first.
--
-- KEPT AS IT CAME: a data: URL, webp or png, checked to be one and under MAX_LEN. A character who
-- has not logged in since this existed has none, and whoever shows them falls back to initials.
--
-- READ ON DEMAND, NEVER BROADCAST. An admin's panel asks for the people it is showing
-- (whip_core:portraits, a page of them at a time); nothing is pushed to every player.

Portraits = {}

local MAX_LEN = 65536      -- a 128 px headshot as webp is a few KB; this is generous, and a ceiling
local SAVE_EVERY_S = 20    -- a character's portrait is written at most this often (spawn, then creator)
local PAGE = 20            -- the most portraits one ask answers: one answer is one reliable event, so
                           -- kept small (a few KB each); the panel asks a page at a time (pickers.js)

local lastSaved = {}       -- [charId] = os.time() of the last write

local function say(fmt, ...) print(('[whip_core:portraits] ' .. fmt):format(...)) end

--- The table: one row per character, gone with the character (ON DELETE CASCADE).
---@return boolean ok
function Portraits.ensureTable()
    return CreateTable('character_portraits', [[
        CREATE TABLE IF NOT EXISTS `character_portraits` (
            `charId`    INT UNSIGNED NOT NULL,
            `image`     MEDIUMTEXT   NOT NULL,
            `updatedAt` TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`charId`),
            CONSTRAINT `fk_portrait_char` FOREIGN KEY (`charId`)
                REFERENCES `characters` (`charId`) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
end

--- Is this a picture we keep: a webp or png data: URL of whole base64, not too long?
---@param image string
---@return boolean
local function isPicture(image)
    if #image > MAX_LEN then return false end
    local body = image:match('^data:image/webp;base64,([%w%+/=]+)$') or image:match('^data:image/png;base64,([%w%+/=]+)$')
    return body ~= nil and #body % 4 == 0 and #body >= 100
end
-- A lore character's headshot is kept by the same rule (server/director/lore.lua).
Portraits.isPicture = isPicture
Portraits.MAX_LEN = MAX_LEN

-- The player's own game hands in the portrait of the character it is playing — never anyone else's:
-- the row is the character the server says they are on.
SecureEvent('whip_core:server:portraitSave', {
    rateLimit = 10000,
    params = { {'image', 'string', MAX_LEN + 1} },   -- one over: a cut-off picture is refused, not kept
}, function(_, player, image)
    local charId = player and player.charId
    if not charId then return false, 'No character' end
    if not isPicture(image) then return false, 'Not a portrait' end
    local now = os.time()
    if lastSaved[charId] and now - lastSaved[charId] < SAVE_EVERY_S then return end
    lastSaved[charId] = now
    local ok, err = pcall(MySQL.query.await,
        'INSERT INTO `character_portraits` (`charId`, `image`) VALUES (?, ?) '
        .. 'ON DUPLICATE KEY UPDATE `image` = VALUES(`image`)', { charId, image })
    if not ok then
        lastSaved[charId] = nil
        say('^1the portrait of character %d was not saved: %s^0', charId, tostring(err))
        return false, 'Your portrait was not saved'
    end
end)

-- The portraits of the people a panel is showing: { ok = true, portraits = { [charId] = dataUrl } }.
-- A character with none is left out, and the panel draws their initials.
SecureCallback('whip_core:portraits', {
    ace = 'whip.devtools',
    rateLimit = 200,
    burst = 10,
    params = { {'charIds', 'any'} },
}, function(_, _, charIds)
    if type(charIds) ~= 'table' then return { ok = true, portraits = {} } end
    local ids, seen = {}, {}
    for _, v in ipairs(charIds) do
        local n = math.tointeger(tonumber(v))
        if n and n > 0 and not seen[n] then
            seen[n] = true
            ids[#ids + 1] = n
            if #ids >= PAGE then break end
        end
    end
    if #ids == 0 then return { ok = true, portraits = {} } end
    local ok, rows = pcall(MySQL.query.await,
        'SELECT `charId`, `image` FROM `character_portraits` WHERE `charId` IN ('
        .. string.rep('?', #ids, ',') .. ')', ids)
    if not ok then return false, 'The portraits could not be read' end
    local out = {}
    for _, r in ipairs(rows or {}) do out[tostring(r.charId)] = r.image end
    return { ok = true, portraits = out }
end)

-- The player's own portrait, for their own screens (the shop's talk capsule):
-- { ok = true, image = dataUrl } or { ok = true } for none. Only ever the character they are playing;
-- their page keeps it after the first ask (html/js/portrait.js), and has it at once after a new one is
-- taken, so this is asked about once a character.
SecureCallback('whip_core:myPortrait', {
    rateLimit = 2000,
    burst = 3,
}, function(_, player)
    local charId = player and player.charId
    if not charId then return { ok = true } end
    local ok, rows = pcall(MySQL.query.await,
        'SELECT `image` FROM `character_portraits` WHERE `charId` = ?', { charId })
    if not ok then return { ok = false } end
    local row = rows and rows[1]
    return { ok = true, image = row and row.image or nil }
end)
