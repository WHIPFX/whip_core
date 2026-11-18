-- ============================================
-- Admin / Debug Commands — server/commands.lua
-- ============================================
--
-- ONE KIND. Every command here answers to the server console and to whip.devtools with developer mode on,
-- the one permission the rest of whip's admin tools use (devCommand below). What one prints goes to the
-- console, or to the chat of the admin who typed it (linesTo).

--- The in-game admin commands: [name] = true. whip_chat asks (GetCommandAce) so it only suggests
--- them to players who may run them.
local DEV_COMMANDS = {}

--- An admin command a player can type: allowed to the console and to whip.devtools.
---
--- One permission: FiveM lets the command through (not `RegisterCommand(..., true)`, which gates on
--- its own `command.<name>` ACE) and the handler asks whip.devtools, and says so when refused.
---@param name string
---@param fn fun(source: number, args: table, raw: string)
---@param help table|nil  { help = 'What it does', params = { { name = 'id', help = '...' } } } for the chat's suggestion
local function devCommand(name, fn, help)
    DEV_COMMANDS[name] = type(help) == 'table' and help or true
    RegisterCommand(name, function(source, args, raw)
        if source ~= 0 and not DevTools.isAllowed(source) then
            ShowError(source, DevTools.isEligible(source) and DevTools.OFF_REASON or 'That command needs whip.devtools')
            return
        end
        return fn(source, args, raw)
    end, false)
end

--- Answer whoever ran the command: the console gets a print, a player a toast.
---@param source number
---@param msg string
---@param kind string|nil  'success' | 'error' | 'info' (default 'info')
local function reply(source, msg, kind)
    if source == 0 then
        print('[whip_core] ' .. msg)
    else
        NotifyPlayer(source, msg, kind or 'info')
    end
end

--- The ACE a whip_core command needs beyond FiveM's own, or nil. For chat suggestions (whip_chat).
---@param name string
---@return string|nil
exports('GetCommandAce', function(name)
    return DEV_COMMANDS[name] and 'whip.devtools' or nil
end)

-- ============================================
-- Chat suggestions for the admin commands
-- ============================================
-- Staff get these as chat suggestions when their character loads, and again on whip_core's start: one event each,
-- only to players holding whip.devtools. The handlers still check developer mode when a command is run.

