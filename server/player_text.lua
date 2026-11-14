-- ============================================
-- Player text — the instruction band, from the server
-- ============================================
--
-- The band at the bottom (or top) of the screen that ShowText puts up on the client ("Take the
-- package to the docks"), shown from SERVER code: an objective for a run's players, a step of a job.
-- The client's rule holds here too: one band per player, a new one takes it over, and a resource
-- can only take down its own.
--
--   exports.whip_core:ShowPlayerText(source, 'Take the package to the docks', { position = 'bottom', tag = 'run:42' })
--   exports.whip_core:ShowPlayerText(source, 'Get out before the alarm', { countdown = 90 })   -- '... · 1:30'
--   exports.whip_core:HidePlayerText(source)
--
-- Yours: taken down when your resource stops, when your run's tag is released, and when the player
-- logs out. Text only (the page escapes it); colour codes are removed, at most 200 characters.
--
-- A countdown (the Director's Countdown and Goal cards): `countdown = seconds` puts a
-- clock after the text that the player's game counts down itself, a second at a time, with the
-- band's fill draining as it goes (from `countdownTotal` seconds, when the clock started earlier).
-- It is said once, never sent every second; at 0:00 it stops and stays until the text changes.
--
-- Objectives are not on the band: PlayerText.objective puts
-- a job's objective on a card of its own at the top right (html/js/ui.js §10): its words, the job's
-- name and its clock. The band stays what the player is doing this moment — placing, giving, a door —
-- and the two never take each other's place. One card per owner per `id` (a run's tag), so two jobs
-- are two cards; each goes like the band does: taken down, its tag released, its owner stopped, the
-- player logged out.

PlayerText = {}

local MAX_LEN = 200
local MAX_COUNTDOWN = 7 * 24 * 3600   -- a week, as long as a Director wait
local shown = {}   -- [source] = the record on their screen

local function hide(rec)
    if shown[rec.source] ~= rec then return end
    shown[rec.source] = nil
    TriggerClientEvent('whip_core:client:playerText', rec.source, false)
end

local reg = Registry.new('playerText', {
    label = 'player text',
    scoped = true,
    releaseOrder = 10,
    same = false,
    onRemove = function(_, rec) hide(rec) end,
})

--- Put the band up for a player. Answers true, or false and why.
---@param owner string  Registry.caller()
---@param source number
---@param text string
---@param opts table|nil { position = 'bottom'|'top', progress = 0-100, countdown = seconds,
---                       countdownTotal = seconds (the fill's full length; default countdown), tag }
function PlayerText.show(owner, source, text, opts)
    opts = type(opts) == 'table' and opts or {}
    local src = Sanitize.id(source)
    local player = src and Players[src]
    if not src or not player or not player.charId then return false, 'no such player' end
    if type(text) ~= 'string' then return false, 'text is text' end
    local clean = BubbleText.clean(text, MAX_LEN)
    if clean == '' then return false, 'text is empty' end
    local position = opts.position or 'bottom'
    if position ~= 'bottom' and position ~= 'top' then return false, "position is 'bottom' or 'top'" end
    local progress = nil
    if opts.progress ~= nil then
        progress = tonumber(opts.progress)
        if not progress or progress ~= progress then return false, 'progress is a number, 0-100' end
        progress = math.max(0, math.min(100, progress))
    end
    local timer = nil
    if opts.countdown ~= nil then
        local left = tonumber(opts.countdown)
        if not left or left ~= left or left < 0 or left > MAX_COUNTDOWN then
            return false, ('countdown is a number of seconds, 0-%d'):format(MAX_COUNTDOWN)
        end
        local total = opts.countdownTotal ~= nil and tonumber(opts.countdownTotal) or left
        if not total or total ~= total or total < 0 or total > MAX_COUNTDOWN then
            return false, ('countdownTotal is a number of seconds, 0-%d'):format(MAX_COUNTDOWN)
        end
        timer = { left = math.floor(left * 1000), total = math.floor(math.max(total, left) * 1000) }
    end

    -- Whoever had the band loses it (theirs goes without a hide: this one replaces it on screen).
    local old = shown[src]
    if old then
        shown[src] = nil
        reg:remove(old.owner, src)
    end
    local rec = { source = src, owner = owner, text = clean, position = position, progress = progress, tag = opts.tag,
                  endsAt = timer and (GetGameTimer() + timer.left) or nil }
    local ok, why = reg:add(owner, src, rec, opts.tag ~= nil and { tag = opts.tag } or nil)
    if not ok then return false, why end
    shown[src] = rec
    TriggerClientEvent('whip_core:client:playerText', src, clean, position, progress, timer)
    return true
end

--- Take the band down, if it is the owner's. Answers true, or false and why.
function PlayerText.hide(owner, source)
    local src = Sanitize.id(source)
    local rec = src and shown[src]
    if not src or not rec then return false, 'nothing is shown' end
    if rec.owner ~= owner then return false, ('the text on screen is %s\'s'):format(tostring(rec.owner)) end
    return reg:remove(owner, src)
end

--- What a player's band says right now, and whose it is: { owner, text, position, progress, tag,
--- countdown = seconds left } or nil.
function PlayerText.get(source)
    local rec = shown[Sanitize.id(source) or -1]
    if not rec then return nil end
    return { owner = rec.owner, text = rec.text, position = rec.position, progress = rec.progress, tag = rec.tag,
             countdown = rec.endsAt and math.max(0, (rec.endsAt - GetGameTimer()) / 1000) or nil }
end

-- ============================================
-- Objectives: the tracker at the top right
-- ============================================

local cards = {}   -- [source] = { [cardId] = record }, cardId = '<owner>:<id>' (the page's name for it)

local function hideCard(rec)
    local mine = cards[rec.source]
    if not mine or mine[rec.cardId] ~= rec then return end
    mine[rec.cardId] = nil
    if next(mine) == nil then cards[rec.source] = nil end
    TriggerClientEvent('whip_core:client:objective', rec.source, rec.cardId, false)
end

local cardReg = Registry.new('playerObjective', {
    label = 'objective',
    scoped = true,
    releaseOrder = 10,
    same = false,
    onRemove = function(_, rec) hideCard(rec) end,
})

local function cardKey(src, id) return tostring(src) .. '|' .. id end

--- A seconds countdown as the page wants it ({ left, total } in ms), or nil and why.
local function timerOf(countdown, countdownTotal)
    if countdown == nil then return nil end
    local left = tonumber(countdown)
    if not left or left ~= left or left < 0 or left > MAX_COUNTDOWN then
        return nil, ('countdown is a number of seconds, 0-%d'):format(MAX_COUNTDOWN)
    end
    local total = countdownTotal ~= nil and tonumber(countdownTotal) or left
    if not total or total ~= total or total < 0 or total > MAX_COUNTDOWN then
        return nil, ('countdownTotal is a number of seconds, 0-%d'):format(MAX_COUNTDOWN)
    end
    return { left = math.floor(left * 1000), total = math.floor(math.max(total, left) * 1000) }
end

--- Put an objective card up for a player, or change the one `id` names. Answers true, or false and why.
---@param owner string  Registry.caller()
---@param source number
---@param id string  the card's name for its owner (the Director: the run's tag)
---@param text string  what to do ("Get to the docks")
---@param opts table|nil { name = the job's name, countdown = seconds, countdownTotal = seconds, tag, icon = a glyph's key
---  (html/js/glyphs.js; the flag when it names none) }
function PlayerText.objective(owner, source, id, text, opts)
    opts = type(opts) == 'table' and opts or {}
    local src = Sanitize.id(source)
    local player = src and Players[src]
    if not src or not player or not player.charId then return false, 'no such player' end
    if type(id) ~= 'string' or id == '' then return false, 'id is a name' end
    if type(text) ~= 'string' then return false, 'text is text' end
    local clean = BubbleText.clean(text, MAX_LEN)
    if clean == '' then return false, 'text is empty' end
    local name = type(opts.name) == 'string' and BubbleText.clean(opts.name, 60) or ''
    local timer, why = timerOf(opts.countdown, opts.countdownTotal)
    if why then return false, why end
    local icon = opts.icon
    if icon ~= nil and (type(icon) ~= 'string' or #icon > 32 or not icon:match('^[%w_]+$')) then
        return false, 'icon is a glyph\'s key (letters, digits and _)'
    end

    local rec = { source = src, owner = owner, id = id, cardId = owner .. ':' .. id, text = clean, tag = opts.tag }
    local ok, err = cardReg:add(owner, cardKey(src, id), rec, opts.tag ~= nil and { tag = opts.tag } or nil)
    if not ok then return false, err end
    cards[src] = cards[src] or {}
    cards[src][rec.cardId] = rec
    TriggerClientEvent('whip_core:client:objective', src, rec.cardId,
        { text = clean, name = name ~= '' and name or nil, timer = timer, icon = icon })
    return true
end

--- Take an objective card down, if it is the owner's. Answers true, or false and why.
function PlayerText.clearObjective(owner, source, id)
    local src = Sanitize.id(source)
    if not src or type(id) ~= 'string' then return false, 'no such card' end
    return cardReg:remove(owner, cardKey(src, id))
end

local function forget(src)
    local rec = src and shown[src]
    if rec then reg:remove(rec.owner, src) end
    -- Their objective cards too, gathered first: each removal changes the table.
    local mine, gone = src and cards[src], {}
    for _, c in pairs(mine or {}) do gone[#gone + 1] = c end
    for _, c in ipairs(gone) do cardReg:remove(c.owner, cardKey(src, c.id)) end
end

Character.onLife('logout', function(e) if e then forget(e.source) end end)
AddEventHandler('playerDropped', function() forget(source) end)

-- ============================================
-- Exports
-- ============================================

--- The instruction band for a player: ShowPlayerText(source, text, { position, progress, countdown,
--- countdownTotal, tag }) -> true | false, why.
exports('ShowPlayerText', function(source, text, opts)
    local owner = Registry.caller()
    return PlayerText.show(owner, source, text, opts)
end)

--- Take yours down: HidePlayerText(source) -> true | false, why.
exports('HidePlayerText', function(source)
    local owner = Registry.caller()
    return PlayerText.hide(owner, source)
end)
