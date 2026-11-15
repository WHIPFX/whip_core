-- ============================================
-- whip_core — the composer
--
-- One line of text, typed into the player capsule.
--
-- The capsule at the bottom left has three states, and this file owns the second one: the stats
-- step aside and the capsule becomes a text field. The third state (a notification) lives in
-- html/js/ui.js; the default state is html/js/status-hud.js.
--
-- In whip_core, not whip_chat: whip_chat has its own `ui_page` (a different browser frame), and
-- the capsule can only TRANSFORM into the field if the field lives in the capsule's document. The
-- seam between the two resources is COMPOSING vs READING:
--
--     whip_core (here)          whip_chat
--     the input, the caret      the message log
--     the suggestion list       templates, colour codes
--     the history               the mode registry
--     NUI focus                 all transport, and ExecuteCommand
--
-- This file knows nothing about chat (`OpenComposer`, not `OpenChat`): anything wanting a single
-- typed line gets the same capsule. Like a dialog, it lets go of the NUI focus when it closes, so
-- a caller with its own screen still up takes the focus back in onSubmit/onCancel.
--
-- How a caller uses it (functions cross the export like AddAction's):
--
--     exports.whip_core:OpenComposer({
--         placeholder = 'Say something',
--         maxLength   = 256,
--         onSubmit    = function(text, mode) ... end,
--         onCancel    = function() ... end,
--     })
--
-- ============================================

local RESOURCE = GetCurrentResourceName()

--- How long the composer may hold the keyboard with no answer from the page before it gives up.
---
--- Nobody types one line for two minutes: if the box has been open that long the page did not
--- answer and the player has a captured keyboard. The failsafe belongs with whatever called
--- SetNuiFocus, which is this file.
local STUCK_MS = 120000

--- The same, typed on the pad keyboard (opts.pad): a line picked out key by key takes longer.
local PAD_STUCK_MS = 300000

--- How long an un-focused composer may sit open before it takes the keyboard anyway.
---
--- `deferFocus` lets a key binding open the capsule on the PRESS and take the keyboard on the
--- RELEASE (see FocusComposer). If the release half never runs (the resource stopped, the player
--- alt-tabbed), the focus arrives late rather than never.
local DEFER_ARM_MS = 250

-- ============================================
-- State
-- ============================================

--- The live session (the caller's opts table), or nil. One at a time: the capsule is one row.
local _session   = nil
local _openedAt  = 0
local _hasFocus  = false

--- Has the raw-NUI request shape already been dumped after an origin mismatch?
---
--- Once per session: a refused submit can repeat as fast as the player types.
local _originShapeReported = false

-- ============================================
-- Where the origin lives
-- ============================================
--
-- The security boundary: what arrives here can end up run as a command by whip_chat's onSubmit,
-- so it must come from whip's own pages, not any resource's web view. whip_core's manifest has
-- strict mode on for all its callbacks (fxmanifest.lua); the origin check stays anyway, as the one
-- callback that can end in a command, so it does not depend on a manifest line.
--
-- On Legacy the origin is `requestData.resource`. On FiveM for GTAV Enhanced that field is nil and
-- the name is in the Origin header with a `cfx-nui-` prefix:
--
--     Origin = https://cfx-nui-whip_core
--
-- The prefix pattern is tried FIRST: the bare-host pattern would also match and return
-- `cfx-nui-whip_core`, which refuses. Order matters here.
--
-- Safe to trust: the Origin header is set by CEF, not by the page's JavaScript.

--- Pull the calling resource's name out of a raw NUI request, on either platform.
--- @param requestData table The first argument RegisterRawNuiCallback hands its handler
--- @return string|nil origin The resource name, or nil if none of the known shapes carried one
local function ReadOrigin(requestData)
    local origin = requestData.resource
        or requestData.resourceName
        or requestData.origin

    if not origin then
        local h = requestData.headers
        if type(h) == 'table' then
            local ref = h.Origin or h.origin or h.Referer or h.referer
            if type(ref) == 'string' then
                origin = ref:match('^https?://cfx%-nui%-([^/]+)')   -- Enhanced / modern CEF
                    or ref:match('^nui://([^/]+)')                  -- older scheme
                    or ref:match('^https?://([^/]+)')               -- bare host, last resort
            end
        end
    end

    return origin
end

--- Print the request shape once, so an unknown origin field can be identified rather than guessed.
local function ReportOriginShape(requestData)
    if _originShapeReported then return end
    _originShapeReported = true

    print('[whip_core] --- composer request shape, so the origin field can be identified ---')
    for k, v in pairs(requestData) do
        if k == 'body' then
            -- The player's own typed line. No reason to print it back, and every reason not to.
            print('[whip_core]   body = <withheld>')
        elseif type(v) == 'table' then
            print(('[whip_core]   %s = <table>'):format(tostring(k)))
            for hk, hv in pairs(v) do
                print(('[whip_core]       %s = %s'):format(tostring(hk), tostring(hv)))
            end
        else
            print(('[whip_core]   %s = %s (%s)'):format(tostring(k), tostring(v), type(v)))
        end
    end
    print('[whip_core] --- end ---')
end

-- ============================================
-- Closing
-- ============================================

--- Give the keyboard back and put the capsule into whatever state it should be in next.
---
--- Separate from CloseComposer because order matters: focus is released before any callback runs
--- (see the submit handler).
local function ReleaseFocus()
    if not _hasFocus then return end
    _hasFocus = false
    Focus.release('composer')
end

--- The keyboard, no cursor: typing. On the pad keyboard (opts.pad), a screen the pad drives, as
--- client/keyboard.lua's: the pad driver takes the cursor away and keeps the pad reaching the page.
local function TakeFocus()
    _hasFocus = true
    if _session and _session.pad == true then
        Focus.take('composer', { screen = true })
    else
        Focus.take('composer', { cursor = false, screen = true })
    end
end

--- Tear the session down. Safe to call when nothing is open.
--- @param silent boolean|nil When true, the caller's onCancel is NOT run
local function EndSession(silent)
    local s = _session
    _session = nil
    _openedAt = 0

    ReleaseFocus()
    SendNUIMessage({ action = 'composerClose' })

    -- `~= nil`, not a type check: a callback that crossed the export boundary does not answer
    -- 'function' (see OpenComposer).
    if s and not silent and s.onCancel ~= nil then
        -- pcall'd: another resource's code, which must not leave whip_core mid-teardown.
        local ok, err = pcall(s.onCancel)
        if not ok then
            print(('[whip_core] composer onCancel threw: %s'):format(tostring(err)))
        end
    end
end

-- ============================================
-- The only tick this file has: born with the session and gone with it, at 500ms (what it watches
-- is measured in seconds and quarter-seconds).
-- ============================================

--- Start the watchdog for the session that is open right now.
local function StartWatchdog()
    CreateThread(function()
        -- Captured: if this session ends and another opens, it stops matching _session and this
        -- thread retires.
        local mine = _session

        while mine ~= nil and _session == mine do
            Wait(500)
            if _session ~= mine then break end

            local age = GetGameTimer() - _openedAt

            -- ---- deferred focus that never arrived ----
            if not _hasFocus and age > DEFER_ARM_MS then
                TakeFocus()
            end

            -- ---- stuck open ----
            local stuckMs = mine.pad == true and PAD_STUCK_MS or STUCK_MS
            if age > stuckMs then
                print(('[whip_core] the composer was open for %ds with no reply from the page — '
                    .. 'releasing focus. The NUI callback is probably not reaching Lua.')
                    :format(stuckMs / 1000))
                -- Not silent: the opener is still running and must hear it closed (or whip_chat's
                -- open flag stays set).
                EndSession(false)
                break
            end
        end
    end)
end

-- ============================================
-- The public surface
-- ============================================

--- Open the capsule as a text field.
---
--- @param opts table
---   placeholder string|nil   Ghost text shown while the field is empty
---   prefill     string|nil   Text the field starts with, caret at the end
---   maxLength   number|nil   Default 256
---   modes       table|nil    { { name, displayName, color }, ... } — cycled with Tab-less
---                            right-arrow by the page; the active one comes back in onSubmit
---   suggestions table|nil    { { name = '/tp', help = '', params = { { name, help } } } }
---   onSubmit    function     (text, mode) — mode is nil when no mode is active
---   onCancel    function|nil ()
---   onScroll    function|nil (delta) — PageUp/PageDown, for a log living in another frame
---   deferFocus  boolean|nil  Open WITHOUT taking the keyboard; call FocusComposer to take it
---   pad         boolean|nil  Typed on whip's pad keyboard, a controller (Chat on the
---                            wheel): the text in the keyboard's own window above the keys, the capsule
---                            left as it is; Done submits as Enter does. No modes or suggestions there.
---   title       string|nil   With pad: what the keyboard says over the keys ('Chat')
--- @return boolean opened False if something was already open, or opts was unusable
local function OpenComposer(opts)
    if type(opts) ~= 'table' then return false end

    -- Present, not `type(...) == 'function'`: a function handed over through an export is a
    -- callable whose Lua type is not 'function'. nil is still refused; a value that is not
    -- callable after all fails at the pcall'd call site.
    if opts.onSubmit == nil then
        print('[whip_core] OpenComposer needs an onSubmit — refusing to open a field whose '
            .. 'result would go nowhere.')
        return false
    end

    -- One at a time: a second composer would cancel somebody's half-typed line.
    if _session then return false end

    -- Not over a dialog: the dialog lets go of the focus when it closes, which would leave this box
    -- with no keyboard. A progress bar takes no focus, so chat during one is fine.
    if UI and UI.IsBusy and UI.IsBusy() and not UI.IsProgressActive() then return false end
    -- Nor over another screen holding the focus. (Screens themselves are the caller's call: whip_chat
    -- asks IsAnyScreenOpen.)
    if FocusScreenUp ~= nil and FocusScreenUp('composer') then return false end
    -- Nor while a value is typed into a prompt (client/prompt_typing.lua): its keys reach the game too, so chat's T,
    -- typed into the capsule, would otherwise open chat over it.
    if Interactions ~= nil and Interactions.inputActive ~= nil and Interactions.inputActive() then return false end

    _session  = opts
    _openedAt = GetGameTimer()
    -- Whose it is: only the owner may close it, and the owner stopping closes it. `opts` is
    -- whip_core's copy of the caller's table, so the field is ours to set.
    _session.__owner = GetInvokingResource() or RESOURCE

    SendNUIMessage({
        action      = 'composerOpen',
        placeholder = opts.placeholder or '',
        prefill     = opts.prefill or '',
        maxLength   = tonumber(opts.maxLength) or 256,
        modes       = opts.modes or {},
        suggestions = opts.suggestions or {},
        pad         = opts.pad == true,
        title       = type(opts.title) == 'string' and opts.title:sub(1, 80) or nil,
    })

    if not opts.deferFocus then
        TakeFocus()
    end

    StartWatchdog()
    return true
end

--- Take the keyboard, for a caller that opened with `deferFocus`.
---
--- RegisterKeyMapping calls `+name` on key down and `-name` on key up. Taking the keyboard on the
--- DOWN leaves the opening key held as the browser starts listening (a "t" in the field). So the
--- capsule opens on the press and takes the keyboard on the release.
--- @return boolean focused
local function FocusComposer()
    if not _session or _hasFocus then return false end
    TakeFocus()
    return true
end

--- Close the composer without submitting. The caller's onCancel runs.
---
--- Only the resource that opened it (or whip_core) may close it.
--- @return boolean closed
local function CloseComposer()
    if not _session then return false end
    local caller = GetInvokingResource() or RESOURCE
    if caller ~= RESOURCE and caller ~= _session.__owner then return false end
    EndSession(false)
    return true
end

--- Is a composer open right now?
--- @return boolean
local function IsComposerOpen()
    return _session ~= nil
end

-- Global too, for client/ui.lua: a dialog does not open over the composer.
ComposerIsOpen = IsComposerOpen

exports('OpenComposer', OpenComposer)
exports('FocusComposer', FocusComposer)
exports('CloseComposer', CloseComposer)
exports('IsComposerOpen', IsComposerOpen)

-- ============================================
-- Inbound: the player pressed Enter or Escape
-- ============================================

--- RAW callback, not RegisterNUICallback: it exposes the ORIGIN resource (see "Where the origin lives").
RegisterRawNuiCallback('composerResult', function(requestData, cb)
    -- Release focus first, unconditionally, before any check can return early: a rejected or
    -- malformed submit must not leave NUI focus held. Give the controls back, THEN decide whether
    -- to honour what was sent.
    local session = _session
    _session = nil
    _openedAt = 0
    ReleaseFocus()
    SendNUIMessage({ action = 'composerClose' })

    -- No session means a stale or duplicated submit — the page answering twice, or answering
    -- after a CloseComposer. Nothing to do, and nothing to complain about.
    if not session then
        cb({ body = 'ok' })
        return
    end

    local ok, data = pcall(json.decode, requestData.body)
    if not ok or type(data) ~= 'table' or data.canceled then
        if session.onCancel ~= nil then
            local pok, err = pcall(session.onCancel)
            if not pok then
                print(('[whip_core] composer onCancel threw: %s'):format(tostring(err)))
            end
        end
        cb({ body = 'ok' })
        return
    end

    local origin = ReadOrigin(requestData)
    if origin ~= RESOURCE then
        print(('[whip_core] REFUSED a composer submit from "%s" — only this resource\'s own '
            .. 'page may type into the capsule'):format(tostring(origin)))
        ReportOriginShape(requestData)
        cb({ body = 'ok' })
        return
    end

    local message = tostring(data.message or '')
    if #message == 0 then
        if session.onCancel ~= nil then pcall(session.onCancel) end
        cb({ body = 'ok' })
        return
    end

    -- The caller decides what the text means (a command, a chat mode): the raw line is handed over.
    local pok, err = pcall(session.onSubmit, message, data.mode)
    if not pok then
        print(('[whip_core] composer onSubmit threw: %s'):format(tostring(err)))
    end

    cb({ body = 'ok' })
end)

--- The page telling us the player scrolled a log that lives somewhere else.
---
--- PageUp and PageDown belong to whip_chat's message list, in another frame without the keyboard.
RegisterNUICallback('composerScroll', function(data, cb)
    local s = _session
    -- `~= nil` again, for the same reason as every other callback in this file.
    if s and s.onScroll ~= nil then
        pcall(s.onScroll, tonumber(data and data.delta) or 0)
    end
    cb('ok')
end)

-- ============================================
-- Failsafes
-- ============================================

--- Force the controls back. The escape hatch for "the capsule has my keyboard and will not let go".
---
--- Touches no session state and asks no questions: it hands the controls back. Reachable from the
--- F8 console. Developer mode only.
DevCommand('resetcomposer', function()
    _session  = nil
    _openedAt = 0
    _hasFocus = false
    Focus.releaseAll()   -- every hold, not just the composer's: the player is stuck, whatever holds it
    SendNUIMessage({ action = 'composerClose' })
    print('[whip_core] composer closed and NUI focus released.')
end)

--- Losing whip_core with NUI focus held leaves the player unable to move. Losing the resource that
--- OPENED the composer leaves it open with nobody to answer: it is closed silently — its
--- onCancel lives in the resource that just stopped.
AddEventHandler('onResourceStop', function(resource)
    if resource == RESOURCE then
        Focus.release('composer')   -- client/focus.lua hands everything back as whip_core stops anyway
        return
    end
    if _session and _session.__owner == resource then EndSession(true) end
end)

-- A death cancels it (its focus would stay over the death screen and block the respawn hold). The caller's
-- onCancel runs, as for Esc.
AddEventHandler('whip_core:player:died', function()
    if _session then EndSession(false) end
end)
