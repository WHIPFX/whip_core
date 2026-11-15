-- ============================================
-- ATM — Client
-- Banking as a thing you walk up to
-- ============================================
--
-- THE PROMPT IS THE WHOLE INTERFACE. There is no bank screen any more: you stand at a machine,
-- scroll to an account, scroll to Deposit, type the amount into the badge, and press E. The circle
-- goes green and says "Successful!", or red and says why not.
--
-- THIS FILE WRITES ALMOST NONE OF THAT. The scrolling, the stack, the focus, the key, the typing
-- and the coloured reaction all belong to client/interact.lua; finding the machines and placing the
-- badge on them belong to client/prop_prompts.lua.
-- What is here is the menu's shape and the round trip to the server. The pattern is lifted
-- wholesale from client/garage_spots.lua, which does the same thing for cars — press E on a bay and
-- the prompt becomes the list of what is parked in it.
--
-- THE MENU, AND WHY IT NESTS:
--
--   ROOT      one option, "Check Balance". It cannot list accounts yet, because nobody has asked
--             the server what they are — and asking on approach would be a round trip for every
--             machine you walk past on a high street.
--   ACCOUNTS  press E and the server answers. One option per account the character can touch,
--             showing its balance, plus a Back.
--   ACTIONS   press E on an account: its balance as a read-only line, then Deposit and Withdraw,
--             plus a Back.
--   TYPING    press E on Deposit and the label becomes a field. E again submits.
--
-- Back is an option, not a key (there is no second key in this system). Looking away collapses
-- everything to the root through onBlur, as a garage bay folds up (leaving is the cancel); Back steps
-- up one level without walking off.

-- The tracked machines live in client/prop_prompts.lua: PropPrompts.get(promptId) answers "is this
-- machine still here".

--- [promptId] = 'root' | 'accounts' | 'actions'
local level = {}

--- [promptId] = the account rows last fetched for it. Only held while expanded; the action list
--- reads it to turn a selection back into an accountId.
local accounts = {}

-- ============================================
-- Money, written the way a player reads it
-- ============================================

