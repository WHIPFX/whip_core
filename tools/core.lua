-- ============================================
-- Dev Tools — Core: Menu, Tool Registry, Dispatch
-- ============================================

-- Menu state
local menuOpen  = false
local menuIndex = 1

-- Tool registry. Quick tools only — menu-based tools are sections of the /whip master panel
-- (tools/whip_panel.lua + html/js/wp/), reached through the 'Admin Panel' entry under Panels.
--
-- `kind` is what the row draws at its end: a switch for a
-- tool that stays on ('toggle', the default), a run mark for a one-off ('run'), a chevron for one
-- that opens a screen ('open'). `desc` is the line under the list saying what the picked tool does.
--
-- A header with no name ('') is only a gap. The Director opens with /director, and the arrival scenes are
-- chosen in /whip → Settings → Joining.
--
-- `experimental`: a row shown only while that experimental feature is on (/whip → Settings → Experimental
-- features, Config.Experimental), under a header of its own at the end.
local tools = {
    { name = 'Noclip', active = false, desc = 'Fly through anything; you land where you stop.' },
    { name = 'Teleport to Waypoint', active = false, kind = 'run',
      desc = 'To your map waypoint, on the ground; a car you drive comes along. Same as /tpm.' },
    -- tools/player.lua.
    { name = 'Invisible', active = false, desc = 'Nobody else sees you. You see yourself faded.' },
    { name = 'God Mode', active = false, desc = 'No damage; your health is kept full.' },
    { name = 'Restore Player Cores', active = false, kind = 'run',
      desc = 'Fills your health, armour, food and drink. If you are down, it revives you first.' },
    -- tools/show_players.lua.
    { name = 'Reveal Players', active = false,
      desc = 'Every player on the map and minimap, and their name, charId and account over their head.' },
    { name = 'Kill Me', active = false, kind = 'run', ends = { 'Noclip', 'God Mode' },
      desc = 'Downs you at once, where you stand or sit, as any death does. Ends Noclip and God Mode.' },
    { name = 'Repair Vehicle', active = false, kind = 'run',
      desc = 'Repairs the car you are in, whether you are driving it or not.' },
    { name = 'Coords', active = false, desc = 'Where you stand and which way you face. G copies it.' },
    { name = 'Object Viewer', active = false, desc = 'Names the props, cars and people around you.' },
    { sep = '' },
    -- The rows marked `debug` show only while this is on: whip_core's, then other resources' (RegisterDebugTool),
    -- after the one marked `debugLast`.
    { name = 'Debug', active = false, debugSwitch = true,
      desc = 'Shows the debug tools under it. Off turns them all off.' },
    -- In the debug panel (html/js/debug-panel.js), with cards over nearby players and cars.
    { name = 'Player Stats Debug', active = false, debug = true,
      desc = 'Your stats live in the debug panel, and each nearby player\'s over them.' },
    { name = 'Vehicle Stats Debug', active = false, debug = true,
      desc = 'The car you are in, in the debug panel, and each nearby whip car\'s stats over it.' },
    -- tools/ground_debug.lua.
    { name = 'Ground Items Debug', active = false, debug = true, debugLast = true,
      desc = 'Every item on the ground around you, marked to the sky and on the map. Look at one to see it.' },
    { sep = 'Panels' },
    { name = 'Admin Panel', active = false, kind = 'open', desc = 'Opens /whip, the admin panel.' },
    -- tools/whip_panel.lua: the world builder on the live world (client/director_live.lua).
    { name = 'Dungeon Mode', active = false, kind = 'open',
      desc = 'The world builder on the live world: what you put down is made for everyone, and a click opens anything\'s options.' },
    -- The header: shown while any experimental feature below is on (refreshShown).
    { sep = 'Experimental', experimentalHeader = true },
    -- tools/camera.lua.
    { name = 'Camera Creator', active = false, experimental = 'cameraCreator',
      desc = 'An unfinished prototype. Fly a camera; G saves a shot or a point on a path, copied as code.' },
    -- tools/whip_panel.lua: /systems, which opens client/systems_editor.lua for those allowed to build.
    { name = 'Systems Creator', active = false, kind = 'open', experimental = 'systemsCreator',
      desc = 'An unfinished prototype. Builds game systems from cards. The same as /systems.' },
}

--- Is this experimental feature on? (Config.Experimental, /whip → Settings → Experimental features.)
local function experimentalOn(feature)
    return type(Config.Experimental) == 'table' and Config.Experimental[feature] == true
end

-- Pages other resources add to /w (RegisterDevPage, "Pages from other resources" below): each is a row at
-- the end of Panels that swaps the list for the page's own rows. Declared up here for refreshShown and the
-- payload, which run before that section is compiled.
local pages     = {}     -- [owner .. ':' .. id] = the page's registration
local pageKeys  = {}     -- their keys in the order their rows are listed (by label)
---@type table|nil
local page      = nil    -- the page on screen: { key, list, title, crumb, view, backTo }; nil = the tool list
local pageIndex = 1      -- the picked row on that page
local lastPage  = nil    -- the page the menu was shut on with Esc: /w opens on it again

