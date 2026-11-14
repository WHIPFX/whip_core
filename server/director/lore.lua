-- Lore characters: named NPCs the story keeps coming back to (the boss who hands out the jobs). Not a character
-- row: nobody plays one.
--   director_lore   key, name, ped model, bank name (what its payments are from; its name when empty), notes for
--                   whoever writes it, its bank account
-- A scenario's NPC can be one (its World def.lore). A card's `lore` field picks one; left empty it is the scenario's
-- own: the NPC that starts it, else its only lore NPC (DirectorLore.defaultOf).
-- Its bank account is owned by no character. Send Money pays the player from it as a transfer; the money is made on
-- the spot and the lore account's statement says so (Bank.SystemPayFrom).
-- Other resources: GetLoreCharacter, ListLoreCharacters, PayAsLore, and whip_core:lore:changed. Retiring one keeps
-- its records and takes it out of the pickers; saving it again brings it back.
-- Voice lines: director/lore_voice.lua.
-- Its look is made in the character editor: a freemode ped with a face, hair and clothes, checked by
-- SanitizeAppearanceData. Save keeps it with a headshot taken then, used as their face wherever they have no picture
-- link. Every game near the NPC puts the look on it (client/lore_reactions.lua), asking by key (whip_core:loreLook).

DirectorLore = { ready = false }

local CORE = GetCurrentResourceName()
local MAX_NOTES = 2000
local MAX_LOOK = 10000   -- an appearance as JSON, at most (a character's own save allows the same)
local PORTRAIT_PAGE = 20 -- the most headshots one ask answers (a few KB each), as server/portraits.lua

local chars = {}    -- [key] = row, retired ones too
local making = {}   -- [key] = true while its bank account is being made
local looks = {}    -- [key] = the look made in the character editor, when they have one (never in a copy: big)
local shotAt = {}   -- [key] = unix time their headshot was taken, when they have one

local function say(fmt, ...) print(('[whip_core:director] lore: ' .. fmt):format(...)) end

--- Who changed it, as its row keeps them: their name, 80 bytes at most (never half a character), or 'the server'.
local function byNameOf(v) return type(v) == 'string' and DirectorKit.cut(v, 80) or 'the server' end

local trim = DirectorKit.trim

function DirectorLore.validKey(key)
    return type(key) == 'string' and #key >= 2 and #key <= 64 and key:match('^[%w_%-]+$') ~= nil
end

-- ============================================
-- The table
-- ============================================

function DirectorLore.ensureTable()
    local ok = CreateTable('director_lore', [[
        CREATE TABLE IF NOT EXISTS `director_lore` (
            `loreKey`       VARCHAR(64)  NOT NULL,
            `name`          VARCHAR(80)  NOT NULL,
            `model`         VARCHAR(64)  NULL,
            `bankName`      VARCHAR(50)  NULL,
            `notes`         TEXT         NULL,
            `picture`       VARCHAR(255) NULL,
            `pictureFrame`  VARCHAR(32)  NULL,
            `voice`         TEXT         NULL,
            `props`         VARCHAR(64)  NULL,
            `look`          TEXT         NULL,
            `accountId`     INT UNSIGNED NULL,
            `createdByName` VARCHAR(80)  NULL,
            `updatedByName` VARCHAR(80)  NULL,
            `createdAt`     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `updatedAt`     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `retiredAt`     TIMESTAMP    NULL,
            PRIMARY KEY (`loreKey`),
            CONSTRAINT `fk_director_lore_account` FOREIGN KEY (`accountId`)
                REFERENCES `bank_accounts` (`accountId`) ON DELETE SET NULL
        )
    ]])
    if not ok then return false end
    -- Its headshot, in a table of its own as character_portraits is, so reading every lore character stays small.
    -- No foreign key: a lore character is retired, never deleted.
    return CreateTable('director_lore_portraits', [[
        CREATE TABLE IF NOT EXISTS `director_lore_portraits` (
            `loreKey`   VARCHAR(64) NOT NULL,
            `image`     MEDIUMTEXT  NOT NULL,
            `updatedAt` TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`loreKey`)
        )
    ]]) and true or false
end

-- ============================================
-- What its NPC wears on top (a hat): GTA puts no prop on a ped by itself
-- ============================================
--
-- { { anchor, drawable, texture }, ... }: anchor 0 is the head (a hat), 1 the eyes (glasses). Kept as
-- "0:3:1;1:0:0". Its NPC's owning game puts them on (client/lore_reactions.lua), so every game sees them.

local PROP_ANCHORS = { [0] = true, [1] = true, [2] = true, [6] = true, [7] = true }

