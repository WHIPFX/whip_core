-- ============================================
-- THEME OVERRIDE REGISTRY
-- ============================================
--
-- Config.Theme is the STANDING theme: a resource name baked into config, applied by each
-- client's own announce() (client/ready.lua). This file is the RUNTIME override on top of
-- it — the same shape as the accessory-slot registry in server/inventory.lua: a satellite
-- registers itself, whip_core broadcasts, and stopping the satellite unwinds automatically.
--
-- What that buys: a skin can be a start/stoppable resource. `start my_skin` reskins every
-- connected client live (whip_core:client:applyTheme is a hot link swap in the NUI — no
-- restart), `stop my_skin` reverts to Config.Theme. Late joiners are covered by the
-- ride-along in player_lifecycle.lua, because a broadcast cannot reach a player who was not
-- connected when it fired.
--
-- Scope note: themes.css files do not have to reskin everything. A theme whose selectors are
-- all scoped under one panel root (e.g. #ui-notifications) restyles only that panel and
-- leaves the rest of the UI stock — theme.css loads last, so it wins the cascade either way.
-- See docs/nui-theming.md.

Themes = Themes or {}

local function broadcast(theme)
    TriggerClientEvent('whip_core:client:applyTheme', -1, theme or Config.Theme)
end

-- One slot, on the one registration rule (shared/registry.lua).
--
-- The override is the entry 'active', owned by the resource that set it:
--
--   * Clearing is removing, and a resource can only remove its own.
--   * The first skin to claim the slot keeps it until it stops (skins register from
--     whip_core:onReady, which re-fires); a second is refused with the first one's name, which is
--     what the server owner needs to see.
--
-- The same owner setting a different theme replaces it (a manager resource swapping skins). The
-- same one again changes nothing and broadcasts nothing. Stopping the owner reverts to
-- Config.Theme — the registry's sweep, and onRemove broadcasts it.
local _theme = Registry.new('Theme', {
    label    = 'theme override',
    onAdd    = function(_, theme) broadcast(theme) end,
    onRemove = function() broadcast(nil) end,
})

--- The current override, or nil when the server is on Config.Theme.
---@return string|nil
function Themes.getActive()
    return _theme:get('active')
end

--- Set (or clear) the server-wide theme override.
---
--- `resource` names a resource whose theme.css the NUI should inject — usually the caller's
--- own name. Pass nil to clear back to Config.Theme. The apply is fail-soft on the client
--- (html/js/theme.js drops to the base look and logs if the resource or its theme.css is
--- missing), so a typo here cannot blank anyone's UI.
---
--- Callers registering their own skin should do it from a whip_core:onReady handler, not
--- file scope: onReady re-fires after a core restart, and this registry's state dies with
--- core. Same contract as every other registration export.
---
--- Answers (false, reason) when another resource's override is active, and when a resource
--- that does not hold the override tries to clear it.
---@param resource string|nil
---@return boolean ok
---@return string|nil err
exports('SetActiveTheme', function(resource)
    local owner = Registry.caller()   -- first, before anything can yield
    if resource ~= nil and (type(resource) ~= 'string' or #resource == 0 or #resource > 64) then
        return false, 'resource must be a resource name (short string) or nil'
    end

    if resource == nil then
        -- Clearing when nothing is set is not a failure: the answer the caller wanted is true.
        if _theme:get('active') == nil then return true end
        return _theme:remove(owner, 'active')
    end

    local ok, why = _theme:add(owner, 'active', resource)
    if not ok then
        local holder = _theme:ownerOf('active')
        if holder and holder ~= owner then
            return false, ('the active theme belongs to %s — stop it first'):format(holder)
        end
        return false, why --[[@as string]]
    end
    return true
end)

--- The theme in force: the override's resource and who set
--- it, or Config.Theme with no owner when nothing overrides it.
---@return string|nil theme   the resource whose theme.css is applied; nil for the stock look
---@return string|nil owner   the resource that set the override; nil for Config.Theme
exports('GetActiveTheme', function()
    local active = _theme:get('active')
    if active ~= nil then return active, _theme:ownerOf('active') end
    return Config.Theme
end)

-- Config.Theme changed in /whip → Settings: every player gets the new standing look now, unless a
-- resource holds an override, which wins (as it does at join) until it stops.
Settings.onChange('Theme', function()
    if _theme:get('active') == nil then broadcast(nil) end
end)
