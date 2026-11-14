-- ============================================
-- DIRECTOR — this player's own runs, for other resources on their game (the Director API)
-- ============================================
--
-- The server tells this game about the Director runs its player is in (server/director/api.lua,
-- Director.tellPlayer): they joined one, what its band says now, they left it, it ended. Kept here so
-- a phone's job screen or a HUD can ask (GetPlayerScenarioRuns) and hear (local events), without asking the
-- server or reading a statebag:
--
--   whip_core:run:joined   { runId, scenario, name, objective, countdown }
--   whip_core:run:updated  { runId, scenario, name, objective, countdown }   (its band changed)
--   whip_core:run:left     { runId, scenario, name, why }
--   whip_core:run:ended    { runId, scenario, name, outcome, payout }
--
-- Only this player's runs, and never a builder's Test. `countdown` is the seconds left on the band's
-- clock when it was sent; GetPlayerScenarioRuns counts it down.

local mine = {}   -- [runId] = { runId, scenario, name, objective, endsAt (GetGameTimer ms) | nil }

local function viewOf(r)
    local left = r.endsAt and math.max(0, math.floor((r.endsAt - GetGameTimer()) / 1000)) or nil
    return { runId = r.runId, scenario = r.scenario, name = r.name, objective = r.objective, countdown = left }
end

RegisterNetEvent('whip_core:client:directorRun', function(op, info, extra)
    if type(info) ~= 'table' or type(info.id) ~= 'number' then return end
    extra = type(extra) == 'table' and extra or {}
    local id = info.id
    if op == 'joined' or op == 'updated' then
        local known = mine[id] ~= nil
        mine[id] = { runId = id, scenario = info.scenario, name = info.name, objective = info.objective,
                     endsAt = type(info.countdown) == 'number' and GetGameTimer() + info.countdown * 1000 or nil }
        -- An update for a run this game never heard of (it restarted mid-run) is its join.
        WhipEmit((op == 'joined' or not known) and 'whip_core:run:joined' or 'whip_core:run:updated', viewOf(mine[id]))
    elseif op == 'left' or op == 'ended' then
        local r = mine[id] or { runId = id, scenario = info.scenario, name = info.name }
        mine[id] = nil
        if op == 'left' then
            WhipEmit('whip_core:run:left', { runId = id, scenario = r.scenario, name = r.name, why = extra.why })
        else
            WhipEmit('whip_core:run:ended', { runId = id, scenario = r.scenario, name = r.name, outcome = extra.outcome,
                                              payout = extra.payout })
        end
    end
end)

--- The runs this player is in now, newest first: { { runId, scenario, name, objective, countdown } }.
exports('GetPlayerScenarioRuns', function()
    local out = {}
    for _, r in pairs(mine) do out[#out + 1] = viewOf(r) end
    table.sort(out, function(a, b) return a.runId > b.runId end)
    return out
end)
