-- ============================================
-- WHIP'S KEYBOARD — typing on a controller, for any resource
-- ============================================
--
-- A controller cannot type, and a text box asks it to. This opens whip's on-screen keyboard
-- (html/js/pad-keyboard.js) and waits for what was typed:
--
--   local text = exports.whip_core:OpenKeyboard({ title = 'Search', value = '', maxLength = 40 })
--   -- a satellite: Whip.call('OpenKeyboard', opts), from a thread
--   -- text: the string, or nil when the player left it (B, Cancel)
--
--   opts.title      what is being typed, said over the keys ('Search', 'Price')
--   opts.value      the text it starts with
--   opts.placeholder  ghost text in the empty field ('Name the car')
--   opts.numeric    true: digits, minus and point only (a number pad)
--   opts.maxLength  at most this many characters
--   opts.predict    false: no word suggestions over the keys (a plate, a code); they are on otherwise
--
-- Words and languages (html/js/keyboard-words.js): the keyboard suggests how to finish
-- the word being typed, in the player's language, from that language's pack in html/keyboard/. Which
-- languages there are is Config.Keyboard; this file tells the page those, and the one GTA is set to. Each
-- player's own choice of language, and suggestions on or off, are theirs (Settings → Server → Controller).
--
-- It is whip's page that shows it, over any resource's own page: the focus is taken here while it is
-- up and given back after (FiveM keeps one focus vote per resource, so a satellite's own focus stands
-- under it). While it is up the pad is the keyboard's alone (its page scope): whip_core:keyboard:opened and
-- whip_core:keyboard:closed say so, and a Whip.padScreen stops reading the pad between them by itself; any other
-- resource that reads the pad itself leaves it alone until this answers. One at a time: asking again closes the one before,
-- which answers nil. The right stick moves it round the screen, and it opens where it was left.

