-- ============================================
-- Player Lifecycle — server/player_lifecycle.lua
-- Connection, character selection, disconnect,
-- periodic saves, logout, resource start/stop
-- ============================================

--- Which map cells each player has been sent — the ground items and door states in them — seeded at
--- login, kept current by the proximity thread in events_inventory.lua, cleared at logout and drop.
GroundSync = {}   -- [source] = { syncedCells = { [cellKey] = true }, lastCell = cellKey of the last sync pass }

--- Which players have a point's map cell in view: player spatial interest (GroundSync), not specific
--- to ground items (doors use it both ways). What replaces broadcasting to every player: a lookup on
--- an index already maintained once a second.
---@param x number
---@param y number
---@return number[] sources
function PlayersNearPoint(x, y)
    local key = GroundItems.cellKey(x, y)
    local out = {}
    for src, syncData in pairs(GroundSync) do
        if syncData.syncedCells and syncData.syncedCells[key] then
            out[#out + 1] = src
        end
    end
    return out
end

--- Every player within NETWORK RANGE of a point (Config.NetworkRange, 424 m: what a player's game has
--- in scope), for a chat line, a throw, a car's new look. Measured flat (x, y), so a player high in a
--- tower above it is still in. Players on the character screen count (they have a ped). Something
--- with a cell (a ground pile, a door) goes to its cell's holders instead: PlayersNearPoint.
---@param x number
---@param y number
---@param range number|nil  metres; default Config.NetworkRange
---@return number[] sources
function PlayersInRange(x, y, range)
    range = tonumber(range) or Config.NetworkRange or 424.0
    local r2, out = range * range, {}
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        local ped = src and GetPlayerPed(src)
        if ped and ped ~= 0 then
            local c = GetEntityCoords(ped)
            local dx, dy = c.x - x, c.y - y
            if dx * dx + dy * dy <= r2 then out[#out + 1] = src end
        end
    end
    return out
end

--- Send one event to a list of players, packed ONCE. TriggerClientEvent packs its arguments again on
--- every call (citizen scheduler.lua), so a loop of them packs the same payload once per player.
---@param sources number[]
---@param eventName string
function SendToPlayers(sources, eventName, ...)
    if #sources == 0 then return end
    local payload = msgpack.pack_args(...)
    local len = payload:len()
    for _, src in ipairs(sources) do TriggerClientEventInternal(eventName, src, payload, len) end
end

--- The players within network range of a point, for a satellite's message about a place (whip_chat).
--- `coords` is a vector3 or { x, y }; `range` defaults to Config.NetworkRange (424 m). Answers a list of
--- server ids, empty for bad input.
exports('GetPlayersInRange', function(coords, range)
    local x = (type(coords) == 'vector3' or type(coords) == 'table') and tonumber(coords.x) or nil
    local y = x and tonumber(coords.y) or nil
    if not (x and y) then return {} end
    return PlayersInRange(x, y, range)
end)

-- ============================================
-- Identifier Extraction
-- ============================================

---@param source number
---@return table identifiers  {license, steam, discord, fivem}
local function ExtractIdentifiers(source)
    local ids = {license = nil, steam = nil, discord = nil, fivem = nil}
    local numIds = GetNumPlayerIdentifiers(source)

    for i = 0, numIds - 1 do
        local id = GetPlayerIdentifier(source, i)
        if id then
            if id:find('^license:') then
                ids.license = id:gsub('license:', '')
            elseif id:find('^steam:') then
                ids.steam = id:gsub('steam:', '')
            elseif id:find('^discord:') then
                ids.discord = id:gsub('discord:', '')
            elseif id:find('^fivem:') then
                ids.fivem = id:gsub('fivem:', '')
            end
        end
    end

    return ids
end

-- ============================================
-- Identity Resolution
-- ============================================
--
-- `users` is keyed on `license`, but a player's `license:` identifier comes from their Rockstar
-- account and CAN change, and a license-only lookup would make a new, empty account. So: try
-- `license`, then identifiers that survive a Rockstar account change, and adopt the new license
-- when a fallback matches.
--
-- Only server-verified identifiers are fallbacks (`fivem`, the Cfx.re account id, and `discord`):
-- anything accepted as proof of identity is something an attacker could try to present.

--- Fallback identifiers, in priority order. `license` is handled separately as the primary.
local IDENTITY_FALLBACKS = { 'fivem', 'discord' }

--- Resolve the userId for a set of identifiers, WITHOUT creating a row.
--- If a fallback matches, the stored license is updated to the one they connected with, so
--- the account self-heals and a future change in either direction resolves the same way.
---@param ids table  {license, steam, discord, fivem}
---@return number|nil userId
---@return string|nil matchedBy  'license' | 'fivem' | 'discord'
---@return table|nil notice  something staff and the player should hear about (see ReportIdentityNotice):
---                          { kind = 'recovered', field, licenseUpdated } or { kind = 'split', field, otherUserId }
function ResolveUserId(ids)
    if ids.license then
        local userId = MySQL.scalar.await('SELECT `userId` FROM `users` WHERE `license` = ?', { ids.license })
        if userId then
            -- Warn if another row shares a verified identifier — a split account that needs
            -- a manual merge. Deliberately NOT auto-merged: joining two user records is not
            -- something to do silently on a login.
            local notice = nil
            for _, field in ipairs(IDENTITY_FALLBACKS) do
                if ids[field] then
                    local other = MySQL.scalar.await(
                        ('SELECT `userId` FROM `users` WHERE `%s` = ? AND `userId` != ? LIMIT 1'):format(field),
                        { ids[field], userId }
                    )
                    if other then
                        print(('[whip_core] WARNING: split account — userId %d (license) and userId %d share %s:%s. Manual merge required.')
                            :format(userId, other, field, tostring(ids[field])))
                        notice = notice or { kind = 'split', field = field, otherUserId = other }
                    end
                end
            end
            return userId, 'license', notice
        end
    end

    -- License missed. Try the identifiers that survive a Rockstar account change.
    for _, field in ipairs(IDENTITY_FALLBACKS) do
        if ids[field] then
            local userId = MySQL.scalar.await(
                ('SELECT `userId` FROM `users` WHERE `%s` = ? ORDER BY `userId` ASC LIMIT 1'):format(field),
                { ids[field] }
            )
            if userId then
                local licenseUpdated = false
                if ids.license then
                    local ok, err = pcall(MySQL.update.await,
                        'UPDATE `users` SET `license` = ? WHERE `userId` = ?', { ids.license, userId })
                    if ok then
                        licenseUpdated = true
                        print(('[whip_core] identity recovered: userId %d matched by %s:%s — license updated to %s')
                            :format(userId, field, tostring(ids[field]), ids.license))
                    else
                        -- Almost certainly the UNIQUE on `license` — another row already holds it.
                        print(('[whip_core] WARNING: userId %d matched by %s but its license could not be updated: %s')
                            :format(userId, field, tostring(err)))
                    end
                end
                return userId, field, { kind = 'recovered', field = field, licenseUpdated = licenseUpdated }
            end
        end
    end

    return nil, nil
end

--- Account notices waiting for their player to reach the character screen. [userId] = message
---
--- Keyed by USERID, not server id: the id a player connects with is not the one they play with
--- (see EnsurePending), and the connection step is where the notice is found.
local _identityNotices = {}

--- Tell staff now, and the player at the character screen, that an account was found by something
--- other than its Rockstar license — or that another account shares one of its IDs.
---
--- Both, and loudly: recovery is right when someone's Rockstar license changes, but two Rockstar
--- accounts sharing one PC's FiveM login would take turns owning the same whip account, each one
--- "recovering" it from the other. Nothing here can tell those cases apart, so the people who can
--- are told: the player, who knows whether those are their characters, and every admin online —
--- with the console and the activity log as the record.
---@param name string    the connecting player's name
---@param userId number
---@param notice table   from ResolveUserId
local function ReportIdentityNotice(name, userId, notice)
    local idName = notice.field == 'fivem' and 'FiveM' or 'Discord'
    local staffMsg, playerMsg
    if notice.kind == 'recovered' then
        staffMsg = ('Account recovery: %s connected with a new Rockstar license and was matched to account #%d by %s ID%s.')
            :format(name, userId, idName, notice.licenseUpdated and '' or ' (the license could NOT be updated)')
        playerMsg = ('Your Rockstar license changed, so your account was found by your %s ID instead. '
            .. 'If these are not your characters, stop and contact staff.'):format(idName)
    else
        staffMsg = ('Split account: %s (account #%d) shares a %s ID with account #%d. Check whether they need merging.')
            :format(name, userId, idName, notice.otherUserId)
        playerMsg = ('Another account on this server shares your %s ID. If characters are missing, contact staff.')
            :format(idName)
    end

    print('^3[whip_core] ' .. staffMsg .. '^0')
    Log.write(nil, 'identity_notice', { detail = staffMsg })
    for src in pairs(Players) do
        if IsPlayerAceAllowed(src, 'whip.devtools') then
            ShowError(src, staffMsg, 12000)
        end
    end
    _identityNotices[userId] = playerMsg
end

--- Ensure PendingPlayers entry exists for a source
--- Works regardless of whether playerConnecting stored it
---@param source number
---@return table|nil pending
local function EnsurePending(source)
    if PendingPlayers[source] then
        return PendingPlayers[source]
    end

    -- Look up from live identifiers (handles source mismatch from playerConnecting)
    local ids = ExtractIdentifiers(source)
    if not ids.license then return nil end

    local userId = ResolveUserId(ids)
    if not userId then return nil end

    PendingPlayers[source] = {
        userId = userId,
        license = ids.license,
        steam = ids.steam,
        discord = ids.discord,
        fivem = ids.fivem,
    }

    return PendingPlayers[source]
end

-- ============================================
-- Character Select Isolation
-- ============================================
--
-- A player who has not picked a character must not see the world, and the world must not see them.
-- One bucket each, keyed off the server ID: two players sharing one would still see each other's
-- ped (SetEntityVisible hides it only locally). The preview characters are created with
-- isNetwork = false, so they never leave the machine.

--- Where the private worlds start: 1000 + the player's id. Fixed, clear of the worlds other things
--- use (the Director's 100000 + id).
local CHARSELECT_BUCKET_BASE = 1000

---@param source number
---@return number bucket
local function CharSelectBucket(source)
    return CHARSELECT_BUCKET_BASE + source
end

--- Move a player into their private character-select bucket. Global: WhipPlayer:logout() in
--- player.lua calls it too.
function EnterCharSelectBucket(source)
    local bucket = CharSelectBucket(source)
    SetPlayerRoutingBucket(source, bucket)

    -- Ambient peds and traffic would otherwise wander through the shot. Set either way at each entry,
    -- so turning quietBucket off in /whip → Settings fills a bucket that was quieted before (a
    -- bucket's population is the server's, and lasts until it is set again).
    SetRoutingBucketPopulationEnabled(bucket, (Config.CharSelect or {}).quietBucket == false)
end

--- The player has entered the session but has no character yet, so isolate them straight away
--- (not at requestCharacters: the spawn manager drops them into the world first).
AddEventHandler('playerJoining', function()
    EnterCharSelectBucket(source)
end)

-- ============================================
-- Player Connection (UPSERT user record only)
-- ============================================

--- What the start is waiting on, for a player who connects meanwhile ('waiting for its database'), or nil.
local bootWaiting = nil

--- The deferral body, separated so the handler below can pcall it: a throw from any of its database
--- awaits must still resolve the deferral.
local function processConnection(source, name, deferrals)
    -- Still starting: wait, rather than let a player into a half-loaded world (their character would
    -- load before its cars, garages and containers exist).
    if not CoreReady and not BootHalted then
        deferrals.update(bootWaiting and ('[whip_core] The server is still starting (' .. bootWaiting .. ')...')
            or '[whip_core] The server is still starting...')
        local deadline = GetGameTimer() + 60000
        while not CoreReady and not BootHalted and GetGameTimer() < deadline do Wait(500) end
    end

    -- The boot stopped (see onResourceStart): nothing is loaded, and a player let in now would be
    -- saved into a half-built database.
    if BootHalted then
        deferrals.done('[whip_core] The server did not finish starting (' .. BootHalted .. '). An admin needs to check the server console.')
        return
    end
    if not CoreReady then
        deferrals.done('[whip_core] The server is still starting. Try again in a minute.')
        return
    end

    deferrals.update('[whip_core] Checking identifiers...')

    local ids = ExtractIdentifiers(source)

    if not ids.license then
        deferrals.done('[whip_core] No license identifier found. Please restart FiveM.')
        return
    end

    -- Ban check (all identifiers)
    deferrals.update('[whip_core] Checking ban status...')
    local banRow = MySQL.single.await(
        'SELECT * FROM `bans` WHERE `active` = 1 AND (`license` = ? OR `steam` = ? OR `discord` = ? OR `fivem` = ?) AND (`expiresAt` IS NULL OR `expiresAt` > NOW()) ORDER BY `bannedAt` DESC LIMIT 1',
        { ids.license, ids.steam, ids.discord, ids.fivem }
    )
    if banRow then
        local msg = 'You are banned from this server.\n\nReason: ' .. (banRow.reason or 'No reason provided')
        if banRow.expiresAt then
            local expiryStr
            if type(banRow.expiresAt) == 'number' then
                -- Convert unix timestamp (seconds or ms) to readable date
                local ts = banRow.expiresAt < 4102444800 and banRow.expiresAt or math.floor(banRow.expiresAt / 1000)
                expiryStr = os.date('%Y-%m-%d %H:%M:%S %Z', ts)
            else
                expiryStr = tostring(banRow.expiresAt)
            end
            msg = msg .. '\nExpires: ' .. expiryStr
        else
            msg = msg .. '\n\nThis ban is permanent.'
        end
        msg = msg .. '\n\nBan ID: #' .. banRow.banId
        deferrals.done(msg)
        return
    end

    deferrals.update('[whip_core] Loading player record...')

    -- Resolve identity across all verified identifiers before creating anything.
    local userId, matchedBy, notice = ResolveUserId(ids)

    if userId then
        -- Refresh the secondary identifiers on the existing row.
        -- COALESCE, not a plain assignment: a player connecting without Discord linked must
        -- not wipe the stored discord id — those secondary identifiers are the recovery
        -- anchors that let this account be found again if the license changes.
        MySQL.query.await(
            'UPDATE `users` SET `steam` = COALESCE(?, `steam`), `discord` = COALESCE(?, `discord`), `fivem` = COALESCE(?, `fivem`), `name` = ?, `lastSeen` = CURRENT_TIMESTAMP WHERE `userId` = ?',
            { ids.steam, ids.discord, ids.fivem, name, userId }
        )
        if matchedBy ~= 'license' then
            deferrals.update('[whip_core] Recovered your account from a changed identifier...')
        end
        if notice then ReportIdentityNotice(name, userId, notice) end
    else
        -- Genuinely new player.
        local ok, inserted = pcall(MySQL.insert.await,
            'INSERT INTO `users` (`license`, `steam`, `discord`, `fivem`, `name`) VALUES (?, ?, ?, ?, ?)',
            { ids.license, ids.steam, ids.discord, ids.fivem, name }
        )
        if ok then
            userId = inserted
        else
            -- Almost certainly the UNIQUE on `license`: a concurrent connection from the same
            -- player created the row between our resolve and our insert. Resolve again rather
            -- than turning a harmless race into a failed login.
            userId = ResolveUserId(ids)
        end
    end

    if not userId then
        deferrals.done('[whip_core] Failed to load your player record. Please try again.')
        return
    end

    print(('[whip_core] Player connected: %s [%d] (userId: %d, license: %s)'):format(name, source, userId, ids.license))

    deferrals.done()
end

AddEventHandler('playerConnecting', function(name, _, deferrals)
    local source = source
    deferrals.defer()
    Wait(0)

    local ok, err = pcall(processConnection, source, name, deferrals)
    if not ok then
        print(('[whip_core] ERROR during connection of %s: %s'):format(tostring(name), tostring(err)))
        deferrals.done('[whip_core] The server could not load your record (database error). Please try again in a moment.')
    end
end)

-- ============================================
-- Character Selection Flow
-- ============================================

--- Client requests the character list after fully spawning
SecureEvent('whip_core:server:requestCharacters', {
    rateLimit = 2000,
    requirePlayer = false,
}, function(source)
    -- Not with a character loaded: the character screen's private bucket would make a loaded player
    -- invisible to everyone. /logout is the way back to the screen.
    if Players[source] then
        RecordEventRejection('whip_core:server:requestCharacters', source, 'character already loaded')
        return
    end

    -- The reads can fail (a database blip at a restart): caught, and the client's retry asks again.
    local okPending, pending = pcall(EnsurePending, source)
    if not okPending then
        print(('[whip_core] requestCharacters for source %d: reading the account failed: %s'):format(source, tostring(pending)))
        return
    end
    if not pending then
        print(('[whip_core] WARNING: requestCharacters failed for source %d — no license found'):format(source))
        ShowError(source, 'Your account could not be identified — please reconnect', 30000)
        return
    end

    -- Re-asserted here, not only on playerJoining: after a whip_core restart the player is already
    -- in the session, and playerJoining never fires again.
    EnterCharSelectBucket(source)

    -- The world's time and weather now, not at the next broadcast (Config.TimeSyncInterval).
    TriggerClientEvent('whip_core:client:timeSync', source, TimeWeather.getSyncData())

    local okList, chars = pcall(Character.list, pending.userId)
    if not okList then
        print(('[whip_core] requestCharacters for source %d: the character list could not be read: %s'):format(source, tostring(chars)))
        return   -- the client asks again
    end
    TriggerClientEvent('whip_core:client:receiveCharacters', source, chars, Config.MaxCharacters)

    -- An account notice from this connection (see ReportIdentityNotice), shown where the player is
    -- looking at the characters it concerns, and long enough to read. Once.
    local notice = _identityNotices[pending.userId]
    if notice then
        _identityNotices[pending.userId] = nil
        ShowError(source, notice, 15000)
    end
end)

--- The character screen asked for a character and is waiting behind a black screen for it
--- (client/charselect.lua): it comes straight back with the reason and a fresh list. Not for "you
--- already have a character loaded": a list would put the character screen over the game.
---@param source number
---@param why string
---@param duration number|nil
local function refuseLoad(source, why, duration)
    ShowError(source, why, duration)
    local pending = PendingPlayers[source]
    -- The list is read first, and promised only once it is in hand.
    local chars = nil
    if pending ~= nil and pending.userId ~= nil and not Players[source] then
        local ok, list = pcall(Character.list, pending.userId)
        if ok then
            chars = list
        else
            print(('[whip_core] the character list for source %d could not be read: %s'):format(source, tostring(list)))
        end
    end
    -- `listFollows`: the fresh list rebuilds the screen from the black (CharSelect.Open), so the
    -- client only stands its timeout down; with no list it brings the old screen back itself.
    TriggerClientEvent('whip_core:client:loadRefused', source, why, chars ~= nil)
    if chars then
        TriggerClientEvent('whip_core:client:receiveCharacters', source, chars, Config.MaxCharacters)
    end
end

--- Client selects a character — by its charId, checked as this account's own (Character.isOwnLive) — and
--- where they arrive: 'last' (where they left), or a spawn picker choice's id (server/spawn_choices.lua),
--- read again in the load.
SecureEvent('whip_core:server:selectCharacter', {
    rateLimit = 2000,
    requirePlayer = false,
    params = { {'charId', 'id'}, {'spawnId', 'string', 40, 'last'} },
}, function(source, _, charId, spawnId)
    -- Loaded is asked first: EnsurePending would re-create a pending entry for a player who already
    -- has a character.
    if Players[source] then
        return false, 'You already have a character loaded. Use /logout first.'
    end

    local pending = EnsurePending(source)

    if not pending then
        refuseLoad(source, 'Error: Player not found. Reconnect.')
        return
    end

    if not Character.isOwnLive(pending.userId, charId) then
        refuseLoad(source, 'That character could not be found')
        return
    end

    LoadCharacterForPlayer(source, charId, false, spawnId)
end)

--- Client creates a new character
SecureEvent('whip_core:server:createCharacter', {
    rateLimit = 2000,
    requirePlayer = false,
    params = {
        {'firstName', 'string', 30},
        {'lastName', 'string', 30},
        {'dateOfBirth', 'string', 10},
        {'gender', 'enum', {'male', 'female'}, 'male'},
    },
}, function(source, _, firstName, lastName, dateOfBirth, gender)
    -- Loaded is asked before EnsurePending, as in selectCharacter.
    if Players[source] then
        return false, 'Logout first before creating a new character.'
    end

    local pending = EnsurePending(source)

    if not pending then
        refuseLoad(source, 'Error: Player not found. Reconnect.')
        return
    end

    -- Not while start-up is still running: the character would be created and its load refused.
    if BootHalted or not CoreReady then
        refuseLoad(source, BootHalted and 'The server could not finish starting — tell an admin.'
            or 'The server is still starting — try again in a moment.')
        return
    end

    -- The names cleaned and checked by the one rule a rename uses too (Character.cleanNames: letters, spaces and
    -- hyphens, trimmed and collapsed, two letters at least).
    local nameWhy
    firstName, lastName, nameWhy = Character.cleanNames(firstName, lastName)
    if not firstName then
        refuseLoad(source, nameWhy --[[@as string]])
        return
    end
    -- (cleanNames answers both names, or neither and why.)
    ---@cast lastName string

    local charId, err = Character.create(pending.userId, firstName, lastName, dateOfBirth, gender)

    if not charId then
        refuseLoad(source, 'Failed to create character: ' .. (err or 'Unknown error'))
        return
    end

    -- Create default bank account. `true` is isDefault: without it GetDefaultAccount finds nothing and
    -- Config.StartingBalance is never paid.
    local account, bankErr = Bank.CreateAccount(charId, Config.DefaultAccountLabel, 'personal', true)
    if not account then
        print(('[whip_core] WARNING: Failed to create default bank account: %s'):format(bankErr or 'Unknown'))
    end

    WhipEmit('whip_core:character:created', { source = source, charId = charId })

    -- Auto-load the newly created character. `true` is isNewCharacter: it rides serialize() to the
    -- client, where the load sequence (client/player.lua) opens the appearance creator.
    LoadCharacterForPlayer(source, charId, true)
end)

--- The creator is finished with a brand new character — let them into the world.
---
--- The bucket is the point: a new character is built in the private bucket they still hold from
--- the character screen (LoadCharacterForPlayer). The client waits for the reply before moving
--- them, behind a black screen.
---
--- Only from the creator: the load marks a brand new character `_inCreator`; this refuses anyone
--- else (or it would be a way out of and back into the world at will) and clears the mark.
SecureEvent('whip_core:server:creatorDone', {
    rateLimit = 2000,
}, function(source, player)
    if not player._inCreator then
        RecordEventRejection('whip_core:server:creatorDone', source, 'not in the character creator')
        return
    end
    player._inCreator = nil
    -- Left the creator, finished or skipped: it does not open again at the next load.
    player:setMetadata('creatorPending', nil)
    -- The "placed anyway" clock (WhipPlayer:getCoords) starts now, not at the load: after a long
    -- stay in the creator it would otherwise fire while the ped is still on the creator's mark.
    player.loadedAt = GetGameTimer()
    player:watchPlacement()   -- the walk to the spawn point starts now
    SetPlayerRoutingBucket(source, 0)
    TriggerClientEvent('whip_core:client:creatorFinished', source)
end)

--- Client requests character deletion — by charId, checked as this account's own.
SecureEvent('whip_core:server:deleteCharacter', {
    rateLimit = 2000,
    requirePlayer = false,
    params = { {'charId', 'id'} },
}, function(source, _, charId)
    -- Only from the character screen, like select and create.
    if Players[source] then
        RecordEventRejection('whip_core:server:deleteCharacter', source, 'character loaded')
        return
    end

    local pending = EnsurePending(source)

    if not pending then
        return false, 'Error: Player not found. Reconnect.'
    end

    if not Character.isOwnLive(pending.userId, charId) then
        return false, 'That character could not be found'
    end

    -- Not while it is loading or being played, on any connection of the account.
    if PlayersByCharId[charId] or LoadingCharIds[charId] then
        return false, 'That character is in use right now. Try again in a moment.'
    end

    -- And held for the delete: the load path refuses any charId in LoadingCharIds, so a second
    -- connection can't load it mid-delete. Both exits below clear it (Character.delete answers rather
    -- than throws; each hook runs under its own pcall).
    LoadingCharIds[charId] = 'deleting'
    local ok, err = Character.delete(charId, pending.userId)
    if not ok and LoadingCharIds[charId] == 'deleting' then LoadingCharIds[charId] = nil end
    if ok then
        -- What deleting a character does, one policy: what they held goes back to STOCK, and nothing
        -- inside it is thrown away. Each system does its part in its own Character.onLife('deleted')
        -- hook (run here, not from the public event, which any resource could fire):
        --   homes      no owner (for sale again), every key to them gone; furniture and contents stay
        --              (server/properties.lua)
        --   keys       every property key they held elsewhere is removed (properties.lua)
        --   jobs       they leave every job; a business they OWN has no owner and keeps running —
        --              staff, shop, business account (server/jobs.lua)
        --   stashes    contents stay; owner and one-person lock cleared (server/containers.lua)
        --   cars, bank accounts   STAY AS THEY ARE — later systems (shared accounts, shared
        --              garages) take from them; an admin can reassign one meanwhile
        -- Characters are soft-deleted (Character.delete), so no database cascade does any of this.
        Character.runHooks('deleted', { source = source, charId = charId })
        if LoadingCharIds[charId] == 'deleting' then LoadingCharIds[charId] = nil end
        -- Then the news, for satellites.
        WhipEmit('whip_core:character:deleted', { source = source, charId = charId })
        ShowSuccess(source, 'Character deleted successfully.')
        -- Refresh character list, in a pcall: on a database error the client is told to ask again.
        local listed, chars = pcall(Character.list, pending.userId)
        if listed then
            TriggerClientEvent('whip_core:client:receiveCharacters', source, chars, Config.MaxCharacters)
        else
            print(('[whip_core] deleteCharacter for source %d: the character list could not be read: %s'):format(source, tostring(chars)))
            TriggerClientEvent('whip_core:client:charactersStale', source)
        end
    else
        return false, 'Failed to delete: ' .. (err or 'Unknown error')
    end
end)

-- ============================================
-- Load Character Helper
-- ============================================

-- ---- Load claims — proving the session you started loading for is still there ----
--
-- LoadCharacterForPlayer checks PendingPlayers once and then yields on several database round
-- trips. Meanwhile the player can disconnect (a WhipPlayer published after playerDropped ran would
-- never be removed, and its saves would overwrite the character), the server id can be reused, or
-- select and create can both arrive before either publishes.
--
-- One question covers all three: is the session I started loading for still the one that is there?
-- A fresh table compared by identity answers it. The claim is taken synchronously, before the first
-- yield, and refuses to be taken twice.

--- Take an exclusive load claim for this source. Returns nil if there is no pending session, or
--- if a load is already in flight for it.
---@param source number
---@return table|nil claim
---@return table|string|nil pending  the entry itself, since the load builds userData from it; or, with no
---                                 claim, why not (start-up)
local function beginLoad(source)
    -- Already playing a character: nothing may be loaded over it (createCharacter's inserts yield,
    -- and a select can finish meanwhile).
    if Players[source] then return nil end
    -- Nor before start-up has finished, or when it halted. The reason goes back to the caller to show.
    if BootHalted then return nil, 'The server could not finish starting — tell an admin.' end
    if not CoreReady then return nil, 'The server is still starting — try again in a moment.' end
    local pending = PendingPlayers[source]
    if not pending then return nil end
    if pending._loadClaim then return nil end
    local claim = {}
    pending._loadClaim = claim
    -- Handed back: the caller reads userId/license off it after its first yield, and this reference
    -- still describes the session it started for (the claim check decides whether to publish).
    return claim, pending
end

--- Is this claim still the live one for this source?
---@param source number
---@param claim table
---@return boolean
local function claimHeld(source, claim)
    local pending = PendingPlayers[source]
    return pending ~= nil and pending._loadClaim == claim
end

--- Give the claim back so the player can try again. Safe to call when the claim has already
--- been superseded — it only clears its own.
---@param source number
---@param claim table
local function releaseClaim(source, claim)
    local pending = PendingPlayers[source]
    if pending and pending._loadClaim == claim then
        pending._loadClaim = nil
    end
end

--- Abandon a load that got far enough to touch persistence.
---
--- Inventory.load populates a cache and Stores may already hold a dirty unit for it. Returning
--- without dropping that unit leaves the flush thread holding a half-built session keyed on the
--- SAME unit the character's next login will use.
---@param source number
---@param claim table
---@param charId number|nil
---@param why string
local function abandonLoad(source, claim, charId, why)
    releaseClaim(source, claim)
    if charId then Stores.forget('player:' .. charId) end
    print(('[whip_core] abandoned character load for source %d: %s'):format(source, why))
end

-- ---- The other half of the admin-inventory handover ----
--
-- An admin may have an OFFLINE character's inventory open (a second, detached cache) when that
-- character logs in. Its save on close would prune every row not in its copy, so it is closed
-- BEFORE the live cache is built and the two never coexist.

--- Characters whose live inventory cache is currently being built. Read by OpenPlayerInventory
--- so an admin cannot open the offline view of a character mid-login and end up detached again.
LoadingCharIds = {}

-- Closing it is Inventory.closeOfflineSessionsOn (server/inventory.lua); the call is below.

---@param source number
---@param charId number
---@param isNewCharacter boolean|nil
---@param claim table    taken by LoadCharacterForPlayer before this runs
---@param pending table
---@param spawnId string|nil  the spawn picker's choice; nil or 'last' is where they left
local function loadCharacterInner(source, charId, isNewCharacter, claim, pending, spawnId)
    local charData = Character.load(charId)
    if not charData then
        releaseClaim(source, claim)
        refuseLoad(source, 'Failed to load character data.')
        return
    end

    -- Somewhere the spawn picker chose (server/spawn_choices.lua), read again now: a choice that is no longer
    -- theirs (a key taken, a spawn point removed) refuses the load, and the character screen says why.
    -- A dead character arrives where they fell (character.lua: no picker): a choice sent for one is ignored. So is
    -- every choice while the picker is switched off (Config.CharSelect.spawnPicker): the client's word is not the rule.
    if DbBool(charData.isDead) then spawnId = nil end
    if (Config.CharSelect or {}).spawnPicker == false then spawnId = nil end
    local spawnAt, spawnWhy = SpawnChoices.resolve(charData.charId, spawnId)
    if spawnWhy then
        releaseClaim(source, claim)
        refuseLoad(source, spawnWhy)
        return
    end

    -- Build userData table for WhipPlayer constructor
    local userData = {
        userId  = pending.userId,
        license = pending.license,
        steam   = pending.steam,
        discord = pending.discord,
        fivem   = pending.fivem,
    }

    -- Create WhipPlayer instance
    local player = WhipPlayer.new(source, userData, charData)

    -- A creator never finished opens again: `creatorPending` is set when a character is made and
    -- cleared when the creator is left (finished or skipped: creatorDone).
    --
    -- Two flags: `openCreator` drives the creator and its bucket; `isNewCharacter` (the welcome-pack
    -- hook's `newCharacter` on whip_core:player:loaded) stays true only for the load straight after
    -- the character was made.
    local openCreator = isNewCharacter == true
    if isNewCharacter then
        player:setMetadata('creatorPending', true)
    elseif type(player.metadata) == 'table' and player.metadata.creatorPending == true then
        openCreator = true
    end

    -- Noticed arriving at the spawn, not whenever something next reads the coords.
    player:watchPlacement()

    -- Load inventory from DB. A nil return means the read FAILED (not "empty"): refuse to spawn, or
    -- the next save would persist an empty inventory over the real one.
    -- First close any detached admin view of the character, BEFORE the live cache exists
    -- (LoadingCharIds was set by LoadCharacterForPlayer). Its write must have LANDED, and nothing may
    -- still be owed under the admin copy's 'raw:' unit (as the last session's own unit, settle).
    if not Inventory.closeOfflineSessionsOn(charData.charId)
        or not Stores.settle('raw:' .. tostring(charData.charId)) then
        LoadingCharIds[charData.charId] = nil
        abandonLoad(source, claim, charData.charId, 'an inspected copy of the inventory is still owed')
        refuseLoad(source, 'Your inventory is still being saved. Try again in a moment.')
        return
    end

    local loadedInventory, retiredGone = Inventory.load(charData.charId)
    if not loadedInventory then
        LoadingCharIds[charData.charId] = nil
        abandonLoad(source, claim, charData.charId, 'inventory read failed')
        refuseLoad(source, 'Could not load your inventory. Please try again in a moment.')
        return
    end
    player.inventory = loadedInventory

    -- Cache the default account number once, here, rather than a query on every inventory,
    -- container or shop open.
    local defaultAccount = Bank.GetDefaultAccount(player.charId)

    -- No default account at all? Made now. Asked of the table itself (every default row, closed ones
    -- too, by a read that must SUCCEED), so a failed lookup can never make a second one.
    if not defaultAccount then
        local counted, n = pcall(MySQL.scalar.await,
            'SELECT COUNT(*) FROM `bank_accounts` WHERE `ownerCharId` = ? AND `isDefault` = 1', { player.charId })
        if counted and tonumber(n) == 0 then
            local made, why = Bank.CreateAccount(player.charId, Config.DefaultAccountLabel, 'personal', true)
            if made then
                print(('[whip_core] made the missing default bank account for charId %d'):format(player.charId))
                defaultAccount = Bank.GetDefaultAccount(player.charId)
            else
                print(('[whip_core] charId %d still has no default bank account: %s'):format(player.charId, tostring(why)))
            end
        end
    end
    player.accountNumber = defaultAccount and defaultAccount.accountNumber or nil

    -- Move from pending to active. Last chance to notice the session left: everything above
    -- yielded, and this is the first write that can't be taken back.
    LoadingCharIds[player.charId] = nil

    if not claimHeld(source, claim) then
        abandonLoad(source, claim, player.charId, 'session ended or was replaced during load')
        return
    end

    Players[source] = player
    PlayersByCharId[player.charId] = player
    PlayersByUserId[player.userId] = player
    PendingPlayers[source] = nil

    -- Retired items taken out as the pockets loaded (Inventory.load): written with the next flush, now the
    -- pockets are live. Marked, not saved: nothing between here and the client's sync may wait.
    if (retiredGone or 0) > 0 then Stores.markDirty(Stores.player(source, 'player')) end

    -- Initialize the Stats system — decode statuses from DB for Stats cache
    -- Type-checked. None stored, each stat starts at its own start value (Stats.initPlayer).
    local dbStatuses = Character.readJson(charData.statuses, ('charId %s statuses'):format(tostring(charData.charId)))

    Stats.initPlayer(source, {
        health   = charData.health or 200,
        armour   = charData.armour or 0,
        statuses = dbStatuses,
    })

    -- Back into the shared world, before playerLoaded is sent, so the client spawns into the real one.
    --
    -- A brand new character keeps the bucket: they are built on the creator's mark, unwatched and
    -- with no traffic in the shot. whip_core:server:creatorDone releases them.
    if not openCreator then
        SetPlayerRoutingBucket(source, 0)
    else
        -- The one legitimate reason creatorDone arrives. It checks this and clears it, so the
        -- bucket switch it performs cannot be replayed by anyone who is not in the creator.
        player._inCreator = true
    end

    -- Send data to client. openCreator opens the creator (client/appearance.lua); isNewCharacter is
    -- only the first load of a character just made.
    -- Left sitting in a car that is still near? Back in it (moves the position to the car first, so
    -- the serialized position is the car's). Only arriving where they left: a spawn picker choice puts
    -- them there instead (the position is moved before the car is looked for near it).
    -- Otherwise on foot, by a car of theirs? (The scenes made with a car: client/arrival.lua.)
    if spawnAt and not openCreator then player.position = spawnAt end
    local wakeIn = not openCreator and not spawnAt and Vehicles.wakeSeatFor(player) or nil
    local nearCar = not openCreator and not wakeIn and Vehicles.nearCarFor(player) or nil
    local serialized = player:serialize()
    serialized.isNewCharacter = isNewCharacter == true
    serialized.openCreator = openCreator
    serialized.wakeIn = wakeIn
    serialized.nearCar = nearCar
    TriggerClientEvent('whip_core:client:playerLoaded', source, serialized)

    -- Send HUD stat definitions (icons, colors, order) then initial values
    TriggerClientEvent('whip_core:client:hudDefs', source, Stats.getHudDefs())

    if Stats and Stats.syncAll then
        Stats.syncAll(source)
    end

    -- Player statebags, through the Sentinel's write-through helper (the single-writer rule,
    -- shared/statebags.lua). Not the character's name or charId: a bag goes to EVERY client; a
    -- script asks GetPlayerFullName (Config.ShowPlayerNames).
    Sentinel.setPlayerKey(source, PLAYER_DEAD_KEY, player.isDead)
    Sentinel.setPlayerKey(source, PLAYER_JOB_KEY, false)  -- not clocked on yet at load time
    Sentinel.setPlayerKey(source, PLAYER_ESCORTED_KEY, false)
    -- The character's facial expression (/mood), for everyone else's client to show. Absent: none.
    Sentinel.setPlayerKey(source, PLAYER_MOOD_KEY, player:getMetadata('mood'))

    Log.write(player.charId, 'login', { detail = player.fullName })

    -- Each sync step on its own: one that throws is printed with its name, and the rest still run,
    -- in this order (whip_core:player:loaded must still fire).
    local function step(name, fn)
        local ok, err = pcall(fn)
        if not ok then
            print(('^1[whip_core] login sync step "%s" failed for %s [%d]: %s^0'):format(
                name, tostring(player.fullName), source, tostring(err)))
        end
    end

    -- Proximity-based ground item sync (only nearby cells, not full cache)
    step('ground items', function()
        local gsPed = GetPlayerPed(source)
        local gsCoords = GetEntityCoords(gsPed)
        local gsRange = Config.GroundItemStreamRange or 100.0
        local gsCellKeys = GroundItems.getNearbyCellKeys(gsCoords.x, gsCoords.y, gsRange)
        GroundSync[source] = { syncedCells = gsCellKeys }
        TriggerClientEvent('whip_core:client:groundItemsSync', source, GroundItems.getItemsInCells(gsCellKeys))
    end)

    -- Container definitions for client-side prop streaming + interaction — what a client draws,
    -- not who owns what (Containers.wireAll)
    step('containers', function()
        TriggerClientEvent('whip_core:client:containersSync', source, Containers.wireAll())
    end)

    -- Send player's vehicles and key cache (wireForOwner: a projection, not the live records).
    step('vehicles', function()
        TriggerClientEvent('whip_core:client:vehiclesSync', source, Vehicles.wireForOwner(player.charId))
        Vehicles.syncKeys(source, player, true)   -- forced: a new character, whatever was sent before
        -- Which trunks and gloveboxes are off (Vehicle Adjustments): the prompts and F2 go by it.
        TriggerClientEvent('whip_core:client:vehicleStorageSync', source, Vehicles.storageWire())
    end)

    -- Garage definitions for blips + interaction (Garages.wire: no spawn point, the server places
    -- retrieved vehicles itself). The bays are sent whole (a spot IS a position). Then which PRIVATE
    -- garages (a property's) this character may use: their bays show only for them.
    step('garages', function()
        TriggerClientEvent('whip_core:client:garagesSync', source, Garages.wire())
        GarageSpots.sync(source)
        Garages.pushAccess(source)
    end)

    -- The catalog of furniture that may be placed.
    step('prop catalog', function() PropCatalog.sync(source) end)

    -- Properties: where each one's space and sign are, its name and whose it is. The lock travels
    -- with the DOORS, which the door sync below carries. Their furniture is NOT sent here: only a
    -- version per room, and a client fetches a room's rows when it comes near it. And which of them
    -- this character holds a key to: their client shows those a manager sign.
    step('properties', function()
        Properties.sync(source)
        Properties.syncKeys(source)
        PropertyObjects.sync(source)
    end)

    -- Shop definitions for NPC/prop streaming + blips (Shops.wire, a projection).
    step('shops', function()
        TriggerClientEvent('whip_core:client:shopsSync', source, Shops.wire())
    end)

    -- Every door, projected (Doors.wire: `requirements` never leaves the server).
    --
    -- Order is load-bearing: below the GroundSync seeding above, so every toggle after this snapshot
    -- reaches the player through cells they hold (doorStateChanged) or as they gain cells
    -- (doorStatesBatch).
    step('doors', function()
        TriggerClientEvent('whip_core:client:doorsSync', source, Doors.wire())
    end)

    -- Persistent zones from DB, the time & weather, and the player's job data.
    step('zones', function()
        TriggerClientEvent('whip_core:client:zonesSync', source, Zones.getDbZonesForSync())
    end)
    step('time', function()
        TriggerClientEvent('whip_core:client:timeSync', source, TimeWeather.getSyncData())
    end)
    step('jobs', function()
        TriggerClientEvent('whip_core:client:jobsSync', source, Jobs.getCharJobs(player.charId))
    end)

    -- Send lightweight inventory sync so item flags + hotbar work immediately (before opening inventory)
    step('inventory flags', function()
        if player.inventory then
            -- Inventory.cachedItemDefs: the one place the definitions are sent; every open after
            -- this leaves them out.
            player._haveItemDefs = true
            TriggerClientEvent('whip_core:client:inventoryFlagsSync', source, Inventory.serialize(player.inventory), Inventory.cachedItemDefs(),
                -- The slot registry rides the login sync: broadcasts fired before this player
                -- connected, so this is their first (and usually only) copy.
                Inventory.getSlotDefsPayload())
        end
    end)

    -- The theme override rides the login sync for the same reason as the slot registry above:
    -- SetActiveTheme's broadcast fired before this player connected. Config.Theme needs no push
    -- here — the client announces that itself (client/ready.lua) — so this only fires when a
    -- skin resource is actually overriding it.
    step('theme', function()
        if Themes.getActive() then
            TriggerClientEvent('whip_core:client:applyTheme', source, Themes.getActive())
        end
    end)

    -- What this character carries as it arrives is the item events' starting point, not a change:
    -- logging in does not "add" everything in the pockets (see Inventory.announceChanges).
    step('item baseline', function() Inventory.resetCarried(source, player) end)

    -- whip_core's own reactions first, as hooks, then whip_core:player:loaded for everyone else,
    -- with the same table as the client's event.
    local loadedPayload = {
        source       = source,
        charId       = player.charId,
        name         = player.fullName,
        newCharacter = serialized.isNewCharacter == true,
        player       = serialized,
    }
    Character.runHooks('loaded', loadedPayload)
    WhipEmit('whip_core:player:loaded', loadedPayload)

    print(('[whip_core] Player loaded: %s [%d] as %s (charId: %d)'):format(
        GetPlayerName(source) or 'Unknown', source, player.fullName, player.charId
    ))
end

--- Load a character for a player. The claim, the one-copy rule and the error cleanup live here;
--- the load itself is loadCharacterInner above.
---
--- One live copy of a character: one that is in the game, or already being loaded, is refused (two
--- sessions would each save over the other). A throw anywhere in the load releases the claim, so the
--- player can try again.
---@param source number
---@param charId number|nil
---@param isNewCharacter boolean|nil
---@param spawnId string|nil  where to arrive (the spawn picker); nil is where they left
function LoadCharacterForPlayer(source, charId, isNewCharacter, spawnId)
    -- Taken before the first yield, and refused if a load is already running for this source.
    -- A refusal with a reason (start-up) is shown, and the character screen comes back.
    local claim, pending = beginLoad(source)
    if not claim then
        if type(pending) == 'string' then refuseLoad(source, pending) end
        return
    end
    ---@cast pending table

    charId = tonumber(charId)
    if not charId or PlayersByCharId[charId] or LoadingCharIds[charId] then
        releaseClaim(source, claim)
        -- 'metadata': another resource is writing this character's row while it is offline (SetPlayerMetadata).
        refuseLoad(source, LoadingCharIds[charId] == 'metadata' and 'That character is being saved. Try again in a moment.'
            or 'That character is already in the game.')
        return
    end
    -- Set BEFORE the first yield, so a second load of the same character is refused the moment this
    -- one starts rather than when it finishes. Holds the source (truthy) for anyone asking.
    LoadingCharIds[charId] = source

    -- The last session's save first: its pockets, row and position are one unit, `player:<charId>`.
    -- If it is still owed (a failed teardown write, a move during it), loading now would read rows
    -- about to change. Write it, or refuse the load until it is.
    local settled = Stores.settle('player:' .. tostring(charId))
    if not settled then
        if LoadingCharIds[charId] == source then LoadingCharIds[charId] = nil end
        releaseClaim(source, claim)
        refuseLoad(source, 'Your last session is still being saved. Try again in a moment.')
        return
    end

    local ok, err = pcall(loadCharacterInner, source, charId, isNewCharacter, claim, pending, spawnId)

    if LoadingCharIds[charId] == source then LoadingCharIds[charId] = nil end

    if not ok then
        print(('[whip_core] ERROR loading character %s for source %d: %s')
            :format(tostring(charId), source, tostring(err)))
        if not Players[source] then
            abandonLoad(source, claim, charId, 'error during load')
            refuseLoad(source, 'Could not load that character. Please try again.')
        end
    end
end

-- ============================================
-- Player Disconnect
-- ============================================

--- Everything tied to the CHARACTER a player is playing, as opposed to their connection.
---
--- One function, two callers: disconnect and logout, so going back to character select leaves none
--- of the old character's world behind (open stores, bag panels, an escort, a job clocked on, a
--- basket's stock, a nozzle in a tank).
---
--- Called BEFORE the save, while Players[source] still resolves: closing a bag panel folds its
--- contents into the player's inventory, and that change has to be in the save that follows.
--- `player` may be nil (a player dropped at character select) — the per-source parts still run.
---@param source number
---@param player table|nil
function ReleaseCharacterSession(source, player)
    -- Release every store this player had open, in one call (Stores._viewing keeps a per-player
    -- index). Save, release, and unload only through Containers.unloadInventory, which refuses while
    -- anyone remains.
    for _, storeId in ipairs(Stores.releaseAllViews(source)) do
        local containerId = storeId:match('^container:(%d+)$')
        if containerId then
            pcall(Containers.saveInventory, tonumber(containerId))
            -- And unloaded if that was the last viewer (unloadInventory refuses while anyone is in it).
            pcall(Containers.unloadInventory, tonumber(containerId))
        else
            local vid, storageType = storeId:match('^vehicle:(%d+):(%a+)$')
            if vid then
                pcall(Vehicles.saveInventory, tonumber(vid), storageType)
            end
        end
    end

    -- Clean up OpenPanel sessions through the shared close: nil panelId = EVERY panel this player had
    -- open. onClose fires only for the LAST one inside a panel.
    if Panels and Panels.hasOpen(source) then
        Panels.closeFor(source, nil, false)
    end

    -- Player-inventory sessions: the one this player had open on somebody, and every one open on
    -- them (Inventory.endPlayerInvSessionsFor).
    Inventory.endPlayerInvSessionsFor(source, player)

    -- Clear bank permission cache for this character
    if player then
        Bank.clearPermCache(player.charId)
        -- With the source on a logout, so the whipJob bag and the client hear it; not on a drop
        -- (nobody is left to tell).
        Jobs.clockOffAll(player.charId, not player.dropped and source or nil)
    end

    -- Not a bare nil: a player who leaves mid-shop may be holding unpaid stock in a basket, and
    -- forgetting the session without putting it back deletes goods the shopkeeper owns.
    Shops.endSession(source)

    -- Every money hold they pay for (a metered service — a pump's fill: server/money_holds.lua) settled for what was
    -- used, before the save, so cash change lands in the pockets that are then written.
    pcall(MoneyHolds.releasePlayer, source)

    -- Release escort state if this player was escorting or being escorted. The escortee half asks
    -- the Sentinel ledger, not the bag (client-writable).
    ReleaseEscortState(source)
    if Sentinel.getTruth(source, PLAYER_ESCORTED_KEY) then
        local holder = Sentinel.getTruth(source, PLAYER_ESCORTER_KEY)
        Sentinel.setPlayerKey(source, PLAYER_ESCORTED_KEY, false)
        Sentinel.setPlayerKey(source, PLAYER_ESCORTER_KEY, nil)
        if holder and Players[holder] then
            TriggerClientEvent('whip_core:client:escortReleased', holder)
        end
    end
    -- And the holder's own record of holding them (events_misc.lua), which the lines above cannot
    -- reach: left behind, the holder could escort nobody else until it happened to be re-read.
    if ForgetEscortsOf then ForgetEscortsOf(source) end

    -- The world cells this character was sent: the next character's load seeds its own.
    GroundSync[source] = nil
end

AddEventHandler('playerDropped', function(reason)
    local source = source

    -- First, before this handler yields on anything: a character load in flight tests its claim
    -- against PendingPlayers.
    PendingPlayers[source] = nil

    local player = Players[source]
    -- closing: see WhipPlayer:logout. dropped: a logout this lands in the middle of stops at its next
    -- step and leaves the rest of the teardown to this handler.
    if player then player.closing = true; player.dropped = true end

    -- The character's world first, while Players[source] still resolves — see the function.
    ReleaseCharacterSession(source, player)

    if player then
        Log.write(player.charId, 'logout', { detail = reason })
        -- Effects end BEFORE the save, as on a logout.
        if Stats and Stats.endEffects then Stats.endEffects(source, 'disconnect') end
        SafeSavePlayer(player, 'disconnect', true)
        Inventory.clearCooldowns(source)
        -- Core's own hooks first (Character.onLife), then whip_core:player:logout (why = 'disconnect').
        local sheet = player:serialize()
        local ended = { source = source, charId = player.charId, player = sheet, why = 'disconnect' }
        Character.runHooks('logout', ended)
        WhipEmit('whip_core:player:logout', ended)
        -- What a listener changed on the character (metadata, a stat) is saved too.
        PlayerRows.saveIfChanged(player)
        -- Clean up Stats system AFTER save but BEFORE removing from Players
        if Stats and Stats.cleanupPlayer then
            Stats.cleanupPlayer(source, 'disconnect')
        end
        Players[source] = nil
        PlayersByCharId[player.charId] = nil
        -- Only if it is still this session, and the account's other session with a character in takes
        -- its place (as WhipPlayer:logout).
        if PlayersByUserId[player.userId] == player then
            PlayersByUserId[player.userId] = nil
            for _, other in pairs(Players) do
                if other.userId == player.userId then PlayersByUserId[player.userId] = other; break end
            end
        end

        -- Drop the position tracking with them (written above), so the next player on this source
        -- doesn't inherit it.
        PlayerRows.forget(source)

        print(('[whip_core] Player saved and removed: %s [%d] (reason: %s)'):format(player.fullName, source, reason))
    end

    -- Connection-scoped state, which a logout keeps.
    DevTools.viewers.vm[source] = nil
    DevTools.viewers.gm[source] = nil
    DevTools.viewers.gim[source] = nil
    DevTools.viewers.ib[source] = nil
    DevTools.viewers.pm[source] = nil
    DevTools.viewers.jm[source] = nil
    DevTools.viewers.sm[source] = nil
    DevTools.viewers.tw[source] = nil
    GroundSync[source] = nil
    DevTools.viewers.pmgr[source] = nil
    DevTools.viewers.sn[source] = nil
    -- The Player Manager shows who is online, and this is where that changes — a kick's answer too
    -- (devtools.lua). Its own thread: a list query has no business delaying a drop.
    if next(DevTools.viewers.pmgr) ~= nil and BroadcastPlayerManagerList then
        CreateThread(BroadcastPlayerManagerList)
    end

    -- Last, after everything above that reads the ledger: the Sentinel's per-source state. Called
    -- here, not from its own playerDropped handler: sentinel.lua loads first and would sweep before
    -- the escort unwind in ReleaseCharacterSession reads it.
    Sentinel.clearSource(source)
end)

-- Saving has no loop here: character rows and positions are write-behind (PlayerRows, player.lua),
-- and inventories flush through Stores.

-- ============================================
-- Logout Event (client → server)
-- ============================================

SecureEvent('whip_core:server:logout', {
    whileDead = true,   -- you can always leave; the dead state is saved with the character
    rateLimit = 2000,
}, function(_, player)
    player:logout()
end)

-- ============================================
-- Resource Stop — Emergency save all players
-- ============================================

-- Freeze Stats cache — block reportVitals from overwriting during shutdown. Step 10 of whip_core's
-- stop (server/lifecycle.lua), before anything is handed back or written.
CoreStop.add(10, 'freeze stats', function()
    if Stats then
        Stats.freeze()
    end
end)

-- Step 60 of whip_core's stop (server/lifecycle.lua): after step 20's hand-backs (panels, baskets,
-- pours), which only queue their writes, and step 40's position marks.
CoreStop.add(60, 'stores: send every owed write', function()
    -- Nothing here may wait: a stop handler that awaits sends one write and is gone. Character rows
    -- and positions are handed over by player.lua's step 40; everything the stores owe is handed over
    -- here, a transaction per group (Stores.dispatchOwed). The results can't be heard, so what is
    -- said is what was SENT.
    local units = Stores.dispatchOwed()
    if units > 0 then
        print(('[whip_core] Resource stopping: dispatched %d pending store write(s) — the results cannot be observed from a stop handler')
            :format(units))
    end
end)

-- Step 50 of the final save (server/lifecycle.lua). txAdmin kicks everyone as the save starts and
-- each drop saves that player (playerDropped above); this waits for those, so step 52 can send what
-- they left owed. Half a second is left for the log and the clock.
FinalSave.add(50, 'kicked players', function(deadline, shutdown)
    local by = deadline - 500
    while shutdown and GetGameTimer() < by do
        local online = false
        for _, p in pairs(Players) do
            if not p.phantom then online = true break end
        end
        if not online then return end
        Wait(50)
    end
end)

-- ============================================
-- Startup
-- ============================================

--- Stop start-up where it is. Nothing further loads, core never reports ready, anyone connecting is
--- told the server did not start (processConnection), and no character can load (beginLoad).
---@param why string
local function haltBoot(why)
    BootHalted = why
    print('^1[whip_core] ===================================================================^0')
    print(('^1[whip_core] STARTUP HALTED: %s (see the lines above).^0'):format(why))
    print('^1[whip_core] Players cannot join until it is fixed. Fix the error, then restart whip_core.^0')
    print('^1[whip_core] ===================================================================^0')
end

AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    -- A mistake in config.lua: shared/config_guard.lua has said where, and prints it again below the other errors.
    if ConfigGuard.problem then
        BootHalted = 'config.lua has a mistake'
        return
    end

    -- ---- 0. The database ----
    --
    -- Reached before anything is built (server/db_health.lua): until oxmysql connects, every query waits without
    -- a word, so whip_core says what to check while it waits.
    bootWaiting = 'waiting for its database'
    local dbOk, dbWhy = DbHealth.waitForDatabase()
    bootWaiting = nil
    if not dbOk then return haltBoot(dbWhy --[[@as string]]) end

    -- ---- 1. The schema ----
    --
    -- Every table, built complete the first time (each module's own CREATE, CreateTable in
    -- server/helpers.lua): an empty database needs nothing run by hand. In this order, because a
    -- foreign key needs the table it points at. One "no" stops start-up here. Whether the database
    -- is new is asked first, before any table is made (the migrations below need to know).
    local newDatabase = Migrations.isNewDatabase()
    local SCHEMA = {
        { 'users and characters', WhipPlayer.ensureTable },
        { 'character portraits',  Portraits.ensureTable },
        { 'character inventory',  Inventory.ensureTable },
        { 'bank',                 Bank.ensureTable },
        { 'containers',           Containers.ensureTable },
        { 'vehicles',             Vehicles.ensureTable },
        { 'shops',                Shops.ensureTable },
        { 'world (time/weather)', TimeWeather.ensureTable },
        { 'doors',                Doors.ensureTable },
        { 'properties',           Properties.ensureTables },
        { 'property furniture',   PropertyObjects.ensureTable },
        { 'bans and admin notes', EnsureAdminTables },
        { 'ground items',         GroundItems.ensureTable },
        { 'jobs',                 Jobs.ensureTable },
        { 'activity log',         Log.ensureTable },
        { 'garages',              Garages.ensureTable },
        { 'garage bays',          GarageSpots.ensureTable },
        { 'prop catalog',         PropCatalog.ensureTable },
        { 'property packs',       PropertyPacks.ensureTable },
        { 'vehicle catalog',      VehicleCatalog.ensureTable },
        { 'zones',                Zones.ensureTable },
        { 'settings',             Settings.ensureTable },
        { 'camera sequences',     CameraSequences.ensureTable },
        { 'item holds',           ItemHolds.ensureTable },
        { 'gives kept for login', PendingGives.ensureTable },
    }
    local broken = {}
    for _, t in ipairs(SCHEMA) do
        if not t[2]() then broken[#broken + 1] = t[1] end
    end
    if #broken > 0 then
        return haltBoot('the database could not be set up — ' .. table.concat(broken, ', '))
    end

    -- Changes to a database that already exists (server/migrations.lua); a new one's tables were
    -- just made complete, so it has none. A failed one halts start-up like a missing table does.
    if Migrations.run(newDatabase) == false then
        return haltBoot('a database migration failed')
    end
    BootHalted = nil

    -- ---- 2. Loading — all or nothing ----
    --
    -- A loader whose read fails answers false, and start-up stops at it: the steps after it would
    -- read "not loaded" as "does not exist" and WRITE (garages deleted, doors and bays duplicated).
    local function loaded(name, fn)
        if fn() == false then
            haltBoot(name .. ' could not be loaded from the database')
            return false
        end
        return true
    end

    -- A restart's last writes land first: the old instance's stop handlers can't wait for their
    -- writes, and on a connection pool a SELECT from this instance could finish before them. So,
    -- within STOP_SETTLE_S of the stop, the loads wait out the rest of it; a cold start doesn't wait.
    local STOP_SETTLE_S = 3
    local stoppedAt = GetResourceKvpInt('whip_core:stoppedAt') or 0
    -- Capped, so a clock that jumped backwards cannot hold start-up for longer than the settle.
    local settle = stoppedAt > 0 and math.min(STOP_SETTLE_S, stoppedAt + STOP_SETTLE_S - os.time()) or 0
    if settle > 0 then
        print(('[whip_core] giving the last instance\'s writes %ds to land before loading'):format(settle))
        Wait(settle * 1000)
    end

    -- Settings first: what is in force must match the database before anything below reads a
    -- setting (the seeds read Config). settings.json already gave both sides most of it at load;
    -- this puts in force whatever the file did not (server/settings.lua).
    if not loaded('settings', Settings.loadAll) then return end
    if not loaded('ground items', GroundItems.loadAll) then return end
    if not loaded('containers', Containers.loadAll) then return end
    -- (Vehicles load AFTER the garages below — see there.)
    if not loaded('jobs', Jobs.loadAll) then return end

    -- Garages, then shops — AFTER containers and jobs, which they reference.
    if not loaded('garages', Garages.loadAll) then return end
    Garages.seedFromConfig()
    -- Vehicles after the garages: Vehicles.loadAll gives a garaged car with no garage the default
    -- one, and asks the garage registry which that is.
    if not loaded('vehicles', Vehicles.loadAll) then return end
    if not loaded('vehicle storage defaults', Vehicles.loadMeta) then return end
    -- After the garages, because a spot's create path validates its garage key against them. No
    -- seeding here: a garage gets its first bay when it is created (GarageSpots.seedGarage), and a
    -- garage an admin left with none keeps none.
    if not loaded('garage bays', GarageSpots.loadAll) then return end
    -- The prop catalog, before any furniture save: the seed decides what is placeable, and
    -- PropertyObjects.replace validates against it.
    if not loaded('prop catalog', PropCatalog.loadAll) then return end
    PropCatalog.seedFromConfig()
    PropCatalog.syncImages()
    if not loaded('shops', Shops.loadAll) then return end
    Shops.seedFromConfig()
    -- Each shop's keeper (an NPC) and its prompt (server/shop_counters.lua): after the jobs, which
    -- name who may manage its stock, and once a character has loaded (Character.afterFirstLoad). A fault
    -- there costs the counters, never the start-up.
    Character.afterFirstLoad(function()
        local countersOk, countersErr = pcall(Shops.openCounters)
        if not countersOk then print('[whip_core:shops] ERROR making the shop counters: ' .. tostring(countersErr)) end
    end)
    if not loaded('doors', Doors.loadAll) then return end
    -- Properties, after the doors they manage: reconcile makes every property's doors match its
    -- unit, owner and keys, and writes nothing where they already do.
    if not loaded('properties', Properties.loadAll) then return end
    Properties.reconcile()
    if not loaded('property furniture', PropertyObjects.loadAll) then return end
    -- Then every running resource's property pack (its manifest's whip_property_pack line). After
    -- the properties are loaded, because applying a pack updates them or makes new ones; an
    -- unchanged pack writes nothing.
    if not loaded('property packs', PropertyPacks.loadAll) then return end
    PropertyPacks.scanAll()
    -- The furniture and its stashes agree (server/property_stashes.lua): after the containers, the
    -- properties, their furniture and the packs. A fault there costs a tidy-up, never the start-up.
    local stashOk, stashErr = pcall(PropertyStashes.reconcile)
    if not stashOk then print('[whip_core:property_stashes] ERROR checking the stashes: ' .. tostring(stashErr)) end
    -- The resources that give homes their looks (server/property_themes.lua), after the properties and
    -- the packs: each is matched to its homes and sent their themes. A fault costs the looks only.
    local themesOk, themesErr = pcall(PropertyThemes.scanAll)
    if not themesOk then print('[whip_core:property_themes] ERROR reading the theme resources: ' .. tostring(themesErr)) end
    if not loaded('zones', Zones.loadAll) then return end
    if not loaded('vehicle catalog', VehicleCatalog.loadAll) then return end
    -- The world row — time anchor, weather, freeze, blackout, scale. Before the first broadcast
    -- goes out, which the sync thread's opening Wait leaves plenty of room for.
    if not loaded('the world clock', TimeWeather.loadAll) then return end
    -- The Camera Creator's saved timelines (server/camera_sequences.lua): read by name when one plays.
    if not loaded('camera sequences', CameraSequences.loadAll) then return end
    -- How items sit in a hand (server/item_holds.lua): give mode's held prop.
    if not loaded('item holds', ItemHolds.loadAll) then return end

    -- ---- 3. Housekeeping ----
    --
    -- After the loads, so a start-up that halted above never runs them. None stops start-up. The log
    -- prune runs after CoreReady, below.
    ExpireBans()
    Bank.checkBalanceRule()
    -- A deleted character's release that failed half way is finished here.
    Character.reconcileDeleted()

    -- No push to connected players: a restart empties Players, and no character loads before
    -- CoreReady, so everyone gets the world from the login sync.

    -- Restart dependent resources (resources with dependency 'whip_core')
    local dependents = Config.DependentResources or {}
    for _, dep in ipairs(dependents) do
        if GetResourceState(dep) ~= 'missing' then
            StopResource(dep)
            Wait(200)
            StartResource(dep)
        end
    end

    -- The readiness signal. Everything whip_core owns (the item registry, panels, use handlers)
    -- lives in memory, so a satellite re-declares after a whip_core restart.
    --
    -- A satellite does not listen to this directly. It writes
    --
    --     Whip.register(RegisterWithWhip)        -- lib/satellite.lua
    --
    -- which is built on this event. It fires when whip_core finishes starting, again every time
    -- whip_core restarts, and again when ANY resource starts while whip_core is up (the re-announce
    -- below); Whip.register filters to the starts that concern it. Registration must be idempotent
    -- (shared/registry.lua makes the same declaration again cost nothing).
    --
    -- It says why: { reason = 'coreStarted' } here (whip_core remembers nothing, register
    -- everything), and { reason = 'resourceStarted', resources = { ... } } from the re-announce.
    CoreReady = true
    -- The settings pages of the items registered while whip_core started (config.lua's), now that
    -- what is saved has been read: before any satellite registers its own (server/item_settings.lua).
    ItemSettings.declareWaiting()
    -- The Director, the Systems Creator and the permission grants (CoreStart.add, server/lifecycle.lua):
    -- each in its own thread, so they begin after the announce below.
    CoreStart.run()
    TriggerEvent('whip_core:onReady', { reason = 'coreStarted' })
    TriggerClientEvent('whip_core:client:coreReady', -1)

    -- The activity log's retention, once players can join. Its own thread; it pauses between chunks.
    CreateThread(Log.prune)
end)

--- Has whip_core finished starting?
---
--- For code that needs to ASK rather than be told — a command that must refuse while core is
--- down, say. Registration does not need it: the event above covers every case on its own.
---@return boolean
exports('IsReady', function()
    return CoreReady == true
end)

-- ============================================
-- Re-announcing for late starters
-- ============================================
--
-- An event cannot reach a listener that was not there when it fired, so whip_core announces again
-- when a resource starts while it is ready: the newcomer's handler is registered by then and hears
-- what it missed.
--
-- Coalesced to one announce per tick, naming every resource in the burst, so a satellite can tell
-- "that was me starting" from "someone else started".
local reannounceQueued = nil   -- the names collected this tick, or nil when none is queued

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() then return end
    if not CoreReady then return end
    if reannounceQueued then
        reannounceQueued[#reannounceQueued + 1] = resourceName
        return
    end

    reannounceQueued = { resourceName }
    CreateThread(function()
        -- One tick, so a burst of resources starting together produces one announcement — and
        -- so the newcomer's own scripts have finished loading before it is told anything.
        Wait(0)
        local started = reannounceQueued
        reannounceQueued = nil
        if CoreReady then
            TriggerEvent('whip_core:onReady', { reason = 'resourceStarted', resources = started })
        end
    end)
end)

--- whip_core is going down. Satellites that care can stop trusting it. Step 10 of whip_core's stop
--- (server/lifecycle.lua).
CoreStop.add(10, 'not ready', function()
    CoreReady = false
    -- When the stop handlers handed their last writes to oxmysql, for the next start to give them
    -- time to land — see STOP_SETTLE_S in the start handler.
    SetResourceKvpInt('whip_core:stoppedAt', os.time())
end)
