-- ============================================
-- EMOTES — the server's side (client/emotes.lua does the playing)
-- ============================================
--
-- An emote is the player moving their own ped, which is the client's business, so most of the
-- system never touches the server. What does:
--
--   emoteProps  the props an emote holds, made by the server (server/held_props.lua)
--   setWalk     the walk style, saved on the character (GTA shares a walk with other players itself)
--   setMood     the facial expression, saved on the character AND put on the player's statebag
--               (PLAYER_MOOD_KEY), because GTA does not share faces — every client applies it to
--               that player's ped (client/emotes.lua)

-- ============================================
-- An emote's props
-- ============================================
--
-- The client names the EMOTE; the props — model, bone, where in the hand — come from the server's
-- own copy of the emote list. HeldProps makes them, hands them to the owning client to attach, and
-- deletes them when the emote ends (the client's whip_core:server:heldPropsDrop) or the player goes.

local propsOf = {}   -- [cmd] = that emote's props
for _, e in ipairs(EmoteList and EmoteList.emotes or {}) do
    if e.props then propsOf[e.cmd] = e.props end
end

-- A loose limit on purpose: HeldProps makes at most one set a second however fast this arrives, and
-- keeps only the newest ask, so a tight limit here would only refuse the emote a burst ended on.
SecureEvent('whip_core:server:emoteProps', {
    rateLimit = 100,
    burst     = 10,
    params    = { {'cmd', 'key', 40} },
}, function(source, _, cmd)
    local props = propsOf[cmd]
    if not props then return end   -- an emote with nothing to hold: nothing to do
    HeldProps.give(source, props, 'emote')
end)

-- ============================================
-- Walk style and mood
-- ============================================
--
-- The names are an ENUM built from EmoteList, plus 'c' for "back to normal", so a name that is not
-- in the list never reaches the handler. Saved in the character's metadata (walk, mood); a reset
-- removes the key rather than storing 'c'.

local function names(list)
    local out = { 'c' }
    for _, entry in ipairs(list or {}) do out[#out + 1] = entry.cmd end
    return out
end

local WALKS = names(EmoteList and EmoteList.walks)
local MOODS = names(EmoteList and EmoteList.moods)

SecureEvent('whip_core:server:setWalk', {
    rateLimit = 500,
    burst     = 3,
    params    = { {'walk', 'enum', WALKS} },
}, function(_, player, walk)
    local ok, why = player:setMetadata('walk', walk ~= 'c' and walk or nil)
    if not ok then return false, why end
end)

SecureEvent('whip_core:server:setMood', {
    rateLimit = 500,
    burst     = 3,
    params    = { {'mood', 'enum', MOODS} },
}, function(source, player, mood)
    local value = mood ~= 'c' and mood or nil
    local ok, why = player:setMetadata('mood', value)
    if not ok then return false, why end
    Sentinel.setPlayerKey(source, PLAYER_MOOD_KEY, value)
end)

-- Login puts the saved mood back on the bag (server/player_lifecycle.lua) and logout takes it off
-- (server/player.lua). A saved mood since removed from the list is harmless: clients find no face
-- for it and show none.
