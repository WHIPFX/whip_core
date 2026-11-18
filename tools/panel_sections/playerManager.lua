-- ============================================
-- /whip SECTION — Player Manager (client wiring)
-- ============================================
--
-- Replaces the Player Manager blocks in tools/misc_tools.lua. The section lifecycle,
-- the data forwards, and the plm* mutation callbacks live here, moved verbatim
-- (plmClose retired — the shell owns the close path now). Every server event and
-- Callback named here is UNCHANGED from the standalone tool — the server never
-- noticed the consolidation.
--
-- PREFIX CAUTION: pmGetAllUsers / pmGetUserDetail are PLAYER Manager traffic despite the
-- pm prefix; the Phone Manager owns a separate pm* family (panel_sections/phones.lua). The
-- refresh broadcast is plmRefresh, so the two never cross.
--
-- DETAIL FLOW: JS fires
-- nuiCallback('plmSelectUser', { userId, session }) → the callback below runs
-- Callback('whip_core:pmGetUserDetail') in a thread → the answer forwards as
-- WhipPanelData('playerManager', 'detail', detail), the panel framing of the old
-- SendNUIMessage({ action = 'pmShowDetail', … }) — the JS consumes it in
-- onData('detail', …). Mutations that refresh the pane reuse the same forward.

PanelSections['playerManager'] = {
    enter = function()
        CreateThread(function()
            -- pmGetAllUsers is SecureCallback rate-limited server-side (250ms, burst 5)
            -- and answers nil when tripped — rendered as an empty list, never an error.
            -- Asking also registers this client as a pmgr viewer for refresh broadcasts.
            local users = Callback('whip_core:pmGetAllUsers')
            WhipPanelData('playerManager', 'all', { users = users or {} })
        end)
    end,
    leave = function()
        -- Deregisters the viewer server-side — the plmClosed-leak class the shell's
        -- close funnel exists to prevent.
        TriggerServerEvent('whip_core:server:plmClosed')
    end,
}

-- Server broadcast after another admin's ban/unban. The payload already carries the
-- fresh list, so it forwards straight through — the old handler did the same, no
-- client-side refetch. Still guarded on data.users, which costs nothing.
RegisterNetEvent('whip_core:client:plmRefresh', function(data)
    if data and data.users then
        WhipPanelData('playerManager', 'refresh', { users = data.users })
    end
end)

-- ---- mutations (moved verbatim from tools/misc_tools.lua; the SendNUIMessage
-- pmRefresh/pmShowDetail responses became the equivalent WhipPanelData forwards) ----

RegisterNUICallback('plmSelectUser', function(data, cb)
    CreateThread(function()
        -- session: which of the account's characters in the row was (0, or none: its first).
        local detail = Callback('whip_core:pmGetUserDetail', data.userId, data.session or 0)
        if detail then
            WhipPanelData('playerManager', 'detail', detail)
        end
    end)
    cb('ok')
end)

-- ---- a picture of their game (server/devtools.lua pmShot) ----
-- The page asks when it opens an online player's page with no picture of theirs from the last few minutes, and on
-- Capture Player's Game. The picture comes back on its own, maybe after the panel has closed: the page keeps it.

RegisterNUICallback('plmShot', function(data, cb)
    TriggerServerEvent('whip_core:server:pmShot', tonumber(data.targetSource) or 0)
    cb('ok')
end)

-- pos: where they stood when it came back, for the map beside it.
RegisterNetEvent('whip_core:client:plmShot', function(target, data, why, pos)
    WhipPanelData('playerManager', 'shot', {
        source = tonumber(target) or 0,
        data = type(data) == 'string' and data or nil,
        why = type(why) == 'string' and why or nil,
        pos = type(pos) == 'table' and pos or nil,
    })
end)

-- ---- activity log ----
-- Player timeline pages ride the playerManager section; an item timeline is its own
-- section ('itemlog') so clicking an item opens a separate view without losing the
-- player's page. Both are plain Callback → WhipPanelData forwards.

RegisterNUICallback('alPlayer', function(data, cb)
    CreateThread(function()
        local rows = Callback('whip_core:alPlayer', data.userId, data.beforeId or 0)
        WhipPanelData('playerManager', 'activity',
            { rows = rows or {}, more = (data.beforeId or 0) ~= 0 })
    end)
    cb('ok')
end)

RegisterNUICallback('alItem', function(data, cb)
    CreateThread(function()
        local rows = Callback('whip_core:alItem', data.uid, data.beforeId or 0)
        WhipPanelData('itemlog', 'timeline',
            { uid = data.uid, rows = rows or {}, more = (data.beforeId or 0) ~= 0 })
    end)
    cb('ok')
end)

