-- ============================================
-- /me bubbles — who sees a player's /me (server)
-- ============================================
-- The client sends the text (client/bubbles.lua); this cleans it with the shared rule
-- (shared/bubbles.lua) and sends it to every player within Config.Bubbles.range in the same routing
-- bucket, the sender included. Each of them draws it above the sender's head. Bubbles.show (below)
-- puts the same capsule above a player or an NPC from code.

local CFG = Config.Bubbles or {}

Bubbles = {}

local LINE_CHARS = 60   -- about what one line of a capsule holds (html/bubble3d: 924 px at 30 px)
local MAX_RANGE = 250

--- A bubble's own range (`opts.range`), or nil for Config.Bubbles.range.
local function ownRange(v)
    local n = tonumber(v)
    if not n or n ~= n then return nil end
    return math.max(1, math.min(MAX_RANGE, n))
end

--- A bubble above a player or an NPC, for every player near it (within Config.Bubbles.range, in the
--- same routing bucket) but `opts.except` (a conversation, as the players watching it
--- see it; the Director's NPC /me card). The text is cleaned here, as a /me is.
---@param target table   { source = serverId } or { netId = networkId } (an NPC, any networked ped)
---@param text string
---@param opts table|nil { except = serverId, lines = 1-4 (default 2), range = metres (1-250): seen from this far
---                       instead of Config.Bubbles.range, at its own size (the Director's NPC /me card's Seen from: a
---                       camera zoomed in sees it as big as anything else there), far = metres (0-250): seen this much
---                       further out, and grown with the distance so it stays readable (a lore line's Bonus range),
---                       voice = true: the subtitle of a line the NPC is saying (whip_voice), shown on each game as
---                       the line is heard there (client/bubbles.lua) }
---@return number sent  how many players were sent it
function Bubbles.show(target, text, opts)
    opts = type(opts) == 'table' and opts or {}
    if type(target) ~= 'table' or type(text) ~= 'string' then return 0 end
    local lines = math.max(1, math.min(4, math.floor(tonumber(opts.lines) or 2)))
    local clean = BubbleText.clean(text, math.max(CFG.maxLength or 120, lines * LINE_CHARS))
    if clean == '' then return 0 end
    local ent, bucket
    if target.source then
        local src = tonumber(target.source)
        ent = src and GetPlayerPed(src)
        bucket = src and GetPlayerRoutingBucket(src)
    elseif target.netId then
        ent = NetworkGetEntityFromNetworkId(tonumber(target.netId) or 0)
        bucket = (ent and ent ~= 0) and GetEntityRoutingBucket(ent) or nil
    end
    if not ent or ent == 0 or not DoesEntityExist(ent) then return 0 end
    local at = GetEntityCoords(ent)
    local far = math.max(0, math.min(MAX_RANGE, tonumber(opts.far) or 0))
    local own = ownRange(opts.range)
    local range = (own or CFG.range or 20.0) + far
    local except = tonumber(opts.except)
    local sent = 0
    for _, idStr in ipairs(GetPlayers()) do
        local id = tonumber(idStr)
        if id and id ~= except and GetPlayerRoutingBucket(id) == bucket and IsPlayerNear(id, at.x, at.y, at.z, range) then
            if target.source then
                TriggerClientEvent('whip_core:client:bubble', id, tonumber(target.source), clean, lines, far > 0 and far or nil, own)
            else
                TriggerClientEvent('whip_core:client:bubbleEntity', id, tonumber(target.netId), clean, lines, far > 0 and far or nil,
                    opts.voice == true or nil, own)
            end
            sent = sent + 1
        end
    end
    return sent
end

--- Several bubbles at once, each above an NPC (or a player), for every player near each: the players
--- are looked at ONCE for all of them (a Director group of twelve each saying a line). Each entry is
--- { target, text, opts } as Bubbles.show takes them.
---@param list table[]
---@return number sent  how many bubbles went out, all players together
function Bubbles.showMany(list)
    if type(list) ~= 'table' then return 0 end
    local range = CFG.range or 20.0
    local ready = {}
    for _, e in ipairs(list) do
        local target, text, opts = e[1], e[2], type(e[3]) == 'table' and e[3] or {}
        if type(target) == 'table' and type(text) == 'string' then
            local lines = math.max(1, math.min(4, math.floor(tonumber(opts.lines) or 2)))
            local clean = BubbleText.clean(text, math.max(CFG.maxLength or 120, lines * LINE_CHARS))
            local ent, bucket
            if target.source then
                local src = tonumber(target.source)
                ent = src and GetPlayerPed(src)
                bucket = src and GetPlayerRoutingBucket(src)
            elseif target.netId then
                ent = NetworkGetEntityFromNetworkId(tonumber(target.netId) or 0)
                bucket = (ent and ent ~= 0) and GetEntityRoutingBucket(ent) or nil
            end
            if clean ~= '' and ent and ent ~= 0 and DoesEntityExist(ent) then
                -- far, range and voice per entry, as Bubbles.show reads them (audit 20, WLD-1: they were dropped)
                local far = math.max(0, math.min(MAX_RANGE, tonumber(opts.far) or 0))
                local own = ownRange(opts.range)
                local reach = (own or range) + far
                ready[#ready + 1] = { at = GetEntityCoords(ent), bucket = bucket, clean = clean, lines = lines,
                                      source = tonumber(target.source), netId = tonumber(target.netId), except = tonumber(opts.except),
                                      far = far > 0 and far or nil, own = own, voice = opts.voice == true or nil, r2 = reach * reach }
            end
        end
    end
    if #ready == 0 then return 0 end
    local sent = 0
    for _, idStr in ipairs(GetPlayers()) do
        local id = tonumber(idStr)
        -- (As IsPlayerNear asks it: one in the character creator is near nothing.)
        local p = id and Players and Players[id]
        local ped = id and not (p and p._inCreator) and GetPlayerPed(id) or nil
        if id and ped and ped ~= 0 then
            local pos, bucket = GetEntityCoords(ped), GetPlayerRoutingBucket(id)
            for _, b in ipairs(ready) do
                local dx, dy, dz = pos.x - b.at.x, pos.y - b.at.y, pos.z - b.at.z
                if id ~= b.except and bucket == b.bucket and dx * dx + dy * dy + dz * dz <= b.r2 then
                    if b.source then
                        TriggerClientEvent('whip_core:client:bubble', id, b.source, b.clean, b.lines, b.far, b.own)
                    else
                        TriggerClientEvent('whip_core:client:bubbleEntity', id, b.netId, b.clean, b.lines, b.far, b.voice, b.own)
                    end
                    sent = sent + 1
                end
            end
        end
    end
    return sent
end

SecureEvent('whip_core:server:me', {
    whileDead = true,   -- a downed character can still /me
    rateLimit = 1000,
    burst     = 3,
    params    = { { 'text', 'string', 1024 } },
}, function(source, player, raw)
    local text = BubbleText.clean(raw, CFG.maxLength or 120)
    if text == '' then return false, 'Say what your character does: /me eats an apple' end
    if player and player._inCreator then return false end

    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return false end
    local at = GetEntityCoords(ped)
    local bucket = GetPlayerRoutingBucket(source)
    local range = CFG.range or 20.0

    for _, idStr in ipairs(GetPlayers()) do
        local id = tonumber(idStr)
        if id and GetPlayerRoutingBucket(id) == bucket and IsPlayerNear(id, at.x, at.y, at.z, range) then
            TriggerClientEvent('whip_core:client:bubble', id, source, text)
        end
    end

    -- One line in the server log, like chat. The text has no line breaks left (BubbleText.clean).
    print(('^5[me]^7 %s (%d): %s'):format(GetPlayerName(source) or '?', source, text))
end)