-- The Debug switch, and the debug tools other resources add under it (RegisterDebugTool, "Debug tools from other
-- resources" below).
local debugSwitch = nil
for _, t in ipairs(tools) do
    if t.debugSwitch then debugSwitch = t end
end
---@cast debugSwitch -nil   (the Debug row in the list above)
local debugTools    = {}   -- [owner .. ':' .. id] = its row: { name, desc, active, debugTool = key, owner, onToggle }
local debugToolKeys = {}   -- their keys, by label

-- ============================================
-- Developer mode
-- ============================================
--
-- Dev tools work only with developer mode on (server/devtools_base.lua decides; this follows). Off, /w is
-- the one switch, "Enable developer mode?"; on, the switch heads the list and every tool is under it, and
-- the HUD wears the developer mark. Off again, by the switch or by the server, every tool and dev mode
-- goes off (devtoolsOff, at the bottom).

--- What the server last said: may this account turn developer mode on, and is it on.
local dev = { eligible = false, on = false }

--- Is developer mode on? For what this client only DRAWS for an admin (a manager sign, zone names): the
--- server decides everything behind it again.
---@return boolean
function DevToolsOn()
    return dev.on
end

--- The switch: the first row, always. The question ("Enable developer mode?") is the heading under the
--- list (`title`): in the row it did not fit beside the glyph and the switch.
local devRow = { name = 'Developer mode', dev = true, active = false }
local toolsSep = { sep = 'Tools' }

--- The rows /w shows now: the switch alone, or the switch and every tool.
local shown = { devRow }

local function refreshShown()
    devRow.active = dev.on
    devRow.title = dev.on and 'Developer mode is on' or 'Enable developer mode?'
    devRow.desc = dev.on and 'Every tool below works, and your HUD wears the mark. Off turns them all off.'
        or 'Your dev tools work only while this is on. Your HUD shows it, and it is logged.'
    if not dev.on then
        shown = { devRow }
        return
    end
    shown = { devRow, toolsSep }
    local experimental, header = {}, nil
    for _, t in ipairs(tools) do
        if t.experimentalHeader then
            header = t
        elseif t.experimental then
            if experimentalOn(t.experimental) then experimental[#experimental + 1] = t end
        elseif not t.debug or debugSwitch.active then
            shown[#shown + 1] = t
            if t.debugLast then
                for _, key in ipairs(debugToolKeys) do shown[#shown + 1] = debugTools[key] end
            end
        end
    end
    -- Each resource's page, after Dungeon Mode at the end of Panels.
    for _, key in ipairs(pageKeys) do
        local p = pages[key]
        shown[#shown + 1] = { name = p.label, kind = 'open', desc = p.desc, page = key }
    end
    -- The experimental features that are on, last, under their own header (none on: no header either).
    if #experimental > 0 and header then shown[#shown + 1] = header end
    for _, t in ipairs(experimental) do shown[#shown + 1] = t end
end

--- Where the menu opens: the first tool when developer mode is on (so a habitual Enter never turns it
--- off), else the switch.
local function firstIndex()
    return dev.on and 3 or 1
end

-- Global dispatch table — each tool file registers into this
ToolHandlers = {}

-- The debug overlays keep their own state (their chat commands flip it too); the /w entries SET it, on
-- or off, rather than flip it: a flip after the chat command had already turned one off would turn it
-- back on.
ToolHandlers['Player Stats Debug']  = { enter = function() ToggleStatsDebug(true) end,
                                        exit  = function() ToggleStatsDebug(false) end }
ToolHandlers['Vehicle Stats Debug'] = { enter = function() ToggleVehStatDebug(true) end,
                                        exit  = function() ToggleVehStatDebug(false) end }

-- ============================================
-- Helpers
-- ============================================

--- The rows on screen: a resource's page while one is open, else the tool list.
local function onScreen()
    return page and page.list or shown
end

--- Can the selection land on this row? Group headers and a page's notes are only read.
local function selectable(row)
    return row ~= nil and not row.sep and row.kind ~= 'note'
end

--- The wire shape both send paths share. Entries are tools ({name, active, kind, desc}) or group
--- headers ({sep = 'Label'}) — dev-menu.js renders both and never selects a header; the
--- navigation code here must skip them too, and a page's notes (kind 'note').
local function BuildDevMenuPayload()
    local t = {}
    for i, tool in ipairs(onScreen()) do
        if tool.sep then
            t[i] = { sep = tool.sep }
        else
            t[i] = { name = tool.name, active = tool.active, kind = tool.kind or 'toggle', desc = tool.desc,
                     dev = tool.dev or nil, title = tool.title, icon = tool.icon }
        end
    end
    return t
end

--- One message for the page: the rows, the picked one, the panel's title and the trail above it, and which
--- view this is. dev-menu.js swaps the list in when the view changes, from the side `dir` says ('fwd' into a
--- page or a level of one, 'back' out of it, nil for no slide).
local function menuMessage(action, dir)
    local msg = { action = action, tools = BuildDevMenuPayload(), dir = dir }
    if page then
        msg.index, msg.title, msg.crumb, msg.view = pageIndex - 1, page.title, page.crumb, page.view
    else
        msg.index, msg.title, msg.view = menuIndex - 1, 'Dev Tools', ''
    end
    return msg
end

---@param dir string|nil  'fwd' | 'back' when the view changed by going into or out of something
function SendDevMenu(dir)
    SendNUIMessage(menuMessage('devMenuUpdate', dir))
end

-- (closeMenu lived here for years with zero callers, sending a 'menuHidden' action no
-- JS handler ever registered. Deleted — DeactivateTool below is the real close hook.)

--- Deactivate a tool by name (for NUI close callbacks)
function DeactivateTool(toolName)
    for _, tool in ipairs(tools) do
        if tool.name == toolName then
            tool.active = false
            return
        end
    end
end

--- Is a /w tool on? (The /whip Ground page's "Ground Items Debug" chip shows it.)
---@param toolName string
---@return boolean
function DevToolActive(toolName)
    for _, tool in ipairs(tools) do
        if tool.name == toolName then return tool.active == true end
    end
    return false
end

-- ============================================
-- Tool Toggle — Dispatch via ToolHandlers
-- ============================================

--- Forward declarations: everything off and the menu shut, as when the server takes dev tools back; and
--- developer mode turned on or off. Assigned with the revoke handler at the bottom of this file (a local
--- is only visible to code compiled after it — see StartMenuThread).
local devtoolsTakenBack, devModeChanged

--- Forward declaration: a resource's page on screen ("Pages from other resources", below ToggleTool).
local openPage

--- Forward declarations: the Debug switch, and one resource's debug tool ("Debug tools from other resources").
local setDebug, setDebugTool

--- The switch. ON is the server's to say: it is asked, and its answer (whip_core:client:devMode) opens the
--- list. OFF happens here at once, whatever the server answers — turning everything off is never refused.
local function setDevMode(on)
    if on then
        CreateThread(function()
            local ok, done, why = pcall(Callback, 'whip_core:devtools:setMode', true)
            if not (ok and done == true) then
                UI.Notify(type(why) == 'string' and why or 'Developer mode could not be turned on', 'error')
            end
        end)
    else
        devModeChanged(false)
        CreateThread(function()
            local ok, done = pcall(Callback, 'whip_core:devtools:setMode', false)
            if ok and done == true then return end
            -- Not answered (a timeout, a flood refused): the server may still have it on, and the HUD mark
            -- with it. Show what the server says rather than a menu that disagrees with it.
            local got, access = pcall(Callback, 'whip_core:devtools:access')
            if got and type(access) == 'table' and access.on == true then devModeChanged(true) end
        end)
    end
end

--- One access check in flight at a time; its answer covers every tool switched on meanwhile.
local accessCheckPending = false

--- ASKED AGAIN FOR ANYTHING TURNED ON, so a menu left open after dev tools were taken back cannot
--- switch God Mode on.
---
--- ASKED ALONGSIDE, NOT FIRST: the tool goes on at once (no round-trip pause) and the server is asked
--- at the same time; any answer but yes is treated as dev tools taken back. The server's own revoke
--- push (whip_core:client:devtoolsRevoked) already shuts the menu, so this is the second net.
local function confirmAccess()
    if accessCheckPending then return end
    accessCheckPending = true
    CreateThread(function()
        local ok, allowed = pcall(Callback, 'whip_core:devtools:checkAccess')
        accessCheckPending = false
        if ok and allowed == true then return end
        devtoolsTakenBack()
    end)
end

local function ToggleTool(index)
    local tool = shown[index]
    if not tool or tool.sep then return end

    if tool.dev then
        setDevMode(not dev.on)
        return
    end

    if tool.debugSwitch then
        setDebug(not tool.active)
        SendDevMenu()
        return
    end

    -- Another resource's debug tool: asked again going on, like any tool.
    if tool.debugTool then
        if not tool.active then confirmAccess() end
        setDebugTool(tool, not tool.active)
        SendDevMenu()
        return
    end

    -- A resource's page: asked again like a tool going on, so a menu left open after dev tools were taken
    -- back cannot open one.
    if tool.page then
        confirmAccess()
        openPage(tool.page)
        return
    end

    -- Turning off is never refused, and never asks.
    if not tool.active then confirmAccess() end

    tool.active = not tool.active

    -- Hide dev menu NUI when a panel tool opens
    local function hideMenu()
        menuOpen = false
        SendNUIMessage({ action = 'devMenuHide' })
    end

    -- Tools that don't need NUI focus (keep menu open)
    local overlayTools = {
        ['Noclip'] = true,
        ['Invisible'] = true,
        ['God Mode'] = true,
        ['Restore Player Cores'] = true,
        ['Kill Me'] = true,
        ['Repair Vehicle'] = true,
        ['Coords'] = true,
        ['Camera Creator'] = true,
        -- Draws in the world and takes no clicks, so the menu can stay up while you walk
        -- around naming props — which is the whole point of it.
        ['Object Viewer'] = true,
        ['Reveal Players'] = true,
        -- The debug HUDs are world/screen overlays too — toggling one shouldn't cost
        -- you the menu.
        ['Player Stats Debug'] = true,
        ['Vehicle Stats Debug'] = true,
        ['Ground Items Debug'] = true,
    }

    local handler = ToolHandlers[tool.name]
    if handler then
        if tool.active then
            if not overlayTools[tool.name] then
                hideMenu()
            end
            -- The tools it ends (`ends`), off first and all the way: Kill Me lands you out of Noclip and
            -- takes God Mode away, which would put the health straight back.
            for _, name in ipairs(tool.ends or {}) do
                for _, other in ipairs(tools) do
                    if other.name == name and other.active then
                        other.active = false
                        if ToolHandlers[name] then ToolHandlers[name].exit() end
                    end
                end
            end
            handler.enter()
        else
            handler.exit()
        end
        -- READ BACK: a tool that can refuse to open says whether it is on (the flag was flipped
        -- before enter ran).
        if handler.isActive then tool.active = handler.isActive() == true end
    end

    SendDevMenu()
end

--- Turn a /w tool on or off from somewhere else, the way its row in the menu does (the server is asked
--- when it goes on). The /whip Ground page's "Ground Items Debug" chip uses it. Only with developer
--- mode on: off, the tools are not in the list, and nothing happens. A debug tool turned on turns Debug on.
---@param toolName string
---@param on boolean
---@return boolean  whether it is on now
function SetDevTool(toolName, on)
    if on and dev.on and not debugSwitch.active then
        for _, tool in ipairs(tools) do
            if tool.name == toolName and tool.debug then setDebug(true) break end
        end
    end
    for i, tool in ipairs(shown) do
        if tool.name == toolName and not tool.dev and not tool.sep and not tool.page then
            if (tool.active == true) ~= (on == true) then ToggleTool(i) end
            return tool.active == true
        end
    end
    return false
end

-- ============================================
-- Pages from other resources
-- ============================================
--
-- A resource adds a page of its own to /w with RegisterDevPage: a row at the end of Panels that, picked,
-- swaps the list for the page's rows, with the way back at the top (Backspace does the same). The page says
-- what its rows are (`rows`) and what picking one does (`onSelect`); whip_core draws them, moves the
-- selection, and asks for the rows again after every pick and whenever the page says they changed
-- (RefreshDevPage). Levels inside a page are the page's own: its rows answer `back` (the name of the level
-- above) and its `onBack` goes up one.
--
-- A page is its resource's: keyed `<resource>:<id>`, and gone when that resource stops. Its functions came
-- through an export, so they are called under pcall and never type-tested.

local PAGE_KINDS    = { run = true, toggle = true, open = true, note = true }
local PAGE_MAX_ROWS = 200

--- A string (or a number, as words), cut to `max` characters; nil for anything else or an empty one.
local function pageText(v, max)
    if type(v) == 'number' then v = tostring(v) end
    if type(v) ~= 'string' or v == '' then return nil end
    local n = utf8.len(v)
    if n and n > max then
        v = v:sub(1, utf8.offset(v, max + 1) - 1)
    elseif not n and #v > max then
        v = v:sub(1, max)
    end
    return v
end

--- Could this be a function handed over through an export? A string, number or boolean never is.
local function mayCall(v)
    local t = type(v)
    return v ~= nil and t ~= 'string' and t ~= 'number' and t ~= 'boolean'
end

--- One of the page's functions, under pcall: a page that throws is said in F8 and the menu keeps working.
--- Answers ok and the function's first answer.
local function callPage(p, what, ...)
    local fn = p[what]
    if fn == nil then return true, nil end
    local ok, res = pcall(fn, ...)
    if not ok then
        print(('[whip_core:dev] %s\'s /w page "%s" failed in %s: %s'):format(p.owner, p.id, what, tostring(res)))
    end
    return ok, res
end

--- The page rows in label order.
local function sortPages()
    pageKeys = {}
    for key in pairs(pages) do pageKeys[#pageKeys + 1] = key end
    table.sort(pageKeys, function(a, b)
        local la, lb = pages[a].label:lower(), pages[b].label:lower()
        if la ~= lb then return la < lb end
        return a < b
    end)
end

--- The tool list rebuilt (a page came or went) with the same row still picked.
local function refreshKeepingPick()
    local was = shown[menuIndex]
    local wasKey = was and (was.page or was.name)
    refreshShown()
    for i, row in ipairs(shown) do
        if wasKey ~= nil and (row.page or row.name) == wasKey and selectable(row) then
            menuIndex = i
            return
        end
    end
    if menuIndex > #shown or not selectable(shown[menuIndex]) then menuIndex = firstIndex() end
end

--- Ask the open page for its rows and lay them out under the way back. On the same view the picked row is
--- kept by its id (`keepId`); on a new view it is the row the page names (`select`), else the first that
--- can be picked.
local function buildPage(keepId)
    ---@cast page -nil   (asked for only with a page open)
    local p = pages[page.key]
    local ok, res = callPage(p, 'rows')
    local title, back, rows, pick = p.label, nil, nil, nil
    if ok and type(res) == 'table' then
        rows = res.rows
        if rows == nil then rows = res end            -- a plain list of rows
        title = pageText(res.title, 48) or p.label
        back = pageText(res.back, 32)
        pick = res.select
    end

    local list = { {
        name = back or 'Dev Tools', kind = 'back', back = true,
        desc = ('Back to %s. Backspace does the same.'):format(back or 'the Dev Tools list'),
    } }
    if not ok then
        list[2] = { name = 'This page could not be drawn: see F8', kind = 'note' }
    elseif type(rows) == 'table' then
        for _, r in ipairs(rows) do
            if #list > PAGE_MAX_ROWS then break end
            if type(r) == 'table' then
                local sep = pageText(r.sep, 40)
                if sep then
                    list[#list + 1] = { sep = sep }
                else
                    local label = pageText(r.label, 64)
                    local kind = PAGE_KINDS[r.kind] and r.kind or 'run'
                    local id = r.id
                    if type(id) ~= 'string' and type(id) ~= 'number' then id = nil end
                    -- A row that can be picked needs an id to say which; a note needs none.
                    if label and (id ~= nil or kind == 'note') then
                        -- `icon`: a glyph's key (html/js/glyphs.js), drawn before the label
                        local icon = type(r.icon) == 'string' and #r.icon <= 32 and r.icon:match('^[%w_]+$') or nil
                        list[#list + 1] = { name = label, kind = kind, active = r.active == true,
                                            desc = pageText(r.desc, 300) or '', rowId = id,
                                            close = r.close == true and kind ~= 'note' or nil, icon = icon }
                    end
                end
            end
        end
    end

    local sameView = page.view ~= nil
    page.list, page.title, page.backTo = list, title, back
    page.crumb = title ~= p.label and ('Dev Tools › ' .. p.label) or 'Dev Tools'
    local view = page.key .. '|' .. title .. '|' .. (back or '')
    sameView = sameView and page.view == view
    page.view = view

    local want = sameView and keepId or pick
    local at = nil
    if want ~= nil then
        for i, row in ipairs(list) do
            if row.rowId == want and selectable(row) then at = i break end
        end
    end
    if not at then
        for i = 2, #list do
            if selectable(list[i]) then at = i break end
        end
    end
    pageIndex = at or 1
end

openPage = function(key)
    local p = pages[key]
    if not p then return end
    page = { key = key }
    callPage(p, 'onOpen')
    if not (page and page.key == key and pages[key]) then return end
    buildPage(nil)
    SendDevMenu('fwd')
end

--- Off the page: its onClose, and the tool list back with the page's own row picked. `show` false when the
--- menu is shutting and there is nothing to draw.
local function leavePage(show)
    if not page then return end
    local key = page.key
    page = nil
    if pages[key] then callPage(pages[key], 'onClose') end
    for i, row in ipairs(shown) do
        if row.page == key then menuIndex = i break end
    end
    if show then SendDevMenu('back') end
end

--- The way back: up one of the page's own levels when it has one above, else out to the tool list.
local function pageBack()
    if not page then return end
    local p = pages[page.key]
    if p and page.backTo and p.onBack ~= nil then
        local key = page.key
        callPage(p, 'onBack')
        if page and page.key == key and pages[key] then
            buildPage(nil)
            SendDevMenu('back')
        end
    else
        leavePage(true)
    end
end

--- Shut the menu. A page open in it is left (its onClose) and remembered: /w opens on it again.
local function closeMenu()
    menuOpen = false
    if page then
        lastPage = page.key
        leavePage(false)
    end
    SendNUIMessage({ action = 'devMenuHide' })
end

--- Enter on a page's row: the way back, or the page's onSelect and its rows asked for again. A row that
--- closes (`close`) shuts the menu after its onSelect, the way Escape does: /w opens on the page again.
local function pickPageRow(i)
    local row = page and page.list[i]
    if not row then return end
    ---@cast page -nil   (the row came from it)
    if row.back then pageBack() return end
    if not selectable(row) then return end
    local key, before = page.key, page.view
    callPage(pages[key], 'onSelect', row.rowId)
    if row.close then
        if menuOpen then closeMenu() end
        return
    end
    if page and page.key == key and pages[key] then
        buildPage(row.rowId)
        SendDevMenu(page.view ~= before and 'fwd' or nil)
    end
end

--- Move the selection one row up (-1) or down (1) on what is on screen, over the rows that are only read.
local function stepSelection(dir)
    local list = onScreen()
    local i = page and pageIndex or menuIndex
    for _ = 1, #list do
        i = i + dir
        if i < 1 then i = #list elseif i > #list then i = 1 end
        if selectable(list[i]) then break end
    end
    if page then pageIndex = i else menuIndex = i end
end

--- Enter: on a page, its row; on the tool list, the tool.
local function pickRow()
    if page then pickPageRow(pageIndex) else ToggleTool(menuIndex) end
end

--- A row pressed by a tool reading the menu by its words (html/js/page-tools.js; the menu takes no mouse): the
--- selection moves there and it is picked as Enter picks it. Only on the list the press was made on (`view`).
RegisterNUICallback('devMenuPick', function(d, cb)
    cb({})
    if not menuOpen or type(d) ~= 'table' then return end
    if (d.view or '') ~= (page and page.view or '') then return end
    local i = math.tointeger(tonumber(d.index))
    if not i or not selectable(onScreen()[i]) then return end
    if page then pageIndex = i else menuIndex = i end
    local ok, err = pcall(pickRow)
    if not ok then
        print(('[whip_core:dev] a tool failed to toggle: %s'):format(tostring(err)))
        closeMenu()
        return
    end
    if menuOpen then SendDevMenu() end
end)

--- Developer mode going off, or dev tools taken back: the page left and not opened again.
local function dropPage()
    lastPage = nil
    leavePage(false)
end

--- Gone (its resource stopped, or it removed itself): no onClose, its owner may be gone with it.
local function removePage(key)
    if not pages[key] then return end
    pages[key] = nil
    sortPages()
    if lastPage == key then lastPage = nil end
    if page and page.key == key then page = nil end
    refreshKeepingPick()
    if menuOpen then SendDevMenu() end
end

--- Add a page of your own to /w, or replace the one you added under this id. Called inside Whip.register:
--- whip_core forgets every page when it restarts.
---@param id string  letters, digits, _ and -; yours only (kept as '<your resource>:<id>')
---@param def table  { label, desc?, rows, onSelect, onBack?, onOpen?, onClose? }
---@return boolean ok, string|nil why
local function registerPage(owner, id, def)
    if type(id) ~= 'string' or #id > 48 or not id:match('^[%w_%-]+$') then
        return false, 'the id must be letters, digits, _ or - (48 at most)'
    end
    if type(def) ~= 'table' then return false, 'the page must be a table' end
    local label = pageText(def.label, 40)
    if not label then return false, 'label (the row in /w and the page title) must be a string' end
    if not mayCall(def.rows) then return false, 'rows (a function answering the page\'s rows) is required' end
    if not mayCall(def.onSelect) then return false, 'onSelect (a function run when a row is picked) is required' end
    for _, name in ipairs({ 'onBack', 'onOpen', 'onClose' }) do
        if def[name] ~= nil and not mayCall(def[name]) then return false, name .. ' must be a function' end
    end

    local key = owner .. ':' .. id
    pages[key] = {
        key = key, owner = owner, id = id, label = label, desc = pageText(def.desc, 300) or '',
        rows = def.rows, onSelect = def.onSelect, onBack = def.onBack, onOpen = def.onOpen, onClose = def.onClose,
    }
    sortPages()
    refreshKeepingPick()
    if menuOpen then
        if page and page.key == key then buildPage(nil) end
        SendDevMenu()
    end
    return true
end

exports('RegisterDevPage', function(id, def)
    return registerPage(GetInvokingResource() or GetCurrentResourceName(), id, def)
end)

--- Your page's rows changed (a scene loaded, a list arrived): asked for again if it is on screen.
---@param id string
---@return boolean ok, string|nil why
local function refreshPage(owner, id)
    local key = type(id) == 'string' and (owner .. ':' .. id) or nil
    if not key or not pages[key] then return false, 'no page of yours has that id' end
    if menuOpen and page and page.key == key then
        local row = page.list and page.list[pageIndex]
        buildPage(row and row.rowId)
        SendDevMenu()
    end
    return true
end

exports('RefreshDevPage', function(id)
    return refreshPage(GetInvokingResource() or GetCurrentResourceName(), id)
end)

--- Take your page out of /w (it goes by itself when your resource stops).
---@param id string
---@return boolean ok, string|nil why
exports('RemoveDevPage', function(id)
    local owner = GetInvokingResource() or GetCurrentResourceName()
    local key = type(id) == 'string' and (owner .. ':' .. id) or nil
    if not key or not pages[key] then return false, 'no page of yours has that id' end
    removePage(key)
    return true
end)

-- The /w pages and debug tools other resources add, in GetRegistrations with the registries (Registry.addLister).
Registry.addLister('devPage', function()
    local out = {}
    for key, p in pairs(pages) do out[#out + 1] = { key = key, owner = p.owner } end
    return out
end)
Registry.addLister('debugTool', function()
    local out = {}
    for key, row in pairs(debugTools) do out[#out + 1] = { key = key, owner = row.owner } end
    return out
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then return end
    local gone = {}
    for key, p in pairs(pages) do
        if p.owner == resource then gone[#gone + 1] = key end
    end
    for _, key in ipairs(gone) do removePage(key) end
end)

-- ============================================
-- Debug tools from other resources
-- ============================================
--
-- The Debug switch shows the debug tools under it: whip_core's, then any resource's own (RegisterDebugTool), a
-- switch whose onToggle(on) the resource answers. Off, Debug turns every one of them off; so does developer mode
-- going off. A resource's tools go when it stops, and whip_core forgets them when it restarts (Whip.register).

local function sortDebugTools()
    debugToolKeys = {}
    for key in pairs(debugTools) do debugToolKeys[#debugToolKeys + 1] = key end
    table.sort(debugToolKeys, function(a, b)
        local la, lb = debugTools[a].name:lower(), debugTools[b].name:lower()
        if la ~= lb then return la < lb end
        return a < b
    end)
end

--- Switch one on or off through its owner's onToggle. It stays off if onToggle answers false or throws.
setDebugTool = function(row, on)
    on = on == true
    if row.active == on then return end
    row.active = on
    local ok, res = pcall(row.onToggle, on)
    if not ok then
        print(('[whip_core:dev] %s\'s debug tool "%s" failed: %s'):format(row.owner, row.name, tostring(res)))
        row.active = false
    elseif on and res == false then
        row.active = false
    end
end

--- The Debug switch. Off, every debug tool goes off with it.
setDebug = function(on)
    debugSwitch.active = on == true
    if not debugSwitch.active then
        for _, tool in ipairs(tools) do
            if tool.debug and tool.active then
                tool.active = false
                local handler = ToolHandlers[tool.name]
                if handler and handler.exit then pcall(handler.exit) end
            end
        end
        for _, key in ipairs(debugToolKeys) do setDebugTool(debugTools[key], false) end
    end
    refreshKeepingPick()
end

--- Add a switch of your own to /w's debug tools, or replace the one you added under this id. Called inside
--- Whip.register: whip_core forgets them when it restarts.
---@param id string  letters, digits, _ and -; yours only
---@param def table  { label, desc?, onToggle(on) } — onToggle answers false to stay off
---@return boolean ok, string|nil why
exports('RegisterDebugTool', function(id, def)
    local owner = GetInvokingResource() or GetCurrentResourceName()
    if type(id) ~= 'string' or #id > 48 or not id:match('^[%w_%-]+$') then
        return false, 'the id must be letters, digits, _ or - (48 at most)'
    end
    if type(def) ~= 'table' then return false, 'the tool must be a table' end
    local label = pageText(def.label, 40)
    if not label then return false, 'label (its row in /w) must be a string' end
    if not mayCall(def.onToggle) then return false, 'onToggle (a function run when it is switched) is required' end

    local key = owner .. ':' .. id
    local was = debugTools[key]
    debugTools[key] = { name = label, desc = pageText(def.desc, 300) or '', active = was and was.active or false,
                        debugTool = key, owner = owner, onToggle = def.onToggle }
    sortDebugTools()
    refreshKeepingPick()
    if menuOpen and not page then SendDevMenu() end
    return true
end)

--- Take your debug tool out of /w (it goes by itself when your resource stops). One that is on is not switched off.
---@param id string
---@return boolean ok, string|nil why
exports('RemoveDebugTool', function(id)
    local key = type(id) == 'string' and ((GetInvokingResource() or GetCurrentResourceName()) .. ':' .. id) or nil
    if not key or not debugTools[key] then return false, 'no debug tool of yours has that id' end
    debugTools[key] = nil
    sortDebugTools()
    refreshKeepingPick()
    if menuOpen and not page then SendDevMenu() end
    return true
end)

AddEventHandler('onResourceStop', function(resource)
    local gone = false
    for key, row in pairs(debugTools) do
        if row.owner == resource then debugTools[key] = nil; gone = true end
    end
    if not gone then return end
    sortDebugTools()
    refreshKeepingPick()
    if menuOpen and not page then SendDevMenu() end
end)

-- ============================================
-- /w Command — Toggle Dev Menu
-- ============================================

--- Forward declaration. The command below starts the menu's input thread, which is defined in the
--- next section — and a Lua local is only visible to code compiled AFTER it, so without this line
--- the call inside the command would compile as a GLOBAL lookup and find nil the first time
--- anybody typed /w. Same reason client/zones.lua forward-declares ejectFromZone.
local StartMenuThread

--- Open or shut the menu. /w, and the F1 wheel's Dev Tools (below). Waits for the server's answer, so
--- it runs in a thread: a command's, or the wheel's onSelect.
local function ToggleDevMenu()
    if not menuOpen then
        -- The server says whether this account has dev tools, and whether developer mode is on: the menu
        -- is the switch alone, or the switch and the tools.
        -- NOT UNDER pcall. Callback never throws (a refusal or a timeout answers `false, why`), and a wait
        -- inside a pcall raises an error that pcall would swallow, leaving the menu shut without a word.
        local access, why = Callback('whip_core:devtools:access')
        if type(access) ~= 'table' then
            UI.Notify('Dev tools: ' .. tostring(why or 'no answer from the server'), 'error')
            return
        end
        if access.eligible ~= true then
            -- Not an admin: said, and the server console gets the line that would make them one
            -- (server/devtools_base.lua, DevTools.askedForTools).
            UI.Notify('/w is the admin tools, and you are not an admin on this server', 'error')
            TriggerServerEvent('whip_core:devtools:refusedW')
            return
        end
        dev.eligible = true
        -- Through devModeChanged, so a client that thought otherwise turns its tools off too.
        if (access.on == true) ~= dev.on then devModeChanged(access.on == true) end
        refreshShown()
        menuOpen = true
        menuIndex = firstIndex()
        -- AFTER the flag: the input thread's loop condition IS menuOpen, so starting it any
        -- earlier would have it read false and exit on the spot.
        StartMenuThread()
        -- On the page it was shut on, when that page is still here (and the tool list behind it, its row picked).
        local again = dev.on and lastPage and pages[lastPage] and lastPage or nil
        lastPage = nil
        if again then
            for i, row in ipairs(shown) do
                if row.page == again then menuIndex = i break end
            end
            page = { key = again }
            callPage(pages[again], 'onOpen')
            if page and page.key == again and pages[again] then buildPage(nil) else page = nil end
        end
        SendNUIMessage(menuMessage('devMenuShow'))
    else
        closeMenu()
    end
end

-- In a thread of its own: the open waits on the server, and a thread is where whip waits.
RegisterCommand('w', function() CreateThread(ToggleDevMenu) end, false)

-- ---- whip_core's own pages ----
--
-- RegisterDevPage is for other resources: whip_core never calls its own exports. Its tools use these, the
-- same pages under 'whip_core:<id>'.
DevPages = {}

function DevPages.register(id, def) return registerPage(GetCurrentResourceName(), id, def) end
function DevPages.refresh(id) return refreshPage(GetCurrentResourceName(), id) end

--- /w open on this page (its own command, or back after something it played). Yields: opening asks the server.
function DevPages.open(id)
    local key = GetCurrentResourceName() .. ':' .. tostring(id)
    if not pages[key] then return end
    if menuOpen then
        if not (page and page.key == key) then
            for i, row in ipairs(shown) do
                if row.page == key then menuIndex = i break end
            end
            openPage(key)
        end
        return
    end
    lastPage = key
    ToggleDevMenu()
end

--- /w shut (remembering the page it is on), while one of whip_core's pages plays something on screen.
function DevPages.close()
    if menuOpen then closeMenu() end
end

--- Ask the server whether this account has dev tools and whether developer mode is on.
local function askAccess()
    CreateThread(function()
        local ok, access = pcall(Callback, 'whip_core:devtools:access')
        if ok and type(access) == 'table' then
            dev.eligible = access.eligible == true
            if (access.on == true) ~= dev.on then devModeChanged(access.on == true) end
        end
    end)
end

-- ON THE F1 WHEEL. Shown to a holder of
-- whip.devtools, developer mode on or off — it is how a developer reaches the switch — so it asks
-- dev.eligible (askAccess, at load and when dev tools are given or taken), not the whip.devtools ACE,
-- which with developer mode off answers no. The server still decides: ToggleDevMenu asks again.
-- Also while downed (alive = false): God Mode and Restore Player Cores are what a downed admin reaches for.
AddEventHandler('whip_core:onReady', function()
    Actions.add(GetCurrentResourceName(), {
        id          = 'devmenu',
        at          = { radial = true },
        label       = 'Dev Tools',
        icon        = 'devtools',
        description = 'Open the /w menu',
        require     = { alive = false },
        canInteract = function() return dev.eligible end,
        onSelect    = function() CreateThread(ToggleDevMenu) end,
    })
end)
AddEventHandler('whip_core:player:loaded', function() askAccess() end)
RegisterNetEvent('whip_core:client:devtoolsGranted', function() askAccess() end)
-- whip_core restarted under a loaded character: no 'loaded' comes, so ask once now.
CreateThread(function()
    Wait(2000)
    if PlayerLoaded then askAccess() end
end)

-- ============================================
-- Menu Input Thread
-- ============================================

--- True while the input thread below is alive, so opening twice cannot start two readers of the
--- same keys — which would step the selection two entries per press.
local menuThreadRunning = false

--- BORN WITH THE MENU, NOT WITH THE CLIENT: the menu's open path starts it and it ends when the menu
--- shuts, so a client that never types /w pays nothing for it.
StartMenuThread = function()
    if menuThreadRunning then return end
    menuThreadRunning = true
    -- Esc (so it closes the menu, not the pause menu) and the controls the menu reads: a disabled
    -- reader also fires for an ENABLED control, so a click would toggle a tool AND fire the weapon.
    -- And a mode: the menu takes no NUI focus and reads the D-pad and A itself, so the pad's own
    -- buttons (phone, radial, engine, inventory, a prompt's A) are stood down (IsGameInputFree).
    ControlBlocks.hold('devMenu', { controls = { 200, 24, 257, 241, 242, 14, 15 }, mode = true })

    CreateThread(function()
        while menuOpen do
            local changed = false

            -- Up arrow OR scroll wheel up. Separators are labels, not entries, and so are a page's
            -- notes: step again until a row that can be picked (there is always one: the switch on the
            -- tool list, the way back on a page). The rows ON SCREEN: the switch alone while developer
            -- mode is off, a page's rows while one is open.
            if IsDisabledControlJustPressed(0, 172) or IsDisabledControlJustPressed(0, 241) then
                stepSelection(-1)
                changed = true
            end

            -- Down arrow OR scroll wheel down
            if IsDisabledControlJustPressed(0, 173) or IsDisabledControlJustPressed(0, 242) then
                stepSelection(1)
                changed = true
            end

            -- Enter OR left mouse — toggle the selected tool, or pick the page's row
            if IsDisabledControlJustPressed(0, 201) or IsDisabledControlJustPressed(0, 24) then
                -- A tool that throws closes the menu rather than killing this thread with the
                -- menu's keys still held off. (A page's own functions are under pcall already.)
                local ok, err = pcall(pickRow)
                if not ok then
                    print(('[whip_core:dev] a tool failed to toggle: %s'):format(tostring(err)))
                    closeMenu()
                end
                changed = true
            end

            -- Escape closes the menu. Backspace (or B) closes it too, but on a page it goes back first.
            -- Esc is asked first: it also fires 177, and Esc on a page must close, not go back.
            -- Disabled readers: a tool may hold Backspace.
            if IsDisabledControlJustPressed(0, 200) then
                closeMenu()
            elseif IsDisabledControlJustPressed(0, 177) then
                if page then
                    pageBack()
                    changed = true
                else
                    closeMenu()
                end
            end

            if changed and menuOpen then
                SendDevMenu()
            end

            Wait(0)
        end

        ControlBlocks.release('devMenu')
        menuThreadRunning = false
    end)
end

-- Menu rendering is handled by NUI (html/js/dev-menu.js)

-- ============================================
-- The clipboard — one way in, one way out
-- ============================================
--
-- CEF refuses the clipboard API to a page without focus, so a copy takes the focus for a moment —
-- only when nothing holds it (a page that already has it can copy) — and gives back only what it
-- took, so a copy over an open screen keeps that screen's cursor.

local clipboardTookFocus = false
local clipboardGen       = 0

--- Give the focus back, if a copy took it. `gen` is the floor timer's copy: a timer left over from an
--- earlier copy must not let go of a later one's focus.
local function giveClipboardFocusBack(gen)
    if not clipboardTookFocus then return end
    if gen ~= nil and gen ~= clipboardGen then return end
    clipboardTookFocus = false
    -- Its own hold only: a dialog or screen that opened while the copy held the focus keeps it
    -- (client/focus.lua).
    Focus.release('clipboard')
end

local clipboardThen = nil   -- the copy in flight's own onDone (CopyToClipboard)

--- Put text on the player's clipboard. The one way every dev tool copies.
---
--- A FLOOR UNDER THE GRAB: clipboardDone only fires if the page got the message and the copy
--- resolved. If anything swallows it, the focus is given back after two seconds anyway.
---
--- `onDone(ok)`, when given, hears how this copy went and says so itself (no generic "could not copy").
---@param text string
---@param onDone function|nil
function CopyToClipboard(text, onDone)
    if not IsNuiFocused() then
        clipboardTookFocus = true
        clipboardGen = clipboardGen + 1
        local gen = clipboardGen
        Focus.take('clipboard', { cursor = false })
        SetTimeout(2000, function() giveClipboardFocusBack(gen) end)
    end
    clipboardThen = onDone
    SendNUIMessage({ action = 'copyToClipboard', text = tostring(text or '') })
end

--- What the tools do when a copy lands, in the order they registered (their load order: coords,
--- camera, object viewer). Each checks its OWN "am I open" flag, so the flags stay local to their
--- tools.
local clipboardCopiedHandlers = {}

--- Run `fn` after every copy that worked — for a tool that shows its own "copied" feedback while it
--- is open. Registered once, at the tool's file scope.
---@param fn function
function OnClipboardCopied(fn)
    clipboardCopiedHandlers[#clipboardCopiedHandlers + 1] = fn
end

RegisterNUICallback('clipboardDone', function(data, cb)
    giveClipboardFocusBack(nil)
    -- Only a copy that happened says so (the page's `ok`).
    local ok = type(data) == 'table' and data.ok == true
    local thenFn = clipboardThen
    clipboardThen = nil
    if thenFn then
        local fine, err = pcall(thenFn, ok)
        if not fine then print('[whip_core] a copy\'s onDone failed: ' .. tostring(err)) end
    elseif not ok then
        UI.Notify('Could not copy — close the screen that has the mouse, then try again', 'error')
    end
    if ok then
        for _, fn in ipairs(clipboardCopiedHandlers) do fn() end
    end
    cb('ok')
end)

-- ============================================
-- Cleanup — onResourceStop, and dev tools taken back
-- ============================================

--- Every lit tool's exit, each in its own pcall.
local function exitAllTools()
    for _, tool in ipairs(tools) do
        if tool.active then
            local handler = ToolHandlers[tool.name]
            if handler and handler.exit then
                pcall(handler.exit)
            end
            tool.active = false
        end
    end
end

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    exitAllTools()
end)

--- One mode's close, said in F8 if it throws, so the rest still close.
local function closeMode(what, fn)
    local ok, err = pcall(fn)
    if not ok then print(('[whip_core:dev] could not close %s: %s'):format(what, tostring(err))) end
end

--- EVERYTHING A DEVELOPER HAS ON, OFF: the /w tools, the overlays their chat commands start, the world
--- modes /whip opens, and /whip itself. What developer mode going off and dev tools taken back both do.
local function devtoolsOff()
    -- A resource's page open in /w is left (its onClose), and /w does not open on it again.
    dropPage()
    exitAllTools()
    setDebug(false)   -- and other resources' debug tools
    -- The overlays also have chat commands, which do not light their /w entry.
    ToggleStatsDebug(false); ToggleVehStatDebug(false)
    -- The world modes, each only while it runs: the zone and door editors' exits are not safe twice. Before
    -- the panel: a mode ending hands the screen back to /whip, unless it is 'stopped'.
    if PropertyEditor and PropertyEditor.isActive and PropertyEditor.isActive() then
        closeMode('the property editor', function() PropertyEditor.stop('stopped') end)
    end
    if PropertyWizard and PropertyWizard.active and PropertyWizard.active() then
        closeMode('the property wizard', PropertyWizard.cancel)
    end
    if ZoneEditorActive and ExitZoneEditor then closeMode('the zone editor', ExitZoneEditor) end
    if DoorEditorActive and ExitDoorEditor then closeMode('the door editor', ExitDoorEditor) end
    -- The Ground page's blips, markers and grid outlive the menu, so they are turned off here.
    if GroundManagerOff then closeMode('the ground marks', GroundManagerOff) end
    -- /whip opened directly is not a lit /w tool, and its sections teleport on the client.
    if WhipPanelIsOpen() then WhipPanelClose() end
end

-- TAKEN BACK. With dev tools taken away /w is refused, so God Mode, Invisible and Noclip must go off
-- here: the server says so (server/devtools.lua); everything goes off and the menu shuts. A switch-on
-- the server refuses (confirmAccess, above) lands here too.
devtoolsTakenBack = function()
    if menuOpen then
        menuOpen = false
        SendNUIMessage({ action = 'devMenuHide' })
    end
    local was = dev.on
    dev.on = false
    SendNUIMessage({ action = 'devModeState', on = false })   -- the inventory's Destroy goes (js/inventory.js)
    if was then WhipEmit('whip_core:devtools:modeChanged', { on = false }) end
    refreshShown()
    devtoolsOff()
    askAccess()   -- dev tools themselves may be gone: the F1 wheel's entry follows
end

-- DEVELOPER MODE ON OR OFF (the switch, or the server: dev tools lost, the switch on another road). Off is
-- everything off, as if dev tools had been taken back, but the menu stays — the switch alone — so it
-- can go straight back on.
devModeChanged = function(on)
    on = on == true
    if dev.on == on then return end
    dev.on = on
    -- The page: the inventory offers Destroy only while it is on (js/inventory.js, 'devModeState').
    SendNUIMessage({ action = 'devModeState', on = on })
    -- Satellites hear it too (types/events.lua): what they show only to developers comes and goes with it.
    WhipEmit('whip_core:devtools:modeChanged', { on = on })
    if on then dev.eligible = true else devtoolsOff() end
    refreshShown()
    -- What asked the server about whip.devtools and remembered the answer: the F1 wheel's admin actions.
    Actions.refreshAce('whip.devtools')
    if menuOpen then
        if not on then menuIndex = 1 end
        SendDevMenu()
    end
    UI.Notify(on and 'Developer mode on' or 'Developer mode off', on and 'success' or 'info')
end

RegisterNetEvent('whip_core:client:devtoolsRevoked', function() devtoolsTakenBack() end)
RegisterNetEvent('whip_core:client:devMode', function(on) devModeChanged(on) end)

-- AN EXPERIMENTAL FEATURE SWITCHED (/whip → Settings → Experimental features): its rows come or go, and a tool of
-- one turned off while it was on goes off with it.
Settings.onChange('Experimental', function()
    for _, tool in ipairs(tools) do
        if tool.experimental and tool.active and not experimentalOn(tool.experimental) then
            tool.active = false
            if ToolHandlers[tool.name] then ToolHandlers[tool.name].exit() end
        end
    end
    refreshKeepingPick()
    if menuOpen and not page then SendDevMenu() end
end)