-- Teleport to a logged landing spot (a thrown/placed item's coords row). Local-ped
-- teleport — the admin moves THEMSELVES; the panel closes first so they arrive
-- looking at the world, not at glass.
RegisterNUICallback('alTeleport', function(data, cb)
    cb('ok')
    local x, y, z = tonumber(data.x), tonumber(data.y), tonumber(data.z)
    if not x or not y or not z then return end
    WhipPanelClose()
    SetPedCoordsKeepVehicle(PlayerPedId(), x, y, z + 0.5)
end)


-- THE SERVER ANSWERS THESE: it pushes the list (plmRefresh, above) and the changed user's detail
-- (plmDetail, below) once the write is done; a kick's list arrives when the player has actually left.

RegisterNetEvent('whip_core:client:plmDetail', function(detail)
    if type(detail) == 'table' then
        WhipPanelData('playerManager', 'detail', detail)
    end
end)

RegisterNUICallback('plmKick', function(data, cb)
    TriggerServerEvent('whip_core:server:pmKick', data.targetSource, data.reason or 'Kicked by admin')
    cb('ok')
end)

RegisterNUICallback('plmBan', function(data, cb)
    local seconds = 0
    if not data.permanent then
        seconds = (tonumber(data.days) or 0) * 86400 + (tonumber(data.hours) or 0) * 3600 + (tonumber(data.minutes) or 0) * 60
    end
    -- Permanent travels as its own flag: 0 seconds does not mean "forever" to the server.
    TriggerServerEvent('whip_core:server:pmBan', data.userId, data.reason or 'No reason provided', seconds,
        data.permanent == true)
    cb('ok')
end)

RegisterNUICallback('plmUnban', function(data, cb)
    -- Both ids travel: a real banId unbans that ban; banId 0 with the userId lifts every active ban
    -- for the user (the actions-bar button).
    TriggerServerEvent('whip_core:server:pmUnban', tonumber(data.banId) or 0, tonumber(data.userId) or 0)
    cb('ok')
end)

-- The Permissions group's Give / Take: one declared permission, on or off for this account.
RegisterNUICallback('plmPermission', function(data, cb)
    TriggerServerEvent('whip_core:server:pmPermission', tonumber(data.userId) or 0, tostring(data.name or ''),
        data.on == true)
    cb('ok')
end)

RegisterNUICallback('plmAddNote', function(data, cb)
    TriggerServerEvent('whip_core:server:pmAddNote', data.userId, data.note or '')
    cb('ok')
end)

RegisterNUICallback('plmDeleteNote', function(data, cb)
    -- The user rides along so the server can answer with that pane (0 = not known).
    TriggerServerEvent('whip_core:server:pmDeleteNote', data.noteId, tonumber(data.userId) or 0)
    cb('ok')
end)

-- Rename a character: the name only, the charId stays (server/devtools.lua pmRenameChar). The pane comes back.
RegisterNUICallback('plmRenameChar', function(data, cb)
    TriggerServerEvent('whip_core:server:pmRenameChar', tonumber(data.charId) or 0,
        tostring(data.firstName or ''), tostring(data.lastName or ''))
    cb('ok')
end)

-- Dev tools until the server restarts. The server decides who may, and answers with the pane.
RegisterNUICallback('plmDevtools', function(data, cb)
    TriggerServerEvent('whip_core:server:pmSetDevtools', tonumber(data.userId) or 0, data.give == true)
    cb('ok')
end)

-- A stat typed on their page (Current Stats). The pane comes back with it (server/devtools.lua pmSetStat).
RegisterNUICallback('plmSetStat', function(data, cb)
    TriggerServerEvent('whip_core:server:pmSetStat', tonumber(data.targetSource) or 0, tostring(data.stat or ''),
        tonumber(data.value))
    cb('ok')
end)

-- The action cards on a player: the server checks and does each (server/devtools.lua).
for callback, event in pairs({
    plmTeleportTo  = 'whip_core:server:pmTeleportTo',
    plmBringPlayer = 'whip_core:server:pmBringPlayer',
    plmRevive      = 'whip_core:server:pmRevive',
    plmHeal        = 'whip_core:server:pmHeal',
    plmKill        = 'whip_core:server:pmKill',
}) do
    RegisterNUICallback(callback, function(data, cb)
        TriggerServerEvent(event, data.targetSource)
        cb('ok')
    end)
end

-- Open a character's inventory from the panel. Inventory handoff v1: the shell
-- CLOSES rather than suspends — resuming on inventory close needs a clean
-- inventory-closed hook that hasn't been verified; today's UX is preserved exactly.
-- (Old body minus its focus/close/DeactivateTool lines — the close funnel owns those.)
RegisterNUICallback('plmOpenInventory', function(data, cb)
    if data.charId then
        WhipPanelClose()
        TriggerServerEvent('whip_core:server:openPlayerInventory', data.charId)
    end
    cb('ok')
end)