--- Send the admin commands to one player's chat, if they hold whip.devtools.
---@param src number
local function suggestCommandsTo(src)
    src = tonumber(src)
    if not src or not IsPlayerAceAllowed(src, 'whip.devtools') then return end
    local list = {}
    for name, info in pairs(DEV_COMMANDS) do
        local help = type(info) == 'table' and info or nil
        list[#list + 1] = { name = '/' .. name, help = help and help.help or '', params = help and help.params or nil }
    end
    TriggerClientEvent('chat:addSuggestions', src, list)
end

Character.onLife('loaded', function(e) suggestCommandsTo(e.source) end)

-- A restart of whip_core: the commands are registered again, so the staff in the game get them again. After a
-- moment, so every devCommand below (and in other files) has been made.
CreateThread(function()
    Wait(2000)
    for _, id in ipairs(GetPlayers()) do suggestCommandsTo(id) end
end)

--- Where a command's lines go: the server console, or the chat of the admin who typed it.
---@param source number
---@return fun(line: string)
local function linesTo(source)
    if source == 0 then return function(line) print('[whip_core] ' .. line) end end
    return function(line) TriggerClientEvent('chat:addMessage', source, { args = { '[whip_core]', line } }) end
end

-- /whip_players — List all active players
devCommand('whip_players', function(source)
    local say = linesTo(source)
    local count, phantoms = 0, 0
    for src, player in pairs(Players) do
        if player.phantom then
            -- Counted, not listed. Printing five hundred fake rows would bury the real ones, and
            -- during a load test the useful figure is simply how many are in there.
            phantoms = phantoms + 1
        else
            count = count + 1
            say(('[%d] %s (userId: %d, charId: %d, cash: $%d)'):format(
                src, player.fullName, player.userId, player.charId, player:getCash()
            ))
        end
    end
    say(('Total active players: %d'):format(count))
    if phantoms > 0 then
        say(('...plus %d load-test phantoms (/testloadstop clears them)'):format(phantoms))
    end
end)

-- /whip_pending — List pending players (connected but no character selected)
devCommand('whip_pending', function(source)
    local say = linesTo(source)
    local count = 0
    for src, data in pairs(PendingPlayers) do
        count = count + 1
        say(('[%d] userId: %d, license: %s'):format(src, data.userId, data.license))
    end
    say(('Total pending players: %d'):format(count))
end)

-- /vector2, /vector3, /vector4 and /heading — where you stand, on your clipboard, ready to paste into a config
-- ("vector4(215.76, -810.12, 30.73, 157.48)"). Short forms: /vec (a vector4, the usual one), /vec2, /vec3, /vec4.
-- In-game only. Your game reads the position and copies it, the same way /w → Coords does with G
-- (tools/coords.lua whip_core:client:copyCoords): one format for both.
local COPY_COMMANDS = {
    vector2 = 'vector2', vector3 = 'vector3', vector4 = 'vector4', heading = 'heading',
    vec = 'vector4', vec2 = 'vector2', vec3 = 'vector3', vec4 = 'vector4',
}
for name, kind in pairs(COPY_COMMANDS) do
    devCommand(name, function(source)
        if source == 0 then
            print('[whip_core] This command must be run in-game')
            return
        end
        TriggerClientEvent('whip_core:client:copyCoords', source, kind)
    end, { help = kind == 'heading' and 'Copy the way you face (staff)' or ('Copy where you stand as a %s (staff)'):format(kind) })
end

-- /whip_save — Force save all players
devCommand('whip_save', function(source)
    local say = linesTo(source)
    local count = 0
    for _, player in pairs(Players) do
        -- SafeSavePlayer rather than player:save(), which is the difference between a save that is
        -- guarded and one that is not. It is the single funnel every other teardown path already
        -- uses: it pcalls, it saves the inventory as well as the row, and it refuses load-test
        -- phantoms — which have no character row and would otherwise be written here.
        if not player.phantom then
            SafeSavePlayer(player, 'whip_save')
            count = count + 1
        end
    end
    say(('Saved %d player(s)'):format(count))
end)

-- Cash is an item (banknotes, the key 'cash'), so there is no cash command:
--
--     whip_giveitem <charId> cash 500

-- /whip_bank <playerId> — Show a player's bank accounts
devCommand('whip_bank', function(source, args)
    local say = linesTo(source)
    local targetId = tonumber(args[1])
    if not targetId then
        say('Usage: whip_bank <playerId>')
        return
    end

    local player = Players[targetId]
    if not player then
        say('Player not found or not loaded')
        return
    end

    local accounts = Bank.GetCharacterAccounts(player.charId)
    say(('Bank accounts for %s (charId: %d):'):format(player.fullName, player.charId))
    for _, acc in ipairs(accounts) do
        say(('  [%d] %s (%s) — $%d — %s%s'):format(
            acc.accountId, acc.accountNumber, acc.type, acc.balance,
            acc.role,
            DbBool(acc.isDefault) and ' [DEFAULT]' or ''
        ))
    end
end)

-- Helper: find active player by charId, through the global index (PlayersByCharId).
---@return WhipPlayer|nil player
---@return number|nil source  set whenever player is
local function GetPlayerByCharId(charId)
    local player = PlayersByCharId and PlayersByCharId[charId] or nil
    if player then return player, player.source end
    return nil, nil
end

-- /whip_giveitem [charId] <item> [amount] — Give an item to a player; with no charId, to yourself
-- A number first is a charId; anything else is the item.
devCommand('whip_giveitem', function(source, args)
    local usage = 'Usage: whip_giveitem [charId] <item> [amount] — no charId gives it to you'

    local charId, item, amount
    if tonumber(args[1]) then
        charId, item, amount = tonumber(args[1]), args[2], tonumber(args[3]) or 1
    elseif args[1] then
        if source == 0 then
            reply(source, 'The console has no character: whip_giveitem <charId> <item> [amount]', 'error')
            return
        end
        local me = Players[source]
        if not me then
            reply(source, 'You have no character loaded', 'error')
            return
        end
        charId, item, amount = me.charId, args[1], tonumber(args[2]) or 1
    end

    if not charId or not item then
        reply(source, usage, 'error')
        return
    end

    local player, playerSrc = GetPlayerByCharId(charId)
    if not player then
        reply(source, ('No active player with charId %d'):format(charId), 'error')
        return
    end
    ---@cast playerSrc -nil

    if not player.inventory then
        reply(source, 'That player has no inventory loaded', 'error')
        return
    end

    if not Config.Items[item] then
        reply(source, 'Unknown item: ' .. item, 'error')
        return
    end

    -- A give: through Inventory.giveOrDrop, so a full inventory drops at their feet rather than making
    -- the console say "Failed" while the admin wonders where the item went. This also drops
    -- fifteen lines of hand-rolled sync — a serialize, a weights table built by naming
    -- containers, and a manual item:added — all of which Inventory.giveOrDrop does, and one of which
    -- (the weights literal) was a container list in disguise waiting to go stale.
    local ok, err, placement = Inventory.giveOrDrop(playerSrc, player, item, amount, nil, {
        container = 'player',
        reason    = 'admin command whip_giveitem, run by ' .. (source == 0 and 'the console' or (GetPlayerName(source) or ('#' .. source))),
    })
    if ok then
        reply(source, ('Gave %dx %s to %s (charId: %d)%s'):format(
            amount, item, player.fullName, charId,
            placement == 'ground' and ' — INVENTORY FULL, dropped at their feet' or ''), 'success')
    else
        reply(source, ('Failed: %s'):format(err or 'Unknown error'), 'error')
    end
end)

-- /whip_removeitem <charId> <item> [amount] — Remove an item from a player
devCommand('whip_removeitem', function(source, args)
    local charId = tonumber(args[1])
    local item = args[2]
    local amount = tonumber(args[3]) or 1

    if not charId or not item then
        reply(source, 'Usage: whip_removeitem <charId> <item> [amount]', 'error')
        return
    end

    local player, playerSrc = GetPlayerByCharId(charId)
    if not player then
        reply(source, ('No active player with charId %d'):format(charId), 'error')
        return
    end
    ---@cast playerSrc -nil

    -- The same path as the RemoveItem export: every container the player carries, and saved
    -- through the store. This removed from the main grid only and wrote with Inventory.save, which
    -- neither knows about an in-flight flush nor tells anyone else looking at the inventory.
    local ok, err = Inventory.removeItemAcrossContainers(player.inventory, item, amount)
    if ok then
        local why = 'admin command whip_removeitem, run by ' .. (source == 0 and 'the console' or (GetPlayerName(source) or ('#' .. source)))
        Log.lost(player.charId, item, amount, why)
        -- The push announces whip_core:item:removed (Inventory.announceChanges); this says why.
        Inventory.noteChangeReason(playerSrc, why, 'by whip_core')
        Inventory.syncAndFlush(playerSrc, player)
        reply(source, ('Removed %dx %s from %s (charId: %d)'):format(amount, item, player.fullName, charId), 'success')
    else
        reply(source, ('Failed: %s'):format(err or 'Unknown error'), 'error')
    end
end)

-- /whip_inventory <charId> — Show a player's inventory
devCommand('whip_inventory', function(source, args)
    local charId = tonumber(args[1])
    if not charId then
        reply(source, 'Usage: whip_inventory <charId>', 'error')
        return
    end

    local player = GetPlayerByCharId(charId)
    if not player then
        reply(source, ('No active player with charId %d'):format(charId), 'error')
        return
    end

    -- The full listing goes to the server console; an admin in game also gets it in one toast,
    -- shortened.
    print(('[whip_core] Inventory for %s (charId: %d):'):format(player.fullName, charId))
    local summary, count = {}, 0
    for container, slots in pairs(player.inventory) do
        if type(slots) == 'table' then
            local weight = Inventory.getWeight(player.inventory, container)
            local maxWeight = Config.MaxWeight[container] or 0
            print(('  %s (%.2f/%.2f kg):'):format(container, weight, maxWeight))
            for slot, data in pairs(slots) do
                local def = Config.Items[data.item]
                local name = def and def.name or data.item
                print(('    [%d] %s x%d'):format(slot, name, data.amount))
                count = count + 1
                if #summary < 12 then summary[#summary + 1] = ('%s x%d'):format(name, data.amount) end
            end
        end
    end
    if source ~= 0 then
        NotifyPlayer(source, ('%s: %s%s'):format(player.fullName,
            count == 0 and 'nothing' or table.concat(summary, ', '),
            count > #summary and (' (+%d more — full list in the server console)'):format(count - #summary) or ''),
            'info', 10000)
    end
end)

-- /whip_deposit <playerId> <amount> — Deposit into player's default account
devCommand('whip_deposit', function(source, args)
    local say = linesTo(source)
    local targetId = tonumber(args[1])
    local amount = tonumber(args[2])

    if not targetId or not amount then
        say('Usage: whip_deposit <playerId> <amount>')
        return
    end

    local player = Players[targetId]
    if not player then
        say('Player not found or not loaded')
        return
    end

    local account = Bank.GetDefaultAccount(player.charId)
    if not account then
        say('No default account found')
        return
    end

    -- A SYSTEM move: an admin is creating money, not the player moving theirs, so it goes through
    -- SystemDeposit (no player permission check) like every other system payment.
    local ok, err = Bank.SystemDeposit(account.accountId, amount, 'Admin deposit')
    if ok then
        say(('Deposited $%d into %s for %s'):format(amount, account.accountNumber, player.fullName))
        -- Money made in game by an admin: the console keeps who.
        if source ~= 0 then
            print(('[whip_core] %s [%d] deposited $%d into %s for %s via /whip_deposit')
                :format(GetPlayerName(source) or '?', source, amount, account.accountNumber, player.fullName))
        end
    else
        say(('Deposit failed: %s'):format(err))
    end
end)

-- ============================================
-- /whipsaves — saves the database keeps refusing
-- ============================================
--
-- A save that fails five times in a row is stuck: kept and retried every minute, never dropped
-- (stores.lua, quarantine). A poisoned row never lands and its character can't log back in, so fix
-- the cause, or discard it here as a last resort (its changes and everything saved with it are lost).

devCommand('whipsaves', function(source, args)
    if args[1] == 'drop' then
        local unit = tostring(args[2] or '')
        local dropped = Stores.discardStuck(unit)
        if #dropped == 0 then
            reply(source, ('"%s" is not a stuck save. /whipsaves lists them.'):format(unit), 'error')
            return
        end
        reply(source, ('Discarded the unsaved changes of %s.'):format(table.concat(dropped, ', ')), 'success')
        return
    end

    local stuck = Stores.stuckUnits()
    if #stuck == 0 then
        reply(source, 'No stuck saves.', 'success')
        return
    end
    local now = GetGameTimer()
    for _, s in ipairs(stuck) do
        reply(source, ('%s — %d failed saves over %d s: %s'):format(s.unit, s.fails, (now - (s.since or now)) // 1000, tostring(s.lastErr)))
    end
    reply(source, '/whipsaves drop <unit> discards one (and everything saved with it) for good.')
end)

-- ============================================
-- Ground Item Admin Commands
-- ============================================

-- /whip_clearground [radius] — Clear ground items near the calling player (or all within radius from console)
devCommand('whip_clearground', function(source, args)
    local radius = tonumber(args[1]) or 10.0

    if source == 0 then
        -- Console: need coords from first arg pair or just clear everything nearby a default
        print(('[whip_core] Use whip_clearallground to clear all, or run in-game with /whip_clearground [radius]'))
        return
    end

    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then
        reply(source, 'Could not find your ped', 'error')
        return
    end

    local coords = GetEntityCoords(ped)
    local count = GroundItems.clearNearby(coords.x, coords.y, coords.z, radius)
    local msg = ('Cleared %d ground item(s) within %.0fm'):format(count, radius)
    print(('[whip_core] %s (by player %d)'):format(msg, source))
    -- On the record, as the Ground Item Manager's delete buttons are: items leaving
    -- the game write a 'lost' row, or an admin's clear-out looks like items vanishing.
    local who = Players[source]
    Log.write(who and who.charId or nil, 'lost', {
        detail = ('%d ground item(s) within %.0fm cleared by admin command whip_clearground'):format(count, radius),
        x = coords.x, y = coords.y, z = coords.z,
    })
    reply(source, msg, 'success')
end)

-- /whip_clearallground — Clear ALL ground items server-wide (console or in-game)
devCommand('whip_clearallground', function(source)
    local count = GroundItems.clearAll()
    local msg = ('Cleared ALL %d ground item(s) server-wide'):format(count)
    if source ~= 0 then print(('[whip_core] %s (by player %d)'):format(msg, source)) end
    local who = source ~= 0 and Players[source] or nil
    Log.write(who and who.charId or nil, 'lost', {   -- as above
        detail = ('all %d ground item(s) cleared by admin command whip_clearallground, run by %s')
            :format(count, source == 0 and 'the console' or (GetPlayerName(source) or ('#' .. source))),
    })
    reply(source, msg, 'success')
end)

-- /whip_spawnground <item> [amount] — Debug: spawn a ground item at the calling player's feet
devCommand('whip_spawnground', function(source, args)
    if source == 0 then
        print('[whip_core] This command must be run in-game')
        return
    end

    local item   = args[1]
    -- A whole number, 1 or more, as CreateGroundItem holds it.
    local amount = Sanitize.amount(args[2], 1)

    if not item then
        reply(source, 'Usage: whip_spawnground <item> [amount]', 'error')
        return
    end
    if not amount then
        reply(source, Sanitize.AMOUNT_ERR, 'error')
        return
    end

    if not Config.Items[item] then
        reply(source, 'Unknown item: ' .. item, 'error')
        return
    end

    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return end

    local coords  = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)

    -- Offset slightly in front of the player
    local rad = heading * math.pi / 180.0
    local x = coords.x - math.sin(rad) * 1.0
    local y = coords.y + math.cos(rad) * 1.0
    local z = coords.z - 0.5

    local player = Players[source]
    local charId = player and player.charId or nil

    local data = GroundItems.create(item, amount, nil, x, y, z, heading, charId)
    if data then
        local msg = ('Spawned ground item: %s x%d (id: %d)'):format(item, amount, data.id)
        print(('[whip_core] %s'):format(msg))
        -- An item from nothing is a 'gained' row, as the CreateGroundItem export writes.
        Log.write(charId, 'gained', {
            itemKey = item, amount = amount,
            detail  = 'admin command whip_spawnground, run by ' .. (GetPlayerName(source) or ('#' .. source)) .. ' · on the ground',
            x = x, y = y, z = z,
        })
        reply(source, msg, 'success')
    else
        reply(source, 'Failed to spawn ground item', 'error')
    end
end)

-- /whip_givekey <charId> <vehicleId> — Give a vehicle key to a player
devCommand('whip_givekey', function(source, args)
    local charId    = tonumber(args[1])
    local vehicleId = tonumber(args[2])

    if not charId or not vehicleId then
        reply(source, 'Usage: whip_givekey <charId> <vehicleId>', 'error')
        return
    end

    local player, playerSrc = GetPlayerByCharId(charId)
    if not player then
        reply(source, ('No active player with charId %d'):format(charId), 'error')
        return
    end
    ---@cast playerSrc -nil

    local ok, msg = Vehicles.giveKey(playerSrc, player, vehicleId)
    reply(source, ('giveKey: %s'):format(tostring(msg)), ok and 'success' or 'error')
end)

-- /whip_groundcount — Show how many ground items exist
devCommand('whip_groundcount', function(source)
    local count = 0
    for _ in pairs(GroundItems.cache) do count = count + 1 end
    reply(source, ('Ground items in world: %d'):format(count), 'info')
end)

-- ============================================
-- Death / Revive Commands
-- ============================================

-- /whip_revive <charId> — Revive a character by charId
devCommand('whip_revive', function(source, args)
    local charId = tonumber(args[1])
    if not charId then
        local msg = 'Usage: /whip_revive <charId>'
        if source == 0 then
            print('[whip_core] ' .. msg)
        else
            ShowError(source, msg)
        end
        return
    end

    local target, targetSrc = GetPlayerByCharId(charId)
    if not target then
        local msg = ('No active player with charId %d'):format(charId)
        if source == 0 then
            print('[whip_core] ' .. msg)
        else
            ShowError(source, msg)
        end
        return
    end
    ---@cast targetSrc -nil

    if not target.isDead then
        local msg = ('%s is not dead'):format(target.fullName)
        if source == 0 then
            print('[whip_core] ' .. msg)
        else
            ShowError(source, msg)
        end
        return
    end

    MarkPlayerAlive(targetSrc, target, 'revive:admin')
    TriggerClientEvent('whip_core:client:revive', targetSrc)

    local msg = ('Revived %s (charId: %d)'):format(target.fullName, charId)
    if source == 0 then
        print('[whip_core] ' .. msg)
    else
        ShowSuccess(source, msg)
    end
    print(('[whip_core] %s revived by source %d'):format(target.fullName, source))
end)

-- /whip_reviveme — Revive yourself
devCommand('whip_reviveme', function(source)
    if source == 0 then
        print('[whip_core] This command must be run in-game')
        return
    end

    local player = Players[source]
    if not player then
        ShowError(source, 'No character loaded')
        return
    end

    if not player.isDead then
        ShowError(source, 'You are not dead')
        return
    end

    MarkPlayerAlive(source, player, 'revive:self')
    TriggerClientEvent('whip_core:client:revive', source)
    ShowSuccess(source, 'You have been revived')
    print(('[whip_core] %s [%d] self-revived via /whip_reviveme'):format(player.fullName, source))
end)

-- /whip_statebag [id] — Print all statebag values for a player
devCommand('whip_statebag', function(source, args)
    local say = linesTo(source)
    local id = tonumber(args[1])
    if not id then
        say('Usage: whip_statebag <serverId>')
        return
    end

    local name = GetPlayerName(id)
    if not name then
        say(('No player with source %d'):format(id))
        return
    end

    -- Both columns on purpose: `bag` is what replicated (client-writable), `truth` is the
    -- Sentinel ledger (what the server wrote). A row where they differ is a live tamper
    -- the Sentinel hasn't corrected yet — or a Sentinel bug; either way you want to see it.
    local state = Player(id).state
    say(('Statebags for %s [%d]  (bag | truth):'):format(name, id))
    for _, key in ipairs({
        PLAYER_DEAD_KEY, PLAYER_JOB_KEY,
        PLAYER_ESCORTED_KEY, PLAYER_ESCORTER_KEY, PLAYER_DMGMOD_KEY, PLAYER_MELEEMOD_KEY,
        PLAYER_MOOD_KEY,
    }) do
        say(('  %-14s = %s | %s'):format(key, tostring(state[key]), tostring(Sentinel.getTruth(id, key))))
    end
end)

-- /tp, /tpto and /tpm — move yourself while you build, test or help someone. In-game only (the console has no body).
-- The move is the client's fade teleport (client/main.lua): behind a fade, onto the ground when no height is given,
-- and with the car when you are driving one. Every teleport goes on the admin's activity log (DevTools.logTeleport).
-- Going to a player is DevTools.goToPlayer (server/devtools.lua), shared with the Player Manager's Teleport To.
-- The third argument of each is its line in the staff's chat suggestions (a devCommand without them ignores it).
local TP_LIMIT_XY, TP_Z_MIN, TP_Z_MAX = 10000.0, -200.0, 2700.0

--- The numbers in what was typed, however it was copied: "x y z h", "x, y, z", "vector3(x, y, z)", "vec4(...)".
--- Words go first, so the 4 of vec4 is not one of them.
---@param typed string
---@return number[]
local function typedNumbers(typed)
    local out = {}
    for n in typed:gsub('%a[%w_]*', ' '):gmatch('-?%d+%.?%d*') do out[#out + 1] = tonumber(n) end
    return out
end

-- /tp x y [z] [heading] — to coordinates (no z: onto the ground there); /tp <serverId> — to a player
devCommand('tp', function(source, args, raw)
    if source == 0 then
        print('[whip_core] This command must be run in-game')
        return
    end
    local n = typedNumbers((raw or ''):gsub('^%S+%s*', ''))

    -- One whole number: a player's server id (the same as /tpto <id>).
    if #n == 1 and #args == 1 and math.type(n[1]) == 'integer' then
        local ok, msg = DevTools.goToPlayer(source, n[1])
        if not ok then reply(source, msg, 'error') end
        return
    end

    if #n < 2 then
        return reply(source, 'Use /tp x y [z] [heading], or /tp <server id>', 'error')
    end
    local x, y, z, h = n[1], n[2], n[3], n[4]
    if math.abs(x) > TP_LIMIT_XY or math.abs(y) > TP_LIMIT_XY or (z and (z < TP_Z_MIN or z > TP_Z_MAX)) then
        return reply(source, 'Those coordinates are off the map', 'error')
    end
    TriggerClientEvent('whip_core:client:fadeTeleport', source, x + 0.0, y + 0.0, z and z + 0.0, h and h + 0.0, true)
    DevTools.logTeleport(source, ('to %.1f, %.1f%s'):format(x, y, z and (', %.1f'):format(z) or ''))
end, { help = 'Teleport: to x y [z] [heading], or to a player by server id (staff)', params = { { name = 'x y [z] or id', help = 'Coordinates, or a server id' } } })

-- /tpto <server id> — to a player. The same as /tp <id>, under a name that cannot be read as coordinates.
devCommand('tpto', function(source, args)
    if source == 0 then
        print('[whip_core] This command must be run in-game')
        return
    end
    local id = math.tointeger(tonumber(args[1]))
    if not id or id < 1 or args[2] ~= nil then
        return reply(source, 'Use /tpto <server id>', 'error')
    end
    local ok, msg = DevTools.goToPlayer(source, id)
    if not ok then reply(source, msg, 'error') end
end, { help = 'Go to a player (staff)', params = { { name = 'id', help = 'Their server id' } } })

-- /tpm — to your map waypoint, onto the ground there (the waypoint is on your game: it goes from there)
devCommand('tpm', function(source)
    if source == 0 then
        print('[whip_core] This command must be run in-game')
        return
    end
    TriggerClientEvent('whip_core:client:tpWaypoint', source)
    DevTools.logTeleport(source, 'to their map waypoint')
end, { help = 'Go to your map waypoint (staff)' })