--- 1250 -> "1,250". Grouping is done by hand rather than with a format string because Lua has no
--- thousands separator and the one-liner that fakes it with gsub is genuinely hard to read.
---@param n number|string
---@return string
local function commas(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local out, count = '', 0
    for i = #s, 1, -1 do
        out = s:sub(i, i) .. out
        count = count + 1
        if count % 3 == 0 and i > 1 then out = ',' .. out end
    end
    return out
end

-- ============================================
-- Collapsing
-- ============================================
--
-- Declared together and before their users because they call each other: the root builder is what
-- collapse reinstates, and the action list's Back goes to the account list.
--
-- THE SERVER CALLS ARE IN THIS LIST TOO, AND THEY HAVE TO BE. They are used inside option callbacks
-- written above where they are defined, and a Lua local binds only to code below it — so without
-- the forward declaration those names would compile as GLOBALS. That is not a style point in a
-- client with one shared Lua state: `submitAmount` as a global is a name any other resource could
-- overwrite, and the same trap client/interact.lua's own activeRendererName fell into.
local rootOptions, accountOptions, actionOptions, goRoot
local requestAccounts, beginAmount, submitAmount

--- Fold a machine all the way back to one option.
---
--- EVERYTHING IS DROPPED, not just the level marker. The account rows are a snapshot of balances
--- that were true when they were fetched; keeping them would mean a machine you walked back to
--- five minutes later opening instantly on figures that had since moved.
---@param promptId string
function goRoot(promptId)
    if level[promptId] == 'root' or not PropPrompts.get(promptId) then return end

    level[promptId]    = 'root'
    accounts[promptId] = nil

    -- setOptions cancels any live input on this prompt, which is what collapses a half-typed
    -- amount when the player looks away. See Interactions.beginInput.
    Interactions.setOptions(promptId, rootOptions(promptId))
end

-- ============================================
-- The three menus
-- ============================================

--- What a machine looks like before anybody has asked it anything.
function rootOptions(promptId)
    return { {
        id    = 'balance',
        icon  = 'bank',
        -- A plain string (the cash on hand is in the inventory already).
        label = 'Check Balance',
        callback = function()
            -- Nothing happens here beyond the ask: the reply swaps the options in when it lands.
            level[promptId] = 'accounts'
            requestAccounts(promptId)
        end,
    } }
end

--- One option per account, plus a Back.
---@param promptId string
---@param rows table
function accountOptions(promptId, rows)
    local out = { {
        id       = 'back',
        icon     = 'back',
        label    = 'Back',
        callback = function() goRoot(promptId) end,
    } }

    for i = 1, #rows do
        local row = rows[i]
        out[#out + 1] = {
            id    = 'acct_' .. tostring(row.accountId),
            icon  = 'bank',
            label = ('%s   $%s'):format(row.label or 'Account', commas(row.balance)),
            callback = function()
                level[promptId] = 'actions'
                Interactions.setOptions(promptId, actionOptions(promptId, row))
            end,
        }
    end

    return out
end

--- Balance, Deposit, Withdraw — for one account.
---
--- DEPOSIT AND WITHDRAW APPEAR ONLY IF THIS CHARACTER MAY DO THEM. A mechanic with deposit-only
--- rights on the business account gets no Withdraw option at all, rather than one that always
--- refuses. The server re-checks both on every call regardless — these flags shape the menu, they
--- do not authorise anything.
---@param promptId string
---@param row table
function actionOptions(promptId, row)
    local out = { {
        id       = 'back',
        icon     = 'back',
        label    = 'Back',
        callback = function()
            level[promptId] = 'accounts'
            Interactions.setOptions(promptId, accountOptions(promptId, accounts[promptId] or {}))
        end,
    }, {
        id    = 'amount',
        icon  = 'bank',
        -- A FUNCTION, not a fixed string, so a deposit updates the figure above it without
        -- rebuilding the menu. `row` is the table the server sent and the reply handler writes the
        -- new balance straight back into it.
        label = function()
            return ('%s   $%s'):format(row.label or 'Account', commas(row.balance))
        end,
        -- NO CALLBACK. Pressing E on the balance does nothing, which is the honest answer for a
        -- line that exists to be read. Same treatment as "Garage is empty".
    } }

    if row.frozen then
        -- A FROZEN ACCOUNT SAYS SO rather than simply having no actions. An account with a Back and
        -- a balance and nothing else looks like a bug; this looks like a bank.
        out[#out + 1] = { id = 'frozen', icon = 'bank', label = 'Account is frozen' }
        return out
    end

    if row.canDeposit then
        out[#out + 1] = {
            id    = 'deposit',
            icon  = 'deposit',
            label = 'Deposit',
            callback = function() beginAmount(promptId, row, 'deposit') end,
        }
    end

    if row.canWithdraw then
        out[#out + 1] = {
            id    = 'withdraw',
            icon  = 'withdraw',
            label = 'Withdraw',
            callback = function() beginAmount(promptId, row, 'withdraw') end,
        }
    end

    return out
end

-- ============================================
-- Typing an amount
-- ============================================

--- Type the amount: the machine's prompt steps aside for the typing (a capsule on a keyboard, the number pad on a
--- pad: client/prompt_typing.lua), titled with what is being done, the amount shown as money.
---
--- NO setOptions CALL HERE: it would cancel the input it starts (setOptions does that deliberately).
---@param promptId string
---@param row table
---@param kind string 'deposit' | 'withdraw'
function beginAmount(promptId, row, kind)
    Interactions.beginInput(promptId, {
        max = Config.AtmMaxDigits or 9,
        title = ('%s · %s'):format(kind == 'deposit' and 'Deposit' or 'Withdraw', row.label or 'Account'),
        prefix = '$', commas = true,

        onSubmit = function(text)
            local amount = tonumber(text)
            if not amount or amount <= 0 then
                -- AN EMPTY FIELD IS NOT AN ERROR WORTH A ROUND TRIP. Giving nothing is someone changing their
                -- mind, so it reads as a quiet cancel rather than a refusal.
                Interactions.setStatus(promptId, 'Cancelled', 1200)
                return
            end

            submitAmount(promptId, row, kind, math.floor(amount))
        end,
    })
end

-- ============================================
-- The server
-- ============================================

--- Ask what accounts this character has, and swap them in when the answer lands.
---
--- Callback() YIELDS, so this runs in its own thread rather than inside the option callback that
--- wanted it — an interaction callback that waits is a frame the game spends not drawing.
---@param promptId string
function requestAccounts(promptId)
    CreateThread(function()
        -- The server also returns the player's cash as a second value, not read here.
        local rows = Callback('whip_core:atm:accounts')

        -- The player may have walked away, looked at the machine next to it, or collapsed the menu
        -- while that was in flight. Swapping a list into a prompt they have left would leave it
        -- expanded with nobody looking at it — the same check garage_spots.lua makes on its own
        -- list, and for the same reason.
        if level[promptId] ~= 'accounts' or not PropPrompts.get(promptId) then return end

        rows = rows or {}
        accounts[promptId] = rows

        if #rows == 0 then
            -- NOT SILENCE AND NOT AN EMPTY LIST. A prompt that does nothing when pressed reads as
            -- broken; one that says there are no accounts has answered the question.
            Interactions.setOptions(promptId, { {
                id       = 'back',
                icon     = 'back',
                label    = 'No accounts',
                callback = function() goRoot(promptId) end,
            } })
            return
        end

        Interactions.setOptions(promptId, accountOptions(promptId, rows))
    end)
end

--- Move the money, and say what happened on the badge.
---@param promptId string
---@param row table
---@param kind string 'deposit' | 'withdraw'
---@param amount number
function submitAmount(promptId, row, kind, amount)
    CreateThread(function()
        -- Fourth return is the player's cash, deliberately unread — see the note in requestAccounts.
        local ok, err, newBalance = Callback('whip_core:atm:' .. kind, row.accountId, amount)

        -- Gone while the server was thinking. Nothing to say it to, and nothing that needs undoing
        -- — the money moved or it did not, and the account list is rebuilt from scratch next time.
        if not PropPrompts.get(promptId) then return end

        if ok then
            -- The row is the SAME TABLE the balance label closes over, so writing the new figure
            -- into it updates the line above without rebuilding the menu.
            if newBalance then row.balance = newBalance end

            Interactions.flash(promptId, 60, 220, 90)
            Interactions.setStatus(promptId, 'Successful!', 2000)
        else
            Interactions.flash(promptId, 230, 70, 70)
            -- THE SERVER'S OWN WORDS. "Insufficient funds", "Not enough cash — you have $340",
            -- "Account is frozen" — each of those is a different thing to do next, and a red circle
            -- alone says only that something went wrong, which the player had worked out.
            --
            -- nil is possible: a refused callback is dropped rather than answered (see
            -- server/callback.lua) and the client's own timeout resolves it to nothing. Spamming E
            -- is what produces that, so it gets a message of its own rather than a blank badge.
            Interactions.setStatus(promptId, err or 'No answer from the bank', 2500)
        end
    end)
end

-- Finding machines and placing the badge are client/prop_prompts.lua's. On stop, PropPrompts removes
-- every machine, and each removal comes back through onRemove below.

-- ============================================
-- The machines
-- ============================================
--
-- AT THE BOTTOM OF THE FILE, below every local the functions close over — see PropPrompts.define.

PropPrompts.define({
    kind          = 'atm',
    faces         = 1,
    modelsKey     = 'AtmProps',
    offsetKey     = 'AtmBadgeOffset',
    defaultOffset = { side = 0.0, out = 0.4, up = 0.3, yaw = 0.0 },
    searchRange   = function() return Config.AtmSearchRange or 30.0 end,
    visibleRange  = function() return Config.AtmVisibleRange or 3.0 end,
    activeRange   = function() return Config.AtmActiveRange or 1.4 end,

    --- A machine was found: start it at the root of the menu.
    ---
    --- THE LEVEL IS SET BEFORE THE OPTIONS ARE HANDED BACK, because goRoot returns early for a
    --- machine that is already at the root — a machine with no level at all would never be folded
    --- back by it.
    prompt = function(rec)
        level[rec.id] = 'root'
        return {
            options = rootOptions(rec.id),

            -- Look away and it folds all the way back, cancelling anything half-typed with it. No
            -- cancel key, because leaving is the cancel.
            onBlur = function() goRoot(rec.id) end,

            -- The hand towards the screen after each press and each amount entered (Josh, 2 Nov: the engine does it,
            -- client/interact.lua; only how it looks).
            press = true,
        }
    end,

    --- A machine went out of range, or the resource is stopping: forget its menu with it.
    onRemove = function(rec)
        level[rec.id]    = nil
        accounts[rec.id] = nil
    end,
})

-- Switching character must not leave the previous one's account snapshot behind: the balances and
-- the permissions belong to a charId that is no longer the player.
RegisterNetEvent('whip_core:client:playerLoaded', function()
    PropPrompts.each('atm', function(rec) goRoot(rec.id) end)
end)

-- An ATM setting changed in /whip → Settings: the machines are found again with it.
for _, path in ipairs({ 'AtmProps', 'AtmVisibleRange', 'AtmActiveRange' }) do
    Settings.onChange(path, function() PropPrompts.refresh('atm') end)
end
Settings.onChange('AtmBadgeOffset', function() PropPrompts.reposition('atm') end)
