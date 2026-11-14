-- ============================================
-- /whip SECTION — Phones (client wiring)
-- ============================================
--
-- Replaces tools/phones.lua. The section lifecycle and the data forward live here,
-- and the pm* mutation callbacks moved with them (pmClose retired — the shell owns
-- the close path now). Every server event named here is UNCHANGED from the
-- standalone tool — the server never noticed the consolidation.
--
-- PREFIX CAUTION: pm* here is the PHONE Manager. The Player Manager confusingly
-- uses pmGetAllUsers/plmClosed for its own traffic — none of that belongs here.

PanelSections['phones'] = {
    enter = function()
        TriggerServerEvent('whip_core:server:pmGetAll')
    end,
    leave = function()
        TriggerServerEvent('whip_core:server:pmClosed')
    end,
}

RegisterNetEvent('whip_core:client:pmAllData', function(data)
    -- The old handler only grabbed focus and opened the overlay — both are the
    -- shell's job now, so the payload forwards untouched (no enrichment existed).
    WhipPanelData('phones', 'all', data)
end)

-- Only a PHONE payload. The Player Manager's refresh rode this same name until it became
-- plmRefresh, and its { users } list landed here as an empty phone list.
RegisterNetEvent('whip_core:client:pmRefresh', function(data)
    if data and data.entries then
        WhipPanelData('phones', 'refresh', data)
    end
end)

-- ---- mutations (moved verbatim from tools/phones.lua) ----

-- By NUMBER: a character may own several (whip_phone's SIM cards).
RegisterNUICallback('pmEditNumber', function(data, cb)
    TriggerServerEvent('whip_core:server:pmEditNumber', data.phoneNumber, data.newNumber)
    cb('ok')
end)

RegisterNUICallback('pmDeleteNumber', function(data, cb)
    TriggerServerEvent('whip_core:server:pmDeleteNumber', data.phoneNumber)
    cb('ok')
end)

RegisterNUICallback('pmAssignNumber', function(data, cb)
    TriggerServerEvent('whip_core:server:pmAssignNumber', data.charId)
    cb('ok')
end)

RegisterNUICallback('pmSpawnSim', function(data, cb)
    TriggerServerEvent('whip_core:server:pmSpawnSim', data.phoneNumber)
    cb('ok')
end)

--- What a number holds, for its page: its contacts, messages, calls and blocks (server/devtools.lua, pmNumberDetail).
RegisterNUICallback('pmDetail', function(data, cb)
    CreateThread(function()
        local res = Callback('whip_core:pmNumberDetail', type(data) == 'table' and data.phoneNumber or nil)
        cb(type(res) == 'table' and res or { ok = false })
    end)
end)

--- A number's records, for its dashboard (html/js/wp/phoneRecords.js; server/devtools.lua, pmPhoneDossier).
RegisterNUICallback('pmDossier', function(data, cb)
    data = type(data) == 'table' and data or {}
    CreateThread(function()
        local res, why = Callback('whip_core:pmPhoneDossier', data.phoneNumber, data.tzOffset)
        cb(type(res) == 'table' and res or { ok = false, why = why })
    end)
end)

--- One conversation, a page at a time (pmPhoneThread).
RegisterNUICallback('pmThread', function(data, cb)
    data = type(data) == 'table' and data or {}
    CreateThread(function()
        local res, why = Callback('whip_core:pmPhoneThread', data.phoneNumber, data.otherNumber, data.beforeId)
        cb(type(res) == 'table' and res or { ok = false, why = why })
    end)
end)