--- A list as whip keeps it: known anchors, whole numbers in range, one per anchor. nil for none.
function DirectorLore.cleanProps(list)
    if type(list) ~= 'table' then return nil end
    local out, seen = {}, {}
    for _, p in ipairs(list) do
        local a, d, t = math.tointeger(tonumber(p.anchor)), math.tointeger(tonumber(p.drawable)), math.tointeger(tonumber(p.texture) or 0)
        if a and d and t and PROP_ANCHORS[a] and not seen[a] and d >= 0 and d <= 255 and t >= 0 and t <= 63 then
            seen[a] = true
            out[#out + 1] = { anchor = a, drawable = d, texture = t }
        end
    end
    return #out > 0 and out or nil
end

local function propsOf(s)
    if type(s) ~= 'string' or s == '' then return nil end
    local list = {}
    for a, d, t in s:gmatch('(%d+):(%d+):(%d+)') do list[#list + 1] = { anchor = a, drawable = d, texture = t } end
    return DirectorLore.cleanProps(list)
end

local function propsText(list)
    local parts = {}
    for _, p in ipairs(list or {}) do parts[#parts + 1] = ('%d:%d:%d'):format(p.anchor, p.drawable, p.texture) end
    return #parts > 0 and table.concat(parts, ';') or nil
end

-- ============================================
-- A picture's framing: what of it shows in the round frame
-- ============================================
--
-- { x, y, z }: x and y the point of the picture kept in view, 0-100 (% across and down; 50, 50 the middle), z the zoom,
-- 1-3. Drawn as object-position x% y% with a scale(z) about that same point: it never leaves a gap, whatever the
-- picture's shape. The same for lore characters and players' phones (whip_phone).

local function clamp(n, lo, hi, d)
    n = tonumber(n)
    if not n or n ~= n then return d end
    return math.max(lo, math.min(hi, n))
end

--- A framing as the rule takes it, or nil for none (the middle, unzoomed: nothing to keep).
function DirectorLore.cleanFrame(f)
    if type(f) ~= 'table' then return nil end
    local x = math.floor(clamp(f.x, 0, 100, 50) * 10 + 0.5) / 10
    local y = math.floor(clamp(f.y, 0, 100, 50) * 10 + 0.5) / 10
    local z = math.floor(clamp(f.z, 1, 3, 1) * 100 + 0.5) / 100
    if x == 50 and y == 50 and z == 1 then return nil end
    return { x = x, y = y, z = z }
end

local function frameOf(s)
    local x, y, z = tostring(s or ''):match('^([%d%.]+),([%d%.]+),([%d%.]+)$')
    return x and DirectorLore.cleanFrame({ x = x, y = y, z = z }) or nil
end

--- Its voice lines as kept (checked again on reading: a link start taken off the config list since goes quiet).
local function voiceOf(s)
    if type(s) ~= 'string' or s == '' or not DirectorLore.cleanVoice then return nil end
    local v = DirectorLore.cleanVoice(s)
    return v and next(v) and v or nil
end

--- The look as kept (checked again on reading, by the character save's own rules), or nil.
local function lookOf(s)
    if type(s) ~= 'string' or s == '' or not SanitizeAppearanceData then return nil end
    local ok, t = pcall(json.decode, s)
    if not ok or type(t) ~= 'table' then return nil end
    return (SanitizeAppearanceData(t))
end

local function rowOf(r)
    local look = lookOf(r.look)
    looks[r.loreKey] = look
    return {
        key = r.loreKey, name = r.name,
        -- A look's ped is always the one it was made on (a male or a female freemode ped).
        model = look and look.model or (r.model ~= '' and r.model or nil),
        -- lookV: which look it is (the games keep the one they have until it changes); shotAt: which headshot.
        hasLook = look ~= nil or nil, lookV = look and GetHashKey(r.look) or nil, portraitAt = shotAt[r.loreKey],
        bankName = r.bankName ~= '' and r.bankName or nil, notes = r.notes ~= '' and r.notes or nil,
        picture = type(r.picture) == 'string' and r.picture ~= '' and r.picture or nil,
        pictureFrame = frameOf(r.pictureFrame),
        voice = voiceOf(r.voice),
        props = propsOf(r.props),
        accountId = tonumber(r.accountId), retired = r.retiredAt ~= nil,
        -- updatedAt as the database gives it (milliseconds), as the hub's scenario rows carry theirs
        createdBy = r.createdByName, updatedBy = r.updatedByName, updatedAt = r.updatedAt,
    }
end

function DirectorLore.loadAll()
    -- Which have a headshot first (the rows carry when it was taken, not the picture).
    local pok, shots = pcall(MySQL.query.await, 'SELECT `loreKey`, UNIX_TIMESTAMP(`updatedAt`) AS `at` FROM `director_lore_portraits`')
    if pok and type(shots) == 'table' then
        shotAt = {}
        for _, s in ipairs(shots) do shotAt[s.loreKey] = tonumber(s.at) end
    end
    local ok, res = pcall(MySQL.query.await, 'SELECT * FROM `director_lore`')
    if not ok or type(res) ~= 'table' then return false, tostring(res) end
    looks = {}
    local fresh = {}
    for _, r in ipairs(res) do fresh[r.loreKey] = rowOf(r) end
    chars = fresh
    DirectorLore.ready = true
    return true
end

-- ============================================
-- Reading
-- ============================================

--- A copy for anyone outside: { key, name, model, bankName, notes, retired, ... }, or nil.
local function view(c)
    if not c then return nil end
    local out = {}
    for k, v in pairs(c) do out[k] = v end
    out.payName = c.bankName or c.name
    return out
end

--- A lore character by key (a retired one too), as a copy, or nil.
function DirectorLore.get(key)
    return view(chars[key])
end

--- Is this a lore character that is in use (not retired)?
function DirectorLore.isLive(key)
    local c = type(key) == 'string' and chars[key] or nil
    return c ~= nil and not c.retired
end

--- Every lore character, by name. `withRetired`: the retired ones as well.
function DirectorLore.list(withRetired)
    local out = {}
    for _, c in pairs(chars) do
        if withRetired or not c.retired then out[#out + 1] = view(c) end
    end
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    return out
end

-- ---- a scenario's own lore character ----

local function loreOf(w)
    local d = type(w) == 'table' and w.kind == 'npc' and type(w.def) == 'table' and w.def or nil
    local key = d and d.lore
    return DirectorLore.isLive(key) and key or nil
end

--- A world thing by id, from a document (a list) or a compiled graph (a map).
local function worldThing(world, id)
    if type(world) ~= 'table' or id == nil then return nil end
    if world[id] ~= nil then return world[id] end
    for _, w in ipairs(world) do
        if type(w) == 'table' and w.id == id then return w end
    end
    return nil
end

--- The lore character an empty `lore` field means: the NPC that starts the scenario, when it is one, else the
--- one lore character among its NPCs. nil when there is none, or more than one and none starts it.
function DirectorLore.defaultOf(graph)
    if type(graph) ~= 'table' or type(graph.world) ~= 'table' then return nil end
    local settings = type(graph.settings) == 'table' and graph.settings or {}
    local start = type(settings.start) == 'table' and settings.start or nil
    local key = start and loreOf(worldThing(graph.world, start.world))
    if key then return key end
    local only
    for _, w in pairs(graph.world) do
        local k = loreOf(w)
        if k then
            if only and only ~= k then return nil end
            only = k
        end
    end
    return only
end

-- ============================================
-- Writing (the hub's Lore list: a builder saves, an admin retires)
-- ============================================

local function changed(key)
    local c = chars[key]
    WhipEmit('whip_core:lore:changed', { key = key, character = view(c), retired = c == nil or c.retired })
end

--- The link starts a picture may have (Config.LorePictureLinks), each 'https://' + a site + '/'. One without its
--- '/' after the site is ignored: 'https://r2.fivemanage.com' would also let 'https://r2.fivemanage.com.evil.io/' in.
function DirectorLore.pictureLinks()
    local out = {}
    for _, start in ipairs(type(Config.LorePictureLinks) == 'table' and Config.LorePictureLinks or {}) do
        if type(start) == 'string' and start:match('^https://[%w%-]+%.[%w%-%.]+/[%w%-%._/]*$') then out[#out + 1] = start end
    end
    return out
end

--- Why a picture link is refused, or nil. Every player's game loads it, so it must start with one of the accepted
--- link starts and be a plain address after it (letters, digits, - . _ /): no query, no spaces, nothing that
--- could break out of the picture's tag.
function DirectorLore.pictureProblem(url)
    if url == '' then return nil end
    if #url > 255 then return 'A picture link is at most 255 characters' end
    local starts = DirectorLore.pictureLinks()
    if #starts == 0 then return 'Pictures are switched off (Config: Picture links accepted)' end
    for _, start in ipairs(starts) do
        if url:sub(1, #start) == start then
            local rest = url:sub(#start + 1)
            if rest == '' or not rest:match('^[%w%-%._/]+$') or rest:find('..', 1, true) then
                return 'That link is not a picture\'s address'
            end
            return nil
        end
    end
    return ('Only links starting with %s are accepted'):format(table.concat(starts, ' or '))
end

--- Make or change a lore character. Answers its copy, or nil and why.
---@param key string
---@param f table  { name, model, bankName, notes, picture, pictureFrame = { x, y, z }, voice }
---   voice: its voice lines (JSON text or a table, director/lore_voice.lua); nil or '' leaves them as they are
---@param byName string|nil  who did it
function DirectorLore.save(key, f, byName)
    if not DirectorLore.ready then return nil, 'Lore characters are not loaded' end
    if not DirectorLore.validKey(key) then return nil, 'A key is 2 to 64 letters, digits, _ or -' end
    f = type(f) == 'table' and f or {}
    local name = trim(f.name)
    if name == '' or #name > 80 then return nil, 'A name is 1 to 80 characters' end
    local model = trim(f.model)
    if #model > 64 or (model ~= '' and not model:match('^[%w_]+$')) then return nil, 'A ped model is its spawn name (letters, digits, _)' end
    -- One with a look made in the character editor keeps that look's ped (Use a GTA ped takes the look away first).
    if looks[key] then model = looks[key].model end
    local bankName = trim(f.bankName)
    if #bankName > 50 then return nil, 'A bank name is at most 50 characters' end
    local notes = trim(f.notes)
    if #notes > MAX_NOTES then return nil, ('Notes are at most %d characters'):format(MAX_NOTES) end
    local picture = trim(f.picture)
    local bad = DirectorLore.pictureProblem(picture)
    if bad then return nil, bad end
    local voice
    if f.voice ~= nil and f.voice ~= '' then
        local vwhy
        voice, vwhy = DirectorLore.cleanVoice(f.voice)
        if not voice then return nil, vwhy end
    end
    byName = byNameOf(byName)

    -- The framing goes with its picture: none without one.
    local frame = picture ~= '' and DirectorLore.cleanFrame(f.pictureFrame) or nil

    -- Positions written out: an empty field is nil, and # of a list with holes is not its length.
    local values = { key, name, model ~= '' and model or nil, bankName ~= '' and bankName or nil, notes ~= '' and notes or nil,
                     picture ~= '' and picture or nil, frame and ('%g,%g,%g'):format(frame.x, frame.y, frame.z) or nil }
    local cols, marks, sets, n = '', '', '', 7
    -- Voice lines only when given: a form that sends none leaves them as they are.
    if voice then
        n = n + 1; values[n] = next(voice) and json.encode(voice) or nil
        cols, marks, sets = ', `voice`', ', ?', ', `voice` = VALUES(`voice`)'
    end
    values[n + 1], values[n + 2] = byName, byName
    local ok, err = pcall(MySQL.query.await, ([[
        INSERT INTO `director_lore` (`loreKey`, `name`, `model`, `bankName`, `notes`, `picture`, `pictureFrame`%s,
            `createdByName`, `updatedByName`)
        VALUES (?, ?, ?, ?, ?, ?, ?%s, ?, ?)
        ON DUPLICATE KEY UPDATE `name` = VALUES(`name`), `model` = VALUES(`model`), `bankName` = VALUES(`bankName`),
            `notes` = VALUES(`notes`), `picture` = VALUES(`picture`), `pictureFrame` = VALUES(`pictureFrame`)%s,
            `updatedByName` = VALUES(`updatedByName`), `updatedAt` = CURRENT_TIMESTAMP,
            `retiredAt` = NULL]]):format(cols, marks, sets), values)
    if not ok then
        say('^1saving %s failed: %s^0', key, tostring(err))
        return nil, 'The database refused it'
    end
    local rok, r = pcall(MySQL.single.await, 'SELECT * FROM `director_lore` WHERE `loreKey` = ?', { key })
    if not rok or not r then return nil, 'Saved, but it could not be read back' end
    local old = chars[key]
    chars[key] = rowOf(r)
    -- Its account follows its bank name.
    local c = chars[key]
    if c.accountId and (not old or (old.bankName or old.name) ~= (c.bankName or c.name)) then
        Bank.SetLabel(c.accountId, DirectorKit.cut(c.bankName or c.name, 50))
    end
    changed(key)
    return view(c)
end

--- Retire a lore character: out of the pickers, its records kept. Answers true, or false and why.
function DirectorLore.retire(key, byName)
    local c = chars[key]
    if not c then return false, 'No lore character called ' .. tostring(key) end
    if c.retired then return true end
    local ok, err = pcall(MySQL.update.await,
        'UPDATE `director_lore` SET `retiredAt` = CURRENT_TIMESTAMP, `updatedByName` = ?, `updatedAt` = CURRENT_TIMESTAMP WHERE `loreKey` = ?',
        { byNameOf(byName), key })
    if not ok then
        say('^1retiring %s failed: %s^0', key, tostring(err))
        return false, 'The database refused it'
    end
    c.retired = true
    changed(key)
    return true
end

--- What its NPC wears on top (DirectorLore.cleanProps' list; nil or {} for nothing). true, or false and why.
function DirectorLore.setProps(key, list, byName)
    local c = chars[key]
    if not c then return false, 'No lore character called ' .. tostring(key) end
    local clean = DirectorLore.cleanProps(list)
    byName = byNameOf(byName)
    -- None is a literal NULL (a nil in the params would shift the rest).
    local sql = clean and 'UPDATE `director_lore` SET `props` = ?, `updatedByName` = ?, `updatedAt` = CURRENT_TIMESTAMP WHERE `loreKey` = ?'
        or 'UPDATE `director_lore` SET `props` = NULL, `updatedByName` = ?, `updatedAt` = CURRENT_TIMESTAMP WHERE `loreKey` = ?'
    local values = clean and { propsText(clean), byName, key } or { byName, key }
    local ok, err = pcall(MySQL.update.await, sql, values)
    if not ok then
        say('^1saving %s\'s hat failed: %s^0', key, tostring(err))
        return false, 'The database refused it'
    end
    c.props, c.updatedBy = clean, byName
    changed(key)
    return true
end

-- ============================================
-- Its look, made in the character editor, and its headshot
-- ============================================

--- Their look made in the character editor (an appearance, a copy), or nil for a GTA ped.
function DirectorLore.lookOf(key)
    local look = looks[key]
    return look and json.decode(json.encode(look)) or nil
end

--- Give them a look made in the character editor, with the headshot taken of it (a picture as server/portraits.lua
--- keeps one; '' for none, which takes an old one away: it shows the old look). `look` nil takes the look and its
--- headshot away (Use a GTA ped): their ped stays as it was until it is changed. true, or false and why.
function DirectorLore.setLook(key, look, image, byName)
    local c = chars[key]
    if not c then return false, 'No lore character called ' .. tostring(key) end
    if not SanitizeAppearanceData then return false, 'Looks cannot be checked here' end
    byName = byNameOf(byName)
    local clean, text
    if look ~= nil then
        local eok, enc = pcall(json.encode, look)
        if not eok or type(enc) ~= 'string' or #enc > MAX_LOOK then return false, 'That look is too big to keep' end
        local why
        clean, why = SanitizeAppearanceData(look)
        if not clean then return false, 'That look was refused: ' .. tostring(why) end
        text = json.encode(clean)
    end
    image = type(image) == 'string' and image or ''
    if image ~= '' and not (Portraits and Portraits.isPicture and Portraits.isPicture(image)) then image = '' end

    local ok, err
    if clean then
        ok, err = pcall(MySQL.update.await, [[UPDATE `director_lore` SET `look` = ?, `model` = ?, `updatedByName` = ?,
            `updatedAt` = CURRENT_TIMESTAMP WHERE `loreKey` = ?]], { text, clean.model, byName, key })
    else
        ok, err = pcall(MySQL.update.await, [[UPDATE `director_lore` SET `look` = NULL, `updatedByName` = ?,
            `updatedAt` = CURRENT_TIMESTAMP WHERE `loreKey` = ?]], { byName, key })
    end
    if not ok then
        say('^1saving %s\'s look failed: %s^0', key, tostring(err))
        return false, 'The database refused it'
    end

    -- The headshot follows the look. Its time is which one it is (pages keep the one they have until it moves),
    -- so it always moves on, even twice in a second.
    if image ~= '' then
        local pok, perr = pcall(MySQL.query.await, [[INSERT INTO `director_lore_portraits` (`loreKey`, `image`) VALUES (?, ?)
            ON DUPLICATE KEY UPDATE `image` = VALUES(`image`), `updatedAt` = CURRENT_TIMESTAMP]], { key, image })
        if pok then shotAt[key] = math.max(os.time(), (shotAt[key] or 0) + 1)
        else say('^3%s\'s headshot was not saved: %s^0', key, tostring(perr)) end
    elseif shotAt[key] then
        local pok = pcall(MySQL.update.await, 'DELETE FROM `director_lore_portraits` WHERE `loreKey` = ?', { key })
        if pok then shotAt[key] = nil end
    end

    local rok, r = pcall(MySQL.single.await, 'SELECT * FROM `director_lore` WHERE `loreKey` = ?', { key })
    if rok and r then
        chars[key] = rowOf(r)
    else
        -- Saved, but not read back: what was written, by hand.
        looks[key] = clean
        c.hasLook, c.lookV, c.portraitAt = clean and true or nil, clean and GetHashKey(text) or nil, shotAt[key]
        if clean then c.model = clean.model end
    end
    changed(key)
    return true
end

-- The builder's game sends the look it made (the character editor's Save; tools/panel_sections/director.lua) with
-- the headshot it took of it, or the Lore page sends 'none' to take the look away (Use a GTA ped).
SecureCallback('whip_core:director:loreLook', {
    permission = 'director.build', whileDead = true, rateLimit = 2000, burst = 2,
    params = { { 'key', 'key', 64 }, { 'look', 'any' }, { 'image', 'string', (Portraits and Portraits.MAX_LEN or 65536) + 1, '' } },
}, function(_, player, key, look, image)
    if look == 'none' then look = nil
    elseif type(look) ~= 'table' then return false, 'No look was sent' end
    local ok, why = DirectorLore.setLook(key, look, image, player and player.fullName or nil)
    if not ok then return false, why end
    local c = chars[key]
    return { character = view(c), portrait = c and c.portraitAt ~= nil }
end)

-- Their headshots, for the pages that show their faces (the Lore page, the Director's pickers and maps):
-- { portraits = { [key] = dataUrl } }, a page of them at a time. One without a headshot is left out.
SecureCallback('whip_core:director:lorePortraits', {
    permission = 'director.build', whileDead = true, rateLimit = 300, burst = 6,
    params = { { 'keys', 'any' } },
}, function(_, _, keys)
    if type(keys) ~= 'table' then return { portraits = {} } end
    local list, seen = {}, {}
    for _, k in ipairs(keys) do
        if type(k) == 'string' and shotAt[k] and not seen[k] then
            seen[k] = true
            list[#list + 1] = k
            if #list >= PORTRAIT_PAGE then break end
        end
    end
    if #list == 0 then return { portraits = {} } end
    local ok, rows = pcall(MySQL.query.await, 'SELECT `loreKey`, `image` FROM `director_lore_portraits` WHERE `loreKey` IN ('
        .. string.rep('?', #list, ',') .. ')', list)
    if not ok then return false, 'The headshots could not be read' end
    local out = {}
    for _, r in ipairs(rows or {}) do out[r.loreKey] = r.image end
    return { portraits = out }
end)

-- Their look, for any game that has their NPC near (client/lore_reactions.lua puts it on): { look, v } or {} for
-- none. Nothing in it is private: it is what everyone near sees.
SecureCallback('whip_core:loreLook', {
    whileDead = true, rateLimit = 250, burst = 8,
    params = { { 'key', 'key', 64 } },
}, function(_, _, key)
    local c, look = chars[key], looks[key]
    if not c or not look then return {} end
    return { look = look, v = c.lookV }
end)

-- ============================================
-- Money
-- ============================================

--- Its bank account's id, made the first time it is needed. nil and why when it cannot be.
function DirectorLore.account(key)
    local c = chars[key]
    if not c then return nil, 'No lore character called ' .. tostring(key) end
    -- One maker at a time: a second payment waits for the first's account.
    local deadline = GetGameTimer() + 5000
    while making[key] and GetGameTimer() < deadline do Wait(50) end
    if c.accountId and Bank.GetAccount(c.accountId) then return c.accountId end
    making[key] = true
    local acc, why = Bank.CreateAccount(nil, DirectorKit.cut(c.bankName or c.name, 50), 'personal', false, nil)
    if acc then
        local ok = pcall(MySQL.update.await, 'UPDATE `director_lore` SET `accountId` = ? WHERE `loreKey` = ?', { acc.accountId, key })
        if not ok then say('^3%s\'s account %s was made but not written down^0', key, tostring(acc.accountId)) end
        c.accountId = acc.accountId
    end
    making[key] = nil
    if not acc then return nil, why or 'Its bank account could not be made' end
    return acc.accountId
end

--- A lore character pays a player into their bank: a transfer from its own account, the money made on the spot.
---@param key string
---@param who number|table  a server id, or { charId = n }
---@param amount number
---@param message string|nil  on both statements
---@param madeNote string|nil  on the lore account's statement: where the money came from
---@return boolean ok
---@return string|nil why
function DirectorLore.pay(key, who, amount, message, madeNote)
    if not DirectorLore.isLive(key) then return false, 'No lore character called ' .. tostring(key) end
    local charId, src = WhoIs(who)
    if not charId then return false, src --[[@as string|nil]] or 'No such player' end
    local to, readErr = Bank.GetDefaultAccount(charId)
    if not to then return false, readErr and 'The bank could not be reached' or 'They have no bank account' end
    local from, why = DirectorLore.account(key)
    if not from then return false, why end
    return Bank.SystemPayFrom(from, to.accountId, amount, message, madeNote)
end

-- ============================================
-- The cards
-- ============================================

local define = DirectorKit.define

define({
    type = 'lore.pay', v = 1, category = 'lore', title = 'Send Money', giveUp = 15, handsOut = true,
    haggle = { key = 'amount', toPlayer = true, unit = 'money' },   -- (a Haggle can agree its amount: nodes_talk.lua)
    desc = 'A lore character pays the player into their bank. A test pays nothing.',
    outputs = { 'paid', 'failed', 'timeout' },
    latent = true, yields = true,
    props = {
        { key = 'lore', kind = 'lore', label = 'From' },
        { key = 'amount', kind = 'number', label = 'Amount ($)', default = 500, min = 1, max = 1000000 },
        { key = 'message', kind = 'text', label = 'Message', maxLength = 100, default = 'For the job' },
    },
    run = function(ctx)
        local run = ctx.run
        local src = Director.playerOf(ctx)
        if not src then return 'failed' end
        local key = ctx:prop('lore')
        local amount = math.floor(tonumber(ctx:prop('amount')) or 0)
        local message = ctx:prop('message')
        local data = { source = src }
        if not DirectorLore.isLive(key) then
            ctx:log('Send Money: no lore character (pick one, or make the NPC that starts the scenario one)')
            return 'failed'
        end
        local c = chars[key]
        ctx:call(function()
            -- (The run's way, from the lore character's own account: effects.lua.)
            local ok, why = DirectorEffects.pay(run, ctx.node.id, src, amount, {
                testSays = ('Test: %s would send you $%d'):format(c.bankName or c.name, amount),
                detail = ('$%d from %s'):format(amount, key),
                send = function()
                    return DirectorLore.pay(key, src, amount, message, ('Made by the Director: %s run %d'):format(tostring(run.scenarioId), run.id))
                end,
            })
            if not ok then
                ctx:log('Send Money %s -> %s $%d: %s', key, tostring(src), amount, tostring(why))
                return 'failed', data
            end
            return 'paid', data
        end, { late = DirectorEffects.latePay(run, ctx.node.id, src, amount, 'Send Money') })        return nil
    end,
})

-- ============================================
-- What a lore character is part of (the Lore page's Interactions tab, html/js/wp/lore.js)
-- ============================================

local RECENT_PAYMENTS = 8

--- Where `key` is used in one scenario document: as an NPC (by its label), and by each card with a `lore` field
--- naming them (an empty one means the scenario's own: DirectorLore.defaultOf). { { what, n } }, first met first.
local function usesIn(doc, key)
    local out, at = {}, {}
    local function add(what)
        if at[what] then out[at[what]].n = out[at[what]].n + 1 return end
        out[#out + 1] = { what = what, n = 1 }
        at[what] = #out
    end
    -- Every variant's (a thing every variant shares, and a card copied into another, once).
    local seenThing, seenCard = {}, {}
    for _, vr in ipairs(DirectorGraph.variantsOf(doc)) do
        local vd = vr.doc
        for _, w in ipairs(type(vd.world) == 'table' and vd.world or {}) do
            local d = type(w) == 'table' and not seenThing[w.id] and w.kind == 'npc' and type(w.def) == 'table' and w.def or nil
            if type(w) == 'table' then seenThing[w.id] = true end
            if d and d.lore == key then add('Their NPC') end
        end
        local own
        for _, n in ipairs(type(vd.nodes) == 'table' and vd.nodes or {}) do
            local def = type(n) == 'table' and not seenCard[n.id] and DirectorNodes.get(n.type)
            if def then seenCard[n.id] = true end
            local props = def and type(n.props) == 'table' and n.props or {}
            for _, f in ipairs(def and def.props or {}) do
                if f.kind == 'lore' then
                    local v = props[f.key]
                    if v == nil or v == '' then
                        if own == nil then own = DirectorLore.defaultOf(vd) or false end
                        v = own
                    end
                    if v == key then add(tostring(def and def.title or n.type)) end
                end
            end
        end
    end
    return out
end

--- Every scenario whose draft uses `key`: { { key, name, on, uses } }, by name. nil and why when unread.
local function scenariosUsing(key)
    local ok, rows = pcall(MySQL.query.await, [[SELECT s.`key`, s.`name`, r.`doc` FROM `director_scenarios` s
        JOIN `director_revisions` r ON r.`scenarioId` = s.`id` AND r.`rev` = s.`draftRev`
        WHERE s.`deletedAt` IS NULL]])
    if not ok or type(rows) ~= 'table' then return nil, 'The scenarios could not be read' end
    local out = {}
    for _, r in ipairs(rows) do
        local dok, doc = pcall(json.decode, r.doc)
        if dok and type(doc) == 'table' then
            local uses = usesIn(doc, key)
            if #uses > 0 then
                out[#out + 1] = { key = r.key, name = r.name, on = Director.active[r.key] ~= nil, uses = uses }
            end
        end
    end
    table.sort(out, function(a, b) return tostring(a.name):lower() < tostring(b.name):lower() end)
    return out
end
-- The Director's Overview filters by it (hub.lua): one database read of every draft, so ask once per answer.
DirectorLore.scenariosUsing = scenariosUsing

--- Their phone (a phone resource gives each one a number: whip_phone's phone_numbers.loreKey): the number, and
--- the texts and calls to and from it. nil when they have none, or the phone tables are not there.
local function phoneOf(key)
    local ok, rows = pcall(MySQL.query.await, 'SELECT * FROM `phone_numbers` WHERE `loreKey` = ?', { key })
    if not ok or type(rows) ~= 'table' then return nil end
    local number
    for _, r in ipairs(rows) do
        if r.retiredAt == nil then number = r.phoneNumber break end
    end
    if not number then return nil end
    local p = { number = number }
    local tok, t = pcall(MySQL.single.await, [[SELECT SUM(`senderNumber` = ?) AS `sent`, SUM(`receiverNumber` = ?) AS `got`,
            COUNT(DISTINCT IF(`senderNumber` = ?, `receiverNumber`, `senderNumber`)) AS `people`,
            MAX(UNIX_TIMESTAMP(`createdAt`)) AS `lastAt`
        FROM `phone_messages` WHERE `senderNumber` = ? OR `receiverNumber` = ?]], { number, number, number, number, number })
    if tok and t then
        p.texts = { sent = tonumber(t.sent) or 0, received = tonumber(t.got) or 0, people = tonumber(t.people) or 0,
                    lastAt = tonumber(t.lastAt) }
    end
    local cok, c = pcall(MySQL.single.await, [[SELECT SUM(`callerNumber` = ?) AS `made`, SUM(`calleeNumber` = ?) AS `got`,
            SUM(`calleeNumber` = ? AND `status` = 'answered') AS `answered`, MAX(UNIX_TIMESTAMP(`startedAt`)) AS `lastAt`
        FROM `phone_calls` WHERE `callerNumber` = ? OR `calleeNumber` = ?]], { number, number, number, number, number })
    if cok and c then
        p.calls = { made = tonumber(c.made) or 0, received = tonumber(c.got) or 0, answered = tonumber(c.answered) or 0,
                    lastAt = tonumber(c.lastAt) }
    end
    return p
end

--- What they have paid players from their account: how many payments, the total, to how many people, and the
--- newest few (who to, how much, the message). nil before their first payment made their account.
local function paymentsOf(c)
    if not c.accountId then return nil end
    local ok, t = pcall(MySQL.single.await, [[SELECT COUNT(*) AS `n`, COALESCE(SUM(`amount`), 0) AS `total`,
            COUNT(DISTINCT `toAccountId`) AS `people`, MAX(UNIX_TIMESTAMP(`createdAt`)) AS `lastAt`
        FROM `bank_transactions` WHERE `fromAccountId` = ?]], { c.accountId })
    if not ok or not t then return nil end
    local out = { n = tonumber(t.n) or 0, total = tonumber(t.total) or 0, people = tonumber(t.people) or 0,
                  lastAt = tonumber(t.lastAt), recent = {} }
    local rok, rows = pcall(MySQL.query.await, [[SELECT t.`amount`, t.`message`, UNIX_TIMESTAMP(t.`createdAt`) AS `at`,
            a.`label`, ch.`firstName`, ch.`lastName`
        FROM `bank_transactions` t
        LEFT JOIN `bank_accounts` a ON a.`accountId` = t.`toAccountId`
        LEFT JOIN `characters` ch ON ch.`charId` = a.`ownerCharId`
        WHERE t.`fromAccountId` = ? ORDER BY t.`txId` DESC LIMIT ?]], { c.accountId, RECENT_PAYMENTS })
    for _, r in ipairs(rok and rows or {}) do
        local who = r.firstName and (r.firstName .. ' ' .. (r.lastName or '')) or r.label or 'An account'
        out.recent[#out.recent + 1] = { amount = tonumber(r.amount) or 0, message = r.message, at = tonumber(r.at),
                                        to = trim(who) }
    end
    return out
end

-- Their hat (the Lore page's Details): hat -1 is none, else the ped's hat number (prop 0 on the head) and its texture.
-- What they wear elsewhere (glasses, set by a script) is left as it is.
SecureCallback('whip_core:director:loreProps', {
    permission = 'director.build', whileDead = true, rateLimit = 500, burst = 3,
    params = { { 'key', 'key', 64 }, { 'hat', 'int', -1, 255, -1 }, { 'hatTexture', 'int', 0, 63, 0 } },
}, function(_, player, key, hat, hatTexture)
    local c = chars[key]
    if not c then return false, 'No lore character called ' .. tostring(key) end
    local list = {}
    if hat >= 0 then list[1] = { anchor = 0, drawable = hat, texture = hatTexture } end
    for _, p in ipairs(c.props or {}) do
        if p.anchor ~= 0 then list[#list + 1] = p end
    end
    local ok, why = DirectorLore.setProps(key, list, player and player.fullName or nil)
    if not ok then return false, why end
    return { props = chars[key].props or {} }
end)

-- Times are unix seconds. Read only, so a builder may (the Lore page is a builder's).
SecureCallback('whip_core:director:loreActivity', {
    permission = 'director.build', whileDead = true, rateLimit = 500, burst = 3,
    params = { { 'key', 'key', 64 } },
}, function(_, _, key)
    local c = chars[key]
    if not c then return false, 'No lore character called ' .. tostring(key) end
    local scenarios, why = scenariosUsing(key)
    return { scenarios = scenarios or {}, scenariosWhy = why, phone = phoneOf(key), payments = paymentsOf(c) }
end)

-- ============================================
-- Exports
-- ============================================

--- A lore character: { key, name, model, bankName, payName, notes, picture, pictureFrame, retired, accountId, hasLook
--- (made in the character editor), portraitAt (when its headshot was taken, if it has one) }, or nil.
exports('GetLoreCharacter', function(key)
    return DirectorLore.get(key)
end)

--- A profile picture as whip takes one, for a resource that keeps its own (whip_phone: a player's contact card):
--- the link on the accepted sites (Config.LorePictureLinks), and its framing cleaned. `true, frame` (frame nil for
--- none) or `false, why`. An empty link is no picture: `true, nil`.
exports('CheckPicture', function(url, frame)
    url = type(url) == 'string' and trim(url) or ''
    if url == '' then return true, nil end
    local bad = DirectorLore.pictureProblem(url)
    if bad then return false, bad end
    return true, DirectorLore.cleanFrame(frame)
end)

--- Every lore character in use, by name (`withRetired`: the retired ones too).
exports('ListLoreCharacters', function(withRetired)
    return DirectorLore.list(withRetired == true)
end)

--- A lore character pays a player into their bank, as a transfer from its own account (money made on the spot).
---
---     exports.whip_core:PayAsLore('irwin', source, 500, { message = 'For the drop' })
---
--- `true`, or `false, why`.
exports('PayAsLore', function(key, who, amount, opts)
    local owner = Registry.caller()   -- first, before anything can yield
    opts = type(opts) == 'table' and opts or {}
    local message = type(opts.message) == 'string' and DirectorKit.cut(opts.message, 100) or nil
    return DirectorLore.pay(key, who, amount, message, ('Made by %s'):format(tostring(owner or CORE)))
end)
