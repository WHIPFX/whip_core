-- ============================================
-- Camera sequences — the Camera Creator's timelines, kept by name
-- ============================================
--
-- A sequence (shared/cam_sequence.lua) saved in the Camera Creator is kept here under a name, in the
-- database (whip_camera_sequences), so other admins open it and any script plays it:
--
--     exports.whip_core:PlayCameraSequence('intro')                       -- on a player's game
--     exports.whip_core:PlayCameraSequence('intro', { subjects = { target = veh } })
--
-- Every sequence is checked with CamSequence.clean, the rules the camera plays by, as it is saved and as
-- it is loaded: one that no longer passes (a field taken away) is left out at start, said in the console.
-- Saving and deleting are a permanent admin's (whip.devtools from server.cfg, as settings are); reading
-- one to play is anyone's, since a camera path is not a secret.

CameraSequences = {}

local DEVTOOLS = 'whip.devtools'
local NAME_PATTERN = '^[%w_%-]+$'
local MAX_JSON = 256 * 1024

local seqs = {}   -- [name] = { data = clean sequence, by = who saved it, at = os.time() }

local function say(fmt, ...) print(('[whip_core:camera] ' .. fmt):format(...)) end

function CameraSequences.ensureTable()
    return CreateTable('whip_camera_sequences', [[
        CREATE TABLE IF NOT EXISTS `whip_camera_sequences` (
            `name`      VARCHAR(60)  NOT NULL,
            `data`      MEDIUMTEXT   NOT NULL,
            `updatedBy` VARCHAR(100) NULL,
            `updatedAt` TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`name`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
end

--- A boot loader (server/player_lifecycle.lua): every saved sequence, checked. False on a failed read.
---@return boolean
function CameraSequences.loadAll()
    local ok, res = pcall(MySQL.query.await,
        'SELECT `name`, `data`, `updatedBy`, UNIX_TIMESTAMP(`updatedAt`) AS `at` FROM `whip_camera_sequences`', {})
    if not ok or type(res) ~= 'table' then
        say('^1the saved camera sequences could not be read: %s^0', tostring(res))
        return false
    end
    seqs = {}
    for _, r in ipairs(res) do
        local okJson, data = pcall(json.decode, r.data or '')
        ---@type table|nil, string|nil
        local clean, why = nil, 'is not readable'
        if okJson then clean, why = CamSequence.clean(data) end
        if clean then
            clean.name = r.name
            seqs[r.name] = { data = clean, by = r.updatedBy, at = tonumber(r.at) }
        else
            say('^3the saved sequence %s %s: it is left out^0', tostring(r.name), tostring(why))
        end
    end
    return true
end

---@param name any
---@return boolean
local function goodName(name)
    return type(name) == 'string' and #name >= 1 and #name <= 60 and name:match(NAME_PATTERN) ~= nil
end

--- A saved sequence, as the camera plays it (a copy), or nil.
---@param name string
---@return table|nil
function CameraSequences.get(name)
    local s = goodName(name) and seqs[name]
    if not s then return nil end
    return json.decode(json.encode(s.data))
end

--- Every saved sequence, for the Creator's list: { { name, length, keys, by, at }, ... }, by name.
function CameraSequences.list()
    local out = {}
    for name, s in pairs(seqs) do
        out[#out + 1] = { name = name, length = s.data.length, keys = #s.data.keys, by = s.by, at = s.at }
    end
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    return out
end

--- Keep `data` under `name`, replacing one of that name. Answers the clean sequence, or false and why.
---@param src number
---@param name string
---@param data table
function CameraSequences.save(src, name, data)
    if not goodName(name) then return false, 'A name is letters, digits, _ and -, up to 60' end
    local clean, why = CamSequence.clean(data)
    if not clean then return false, 'Not saved: ' .. tostring(why) end
    clean.name = name
    local text = json.encode(clean)
    if #text > MAX_JSON then return false, 'That sequence is too big to keep' end
    local by = Sanitize.string(GetPlayerName(src), 100, 'player ' .. src)
    local committed, err = Stores.runTransaction({ {
        query = 'INSERT INTO `whip_camera_sequences` (`name`, `data`, `updatedBy`) VALUES (?, ?, ?) '
            .. 'ON DUPLICATE KEY UPDATE `data` = VALUES(`data`), `updatedBy` = VALUES(`updatedBy`)',
        values = { name, text, by },
    } }, 'camera')
    if not committed then
        say('^1%s could not save the sequence %s: %s^0', by, name, tostring(err))
        return false, DB_ERROR
    end
    seqs[name] = { data = clean, by = by, at = os.time() }
    say('%s saved the camera sequence %s (%d keys, %.1f s)', by, name, #clean.keys, clean.length / 1000)
    -- Every player's copy of it is stale (client/camera.lua keeps one per name).
    TriggerClientEvent('whip_core:client:camseqChanged', -1, name)
    return clean
end

--- Forget a saved sequence. Answers true, or false and why.
function CameraSequences.delete(src, name)
    if not goodName(name) or not seqs[name] then return false, 'There is no sequence by that name' end
    local committed, err = Stores.runTransaction({ {
        query = 'DELETE FROM `whip_camera_sequences` WHERE `name` = ?', values = { name },
    } }, 'camera')
    if not committed then
        say('^1the sequence %s could not be deleted: %s^0', name, tostring(err))
        return false, DB_ERROR
    end
    seqs[name] = nil
    say('%s deleted the camera sequence %s', Sanitize.string(GetPlayerName(src), 100, 'player ' .. src), name)
    TriggerClientEvent('whip_core:client:camseqChanged', -1, name)
    return true
end

-- ---- The Camera Creator (admins) ----

SecureCallback('whip_core:camseq:list', { ace = DEVTOOLS, rateLimit = 500, burst = 5 }, function(source)
    return { list = CameraSequences.list(), mayEdit = Settings.mayEdit(source) }
end)

SecureCallback('whip_core:camseq:save', {
    ace = DEVTOOLS, rateLimit = 1000, burst = 3,
    params = { { 'name', 'string', 60 }, { 'data', 'any' } },
}, function(source, _, name, data)
    if not Settings.mayEdit(source) then return false, 'Only a permanent admin can save camera sequences' end
    local clean, why = CameraSequences.save(source, name, data)
    if not clean then return false, why end
    return { name = name, list = CameraSequences.list() }
end)

SecureCallback('whip_core:camseq:delete', {
    ace = DEVTOOLS, rateLimit = 1000, burst = 3,
    params = { { 'name', 'string', 60 } },
}, function(source, _, name)
    if not Settings.mayEdit(source) then return false, 'Only a permanent admin can delete camera sequences' end
    local ok, why = CameraSequences.delete(source, name)
    if not ok then return false, why end
    return { list = CameraSequences.list() }
end)

-- ---- Playing one (anyone: a script on their game asks for it by name) ----

SecureCallback('whip_core:camseq:fetch', {
    rateLimit = 250, burst = 8, whileDead = true,
    params = { { 'name', 'string', 60 } },
}, function(_, _, name)
    local data = CameraSequences.get(name)
    if not data then return false, 'There is no camera sequence called ' .. tostring(name) end
    return data
end)

--- A saved sequence by name (a copy), or nil: for a server script that hands one to a player.
exports('__GetCameraSequence', function(name) return CameraSequences.get(name) end)
