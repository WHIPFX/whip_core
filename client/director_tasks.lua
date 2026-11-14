-- Director: other resources' task steps on this game (Whip.task). A resource's task type
-- (server/director/satellite_api.lua) is played by its own code on the game that owns the thing (whip_core's own steps:
-- client/npcs.lua, client/actors.lua; the builder's preview: client/director_preview.lua). Whip.task hands in one
-- entry function (__RegisterDirectorTaskStep) that runs on that resource's side inside a pcall and answers data.
-- whip_core asks it:
--   run   { call, entity, args, info }  start the step (in a thread of its own: it may wait)
--   done  { call, entity, args }        a waiting step: { how = 'done' | 'failed' | nil }, each quarter second
-- `args` are the step's fields: a placed thing's field is its entity here (nil when not here), a target is
-- { kind, entity, coords }, a point { x, y, z, heading }.

DirectorTaskSteps = {}

local Steps = {}   -- [type] = the resource's entry
local StepReg = Registry.new('directorTaskStep', {
    label = 'Director task step', store = Steps,
    -- (A restarted resource hands in a new entry: every registration replaces.)
    same = false,
})

local seq = 0

-- (DirectorKit's, shared/director/kit.lua: a player's ped by server id goes through GamePlatform.playerIndex.)
local callable, entityOfNet, pedOfServerId = DirectorKit.callable, DirectorKit.entityOfNet, DirectorKit.pedOfServerId

-- (What the server and the preview work a target out into: the code is handed the target itself.)
local TARGET_KEYS = { tSid = true, tNet = true, tAt = true, tEnt = true, thing = true }

--- A step's params as its code is handed them.
local function argsOf(p)
    p = type(p) == 'table' and p or {}
    local a = {}
    for k, v in pairs(p) do
        if type(v) == 'table' and v.thing ~= nil then
            -- A placed thing (server/director/nodes_tasks.lua satThings): the preview's own copy, or the run's by its netId.
            a[k] = (v.ent and DoesEntityExist(v.ent) and v.ent) or entityOfNet(v.net)
        elseif not (p.target and TARGET_KEYS[k]) then
            a[k] = v
        end
    end
    if p.target then
        local e = (p.tEnt and DoesEntityExist(p.tEnt) and p.tEnt) or (p.tSid and pedOfServerId(p.tSid)) or entityOfNet(p.tNet)
        ---@type table|nil
        local c = e and GetEntityCoords(e) or nil
        if not c and type(p.tAt) == 'table' then c = { x = p.tAt.x, y = p.tAt.y, z = p.tAt.z } end
        a.target = { kind = p.target, entity = e, coords = c and { x = c.x, y = c.y, z = c.z } or nil }
    end
    return a
end

--- Is `t` a type another resource plays here?
function DirectorTaskSteps.has(t) return Steps[t] ~= nil end

--- Is `t` another resource's type (its name has its namespace), here or not?
function DirectorTaskSteps.isSatellite(t) return type(t) == 'string' and t:find('.', 1, true) ~= nil end

--- Start step `s` ({ t, p, timing }) on `entity`, a `kind` ('npc' | 'vehicle'), with `left` ms. `preview`: the world
--- builder's copy (nothing of a run's). Answers what to watch for a step that waits (DirectorTaskSteps.done), or nil.
function DirectorTaskSteps.run(entity, kind, s, left, preview)
    local entry = Steps[s.t]
    if not entry then
        print(('[whip_core:tasks] %s: the resource that plays it is not running on this game'):format(tostring(s.t)))
        return s.timing == 'until' and { failed = true } or nil
    end
    seq = seq + 1
    local args = argsOf(s.p)
    local ok, res = pcall(entry, 'run', { call = seq, entity = entity, args = args,
        info = { type = s.t, kind = kind, timing = s.timing, ms = left, preview = preview == true } })
    if not ok or type(res) ~= 'table' or res.err ~= nil then
        local why = ok and type(res) == 'table' and res.err or res
        print(('[whip_core:tasks] %s failed here: %s'):format(s.t, tostring(why or 'its code threw an error')))
        return s.timing == 'until' and { failed = true } or nil
    end
    return { sat = s.t, call = seq, args = args }
end

--- A step that waits, by what run answered: 'done', 'failed' or nil (not yet).
function DirectorTaskSteps.done(entity, look)
    if type(look) ~= 'table' then return nil end
    if look.failed then return 'failed' end
    local entry = look.sat and Steps[look.sat]
    if not entry then return 'failed' end
    local ok, res = pcall(entry, 'done', { call = look.call, entity = entity, args = look.args })
    if not ok or type(res) ~= 'table' or res.err ~= nil then return 'failed' end
    if res.how == 'done' or res.how == 'failed' then return res.how end
    return nil
end

-- Exports

--- __RegisterDirectorTaskStep(taskType, entry) -> true | false, why. Through Whip.task only (its client half).
exports('__RegisterDirectorTaskStep', function(taskType, entry)
    local owner = Registry.caller()
    if type(taskType) ~= 'string' or #taskType > 64 or not taskType:match('^[%a][%w_]*%.[%a][%w_]*$') then
        return false, 'a task type is "<your namespace>.<name>", like autos.paint'
    end
    if not callable(entry) then return false, 'use Whip.task (@whip_core/lib/satellite.lua)' end
    return StepReg:add(owner, taskType, entry)
end)

--- __RemoveDirectorTaskStep(taskType) -> true | false, why. Only your own.
exports('__RemoveDirectorTaskStep', function(taskType)
    return StepReg:remove(Registry.caller(), taskType)
end)