local Keyboard = {}   -- (a local: the export is the way in; whip's page opens it itself)

local pending = nil   -- { id, owner, p }: the one up now
local lastId = 0

--- The one up now has gone (`pending` already cleared): the focus back, then the asker's answer, the text or nil.
--- Every way it goes ends here, so whip_core:keyboard:closed is said once for each whip_core:keyboard:opened: a
--- Whip.padScreen under it stops reading the pad on the one and starts again on the other (lib/satellite.lua).
local function finish(k, text)
    Focus.release('keyboard')
    WhipEmit('whip_core:keyboard:closed', { id = k.id })
    k.p:resolve(text)
end

--- Close the one up now, if any, answering nil (`tellPage`: take it off the screen too).
local function closePending(tellPage)
    local k = pending
    if not k then return end
    pending = nil
    if tellPage then SendNUIMessage({ action = 'padKeyboardClose', id = k.id }) end
    finish(k, nil)
end

--- Open it and wait for the text: the string, or nil when it was left. Call from a thread.
---@param opts table|nil  { title, value, placeholder, numeric, maxLength, predict }
---@param owner string|nil  the resource asking (its stop closes it)
---@return string|nil
function Keyboard.open(opts, owner)
    opts = type(opts) == 'table' and opts or {}
    closePending(true)
    lastId = lastId + 1
    local k = { id = lastId, owner = owner, p = promise.new() }
    pending = k
    local max = math.tointeger(tonumber(opts.maxLength))
    Focus.take('keyboard', { screen = true })
    SendNUIMessage({
        action = 'padKeyboardOpen', id = k.id,
        title = type(opts.title) == 'string' and opts.title:sub(1, 80) or nil,
        value = opts.value ~= nil and tostring(opts.value) or '',
        placeholder = type(opts.placeholder) == 'string' and opts.placeholder:sub(1, 120) or nil,
        numeric = opts.numeric == true,
        maxLength = (max and max > 0) and math.min(max, 2000) or nil,
        predict = opts.predict ~= false,
    })
    WhipEmit('whip_core:keyboard:opened', { id = k.id, owner = owner })
    return Citizen.Await(k.p)
end

--- Is it up?
---@return boolean
function Keyboard.isOpen()
    return pending ~= nil
end

-- The page's answer: the text (Done), or a cancel.
RegisterNUICallback('padKeyboardDone', function(data, cb)
    cb('ok')
    local k = pending
    if not k or type(data) ~= 'table' or data.id ~= k.id then return end
    pending = nil
    finish(k, (data.cancel ~= true and type(data.text) == 'string') and data.text or nil)
end)

-- The resource that asked stopped: no one is waiting for it. whip_core stopping: client/focus.lua lets go.
AddEventHandler('onClientResourceStop', function(res)
    if pending and pending.owner == res then closePending(true) end
end)

-- Death and Swap Character close it, as they close the pause menu: the screen it typed into goes, and the keyboard
-- must not stay over the death screen or the character select, holding the pad. The asker gets nil.
AddEventHandler('whip_core:player:died', function() closePending(true) end)
AddEventHandler('whip_core:player:logout', function() closePending(true) end)

exports('OpenKeyboard', function(opts)
    local owner = GetInvokingResource()
    return Keyboard.open(opts, owner)
end)

-- ============================================
-- Languages
-- ============================================

--- GTA's language (GetCurrentLanguage) as a pack's code.
local GAME_LANGUAGE = { [0] = 'en', [1] = 'fr', [2] = 'de', [3] = 'it', [4] = 'es', [5] = 'pt', [6] = 'pl', [7] = 'ru',
                        [8] = 'ko', [9] = 'zh', [10] = 'ja', [11] = 'es', [12] = 'zh' }

--- What the setting's list calls a language (a code not here shows as itself, in capitals).
local NAMES = { en = 'English', fr = 'Français', de = 'Deutsch', it = 'Italiano', es = 'Español', pt = 'Português',
                pl = 'Polski', ru = 'Русский', nl = 'Nederlands', sv = 'Svenska', da = 'Dansk', no = 'Norsk',
                fi = 'Suomi', tr = 'Türkçe', cs = 'Čeština', ro = 'Română', hu = 'Magyar', el = 'Ελληνικά',
                uk = 'Українська' }

--- The server's languages (Config.Keyboard.Languages), English when it names none.
local function languages()
    local cfg = type(Config.Keyboard) == 'table' and Config.Keyboard or {}
    local list, seen = {}, {}
    for _, code in ipairs(type(cfg.Languages) == 'table' and cfg.Languages or {}) do
        if type(code) == 'string' and code:match('^%l%l%l?$') and not seen[code] then
            seen[code] = true
            list[#list + 1] = code
        end
    end
    if #list == 0 then list[1] = 'en' end
    return list
end

local function sendLanguages()
    local cfg = type(Config.Keyboard) == 'table' and Config.Keyboard or {}
    SendNUIMessage({
        action = 'padKeyboardLanguages', list = languages(),
        default = type(cfg.Default) == 'string' and cfg.Default or 'en',
        game = GAME_LANGUAGE[GetCurrentLanguage()],
    })
end

-- Once the page is up; again for a page that reloaded (as client/player_prefs.lua sends its values).
CreateThread(function()
    Wait(1000)
    sendLanguages()
end)
RegisterNetEvent('whip_core:client:playerLoaded', sendLanguages)

do
    local options = { { value = 'auto', label = 'Game language' } }
    for _, code in ipairs(languages()) do
        options[#options + 1] = { value = code, label = NAMES[code] or code:upper() }
    end
    PlayerPrefs.define({
        key = 'keyboard.language', group = 'Controller', type = 'choice', label = 'Keyboard language',
        help = 'The language the on-screen keyboard types and suggests words in. Game language: the one GTA is set to, when this server has it.',
        options = options, default = 'auto', page = true,
        visible = function() return #languages() > 1 end,
    })
end

PlayerPrefs.define({
    key = 'keyboard.predict', group = 'Controller', type = 'toggle', label = 'Keyboard word suggestions',
    help = 'Words to finish the one you are typing on the on-screen keyboard (RT takes the first). It learns the words you use, on this PC.',
    default = true, page = true,
})
