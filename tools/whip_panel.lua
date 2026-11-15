-- ============================================
-- WHIP ADMIN PANEL — /whip (client controller)
-- ============================================
--
-- The Lua half of the master admin panel (html/js/whip-panel.js). One command, one
-- focus owner, one close funnel, one suspend/resume seam — replacing fourteen
-- free-standing tools that each grabbed focus themselves and each invented their own
-- (frequently divergent) close path.
--
-- SECTIONS register into `PanelSections` from tools/panel_sections/*.lua, which load
-- AFTER this file (manifest order):
--
--     PanelSections['containers'] = {
--         enter = function() TriggerServerEvent('whip_core:server:cmGetAll') end,
--         leave = function() end,   -- fire the tool's xClosed event, drop blips, etc.
--     }
--
-- enter/leave are the ONLY lifecycle a section's Lua owns. The shell (JS) decides when
-- they fire; the server events they call are the SAME events the standalone tools used
-- — the server side of every tool is untouched by the consolidation.
--
-- Section data flows back through WhipPanelData(sectionId, kind, payload), which the
-- section's net-event handlers call instead of the old focus-grab-and-open dance.

PanelSections = PanelSections or {}

local shellOpen     = false
local activeSection = nil
local suspendDepth  = 0

--- Forward a payload to a section's JS `onData(kind, payload)`.
function WhipPanelData(sectionId, kind, payload)
    SendNUIMessage({ action = 'wpSectionData', section = sectionId, kind = kind, payload = payload })
end

--- Drop a one-line acknowledgement into the panel's result strip (bottom edge).
--- The in-panel answer to "did that work?" — section Lua calls this after a mutation
--- instead of (or alongside) a world-corner Notify the panel is covering anyway.
---@param text string  what happened, plain words
---@param kind string|nil  'ok' (default) or 'err'
function WhipPanelResult(text, kind)
    SendNUIMessage({ action = 'wpResult', text = text, kind = kind })
end

function WhipPanelIsOpen()
    return shellOpen
end

--- Open AND actually on screen — false while a section flow has borrowed the game
--- screen (suspend seam). The showSuccess/showError router in client/main.lua asks
--- this, not IsOpen: a result strip nobody can see is worse than the world toast.
function WhipPanelIsVisible()
    return shellOpen and suspendDepth == 0
end

--- Open the panel (optionally landing on a section). Full admins (whip.devtools) open every
--- section; a player given a permission opens only the sections it opens. The callback is the
--- client-side courtesy check; every mutation behind every section is independently gated
--- server-side (ACE or permission), which is the real wall.
local opening = false

---@param section string|nil
---@param focus table|nil  what the section opens on: { vehicleId } (vehicles), { userId } (playerManager): the object
---                        viewer's Open in WHIP Admin Menu (tools/ov_panel.lua)
function WhipPanelOpen(section, focus)
    -- `opening` held across the access check: it waits on the server, and two quick presses would
    -- both get past `shellOpen` and open the panel twice.
    if shellOpen or opening then return end
    -- NOT OVER ANOTHER SCREEN: closing the panel would leave the screen underneath with no cursor.
    -- MayOpenScreen is the question the wheel asks too (client/inventory.lua).
    if MayOpenScreen and not MayOpenScreen('panel') then return end
    opening = true
    -- WHICH SECTIONS: a full admin opens them all; a player given a permission
    -- (a Director builder) opens /whip with only the sections it opens (server/permissions.lua).
    -- Bare, never under pcall (house rule, 08f71051): Callback does not throw, and a pcall only hid the one failure it
    -- could have, being called where it cannot wait. Every caller runs this in a thread (the command below makes one).
    local access, why = Callback('whip_core:panel:access')
    opening = false
    if type(access) ~= 'table' then
        UI.Notify(type(why) == 'string' and why or 'The admin panel did not answer', 'error')
        return
    end
    shellOpen = true
    Focus.take('panel', { screen = true })
    -- Each satellite's settings page is a section of its own, and its Lua half is the Config
    -- section's, for that page (tools/panel_sections/config.lua).
    local pages = type(access.settingsPages) == 'table' and access.settingsPages or {}
    local cfg = PanelSections['config']
    for _, p in ipairs(pages) do
        local id = 'settings:' .. tostring(p.owner)
        if not PanelSections[id] and cfg and cfg.forPage then PanelSections[id] = cfg.forPage(id) end
    end
    SendNUIMessage({ action = 'openWhipPanel', section = section, focus = focus,
        sections = access.all ~= true and (access.sections or {}) or nil,
        permanent = access.permanent == true, settingsPages = pages })
end

--- THE close funnel — every way out of the panel lands here: the × button and Escape
--- (via the wpClose NUI callback), the /w Admin Panel entry toggling off, resource
--- stop. Order matters: the active section's leave runs first (its xClosed event is
--- what stops the server pushing to a viewer that no longer exists — the plmClosed
--- leak class), then focus, then the NUI teardown.
function WhipPanelClose()
    if not shellOpen then return end
    if activeSection and PanelSections[activeSection] and PanelSections[activeSection].leave then
        pcall(PanelSections[activeSection].leave)
    end
    activeSection = nil
    shellOpen = false
    -- A SUSPENDED PANEL HOLDS NO FOCUS: its own hold only, so whatever took the
    -- screen meanwhile keeps its cursor (client/focus.lua).
    suspendDepth = 0
    Focus.release('panel')
    SendNUIMessage({ action = 'closeWhipPanel' })
    DeactivateTool('Admin Panel')   -- keep the /w badge honest; no-op if not listed
end

-- ============================================
-- Suspend / resume — the screen-borrowing seam
-- ============================================
--
-- Generalized from the Job Manager's jmSuspend: a section flow that needs the actual
-- game screen (a UI Library demo, the zone/door in-world editors) hides the panel and
-- releases focus WITHOUT tearing the section down, then resumes. A section that only
-- needs a yes/no asks it inside the panel with WP.confirm and never leaves; a UI.Confirm
-- or other whip dialog opened while the panel is still up answers 'busy' (client/ui.lua).
-- Depth-counted so nested borrows (a confirm inside a demo) cannot un-suspend early.
-- While suspended the JS key scope reports closed, which is what yields Escape/keys
-- to whatever borrowed the screen.

function WhipPanelSuspend()
    if not shellOpen then return end
    suspendDepth = suspendDepth + 1
    if suspendDepth == 1 then
        Focus.release('panel')
        SendNUIMessage({ action = 'wpSuspend' })
    end
end

function WhipPanelResume()
    if not shellOpen then return end
    if suspendDepth > 0 then suspendDepth = suspendDepth - 1 end
    if suspendDepth == 0 then
        -- SOMETHING ELSE TOOK THE SCREEN MEANWHILE (F2 works while the panel is suspended)? Stay
        -- suspended then; /whip brings it back once that screen closes.
        if (IsAnyUIOpen and IsAnyUIOpen()) or (FocusScreenUp and FocusScreenUp('panel')) then
            suspendDepth = 1
            return
        end
        Focus.take('panel', { screen = true })
        SendNUIMessage({ action = 'wpResume' })
    end
end

-- ============================================
-- Command + NUI callbacks
-- ============================================

--- Bring back a panel left suspended because another screen took over (WhipPanelResume), once
--- nothing else is up. True when it did.
---@return boolean
local function resumeLeftSuspended()
    if shellOpen and not WhipPanelIsVisible() and MayOpenScreen and MayOpenScreen('panel') then
        suspendDepth = 1
        WhipPanelResume()
        return true
    end
    return false
end

-- In a thread, as /w is (08f71051): the open waits on the server, and a command handler cannot (audit 20, CLI-5)
RegisterCommand('whip', function()
    CreateThread(function()
        if shellOpen then
            -- Left suspended: /whip brings it back rather than closing a panel the admin cannot see.
            if resumeLeftSuspended() then return end
            WhipPanelClose()
        else
            WhipPanelOpen()
        end
    end)
end, false)

-- The /w quick menu's 'Admin Panel' entry — the second door to the same panel. The
-- menu already hides itself before enter (not an overlayTool); WhipPanelClose keeps
-- the /w badge honest via DeactivateTool, which is a no-op when the close started
-- from the menu itself.
--
-- AS /whip DOES: the entry brings back a suspended panel (WhipPanelOpen returns at once for a panel
-- that is already open), and `isActive` lets the /w list read back whether the panel really is open.
ToolHandlers['Admin Panel'] = {
    enter    = function() if not resumeLeftSuspended() then WhipPanelOpen() end end,
    exit     = function() WhipPanelClose() end,
    isActive = function() return shellOpen end,
}

-- /director (server/director/commands.lua): the same panel, on its Director tab (the Director itself is entered
-- from there: Edit). The panel asks the server who may see it, as /whip does.
RegisterNetEvent('whip_core:client:openDirector', function()
    CreateThread(function()
        if not resumeLeftSuspended() then WhipPanelOpen('director') end
    end)
end)

-- The /w quick menu's 'Dungeon Mode' entry: the world builder on the live world, straight away (client/director_live.lua;
-- /whip, Director, Dungeon Mode opens the same). Never shown as on, so every press opens it; the server decides what it
-- may do (director.live).
ToolHandlers['Dungeon Mode'] = {
    enter    = function()
        CreateThread(function()
            local ok, why = DirectorLive.open()
            if not ok then UI.Notify(why or 'Dungeon Mode could not open', 'error') end
        end)
    end,
    exit     = function() end,
    isActive = function() return false end,
}

-- The /w quick menu's 'Systems Creator' entry (shown while the experimental feature is on): /systems itself, so the
-- server's own checks decide (systems.build, Config.Experimental: server/systems/main.lua) and say why not. Never on.
ToolHandlers['Systems Creator'] = {
    enter    = function() ExecuteCommand('systems') end,
    exit     = function() end,
    isActive = function() return false end,
}

-- Deliberately UNBOUND by default — admins bind it in GTA's keybind settings, and an
-- unbound default can never collide with anyone's existing binds.
RegisterKeyMapping('whip', 'Whip: Open Admin Panel', 'keyboard', '')

RegisterNUICallback('wpClose', function(_, cb)
    WhipPanelClose()
    cb('ok')
end)

-- The char-picker typeahead (WP.attachCharPicker). Pure relay: the server callback
-- owns the ACE gate, the rate limit, and the query shape — nothing here to trust.
RegisterNUICallback('wpCharSearch', function(data, cb)
    local q = data and data.q
    if type(q) ~= 'string' or q == '' then cb({}) return end
    cb(Callback('whip_core:wpCharSearch', q) or {})
end)

-- Everyone, for a page's list of people (pickers.js personList). Pure relay, as above.
RegisterNUICallback('wpCharList', function(_, cb)
    cb(Callback('whip_core:wpCharList') or {})
end)

-- The portraits of the people a section is showing (pickers.js avatar). Pure relay, as above:
-- server/portraits.lua owns the ACE gate, the page size and the read.
RegisterNUICallback('wpPortraits', function(data, cb)
    local ids = data and data.charIds
    if type(ids) ~= 'table' then cb({}) return end
    cb(Callback('whip_core:portraits', ids) or {})
end)

RegisterNUICallback('wpSectionEnter', function(data, cb)
    local id = data and data.id
    if type(id) == 'string' and PanelSections[id] then
        activeSection = id
        if PanelSections[id].enter then
            local ok, err = pcall(PanelSections[id].enter)
            if not ok then print(('[whip_core:panel] enter for "%s" errored: %s'):format(id, tostring(err))) end
        end
    end
    cb('ok')
end)

RegisterNUICallback('wpSectionLeave', function(data, cb)
    local id = data and data.id
    if type(id) == 'string' and PanelSections[id] then
        if id == activeSection then activeSection = nil end
        if PanelSections[id].leave then
            local ok, err = pcall(PanelSections[id].leave)
            if not ok then print(('[whip_core:panel] leave for "%s" errored: %s'):format(id, tostring(err))) end
        end
    end
    cb('ok')
end)

-- A stopping whip_core must not leave the player focus-locked or the server holding a
-- viewer session for a panel that no longer exists.
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if shellOpen then WhipPanelClose() end
end)
