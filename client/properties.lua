-- ============================================
-- PROPERTIES — Client
-- ============================================
--
-- What a property is from here: its SIGNS, and a SPACE you can be inside. The lock is the door's
-- business — the property manages its doors on the server and the door system enforces them — so
-- nothing in this file decides who gets in.
--
-- Two signs, one at a time:
--
--   OUTSIDE   while nobody owns it: its name, its garage bays, its rooms (when known) and its
--             price. The price turns into "Purchase?", which asks how to pay (cash, or an account
--             the buyer can pay from), and the server sells it or says why not.
--   MANAGER   once it is somebody's. INSIDE, and shown only to the people who live there (the
--             owner and keyholders) and to admins: everything they would want to do with the
--             place — keys, furniture, and what else a home comes to have.
--
-- An owned property with no manager placed yet uses its outside sign's spot for the manager, so
-- its owner is never left without one, but not Furnish there: furnishing is from inside (a placed
-- manager, or /furnish).
--
-- Near properties only. Every property arrives at login (propertiesSync), but only the ones within
-- Config.PropertyStreamRange get their sign and are tested for "am I inside", through one
-- StreamProps stream over the properties themselves.
--
-- "Am I inside" is containment, not a zone. The space is tested with shared/shapes.lua every half
-- second against the near properties, and entering or leaving one fires
-- whip_core:property:entered / :exited.

local props       = {}   -- [id] = wire record, plus x/y/z (its anchor) and _shapes (prepared)
local near        = {}   -- [id] = true while streamed in
local signs       = {}   -- [id] = { outside = interaction id, manager = interaction id }
local posts       = {}   -- [id] = { key, entity? }: the outside sign's post while it is up (The sign post, below)
local keyMenuOpen = {}   -- [id] = true while the manager shows the key menu
local themeMenu   = {}   -- [id] = { current, applying } while the manager shows the theme menu
local buyMenuOpen = {}   -- [id] = a table of its own while the outside sign shows how to pay
local askBuy      = {}   -- [id] = true while the outside sign's price says "Purchase?"
local myKeys      = {}   -- [id] = true for each property this character holds a key to
local current     = nil  -- the id of the property the player is standing in

--- May this player see every manager sign (an admin with developer mode on)? Read from what the client
--- already knows (DevToolsOn, tools/core.lua), never asked here: the sign's conditions run every frame.
--- It only decides what is DRAWN; everything behind a sign is checked again by the server.
local function devAllowed()
    return DevToolsOn ~= nil and DevToolsOn()
end

--- Forward-declared: the key and buy menus and the signs call each other, and a local binds only to
--- code below it.
local openKeyMenu, closeKeyMenu, openBuyMenu, closeBuyMenu, addSigns, removeSigns

local function myCharId()
    return PlayerData and PlayerData.charId or nil
end

local function isMine(p)
    local me = myCharId()
    return me ~= nil and p ~= nil and p.ownerCharId == me
end

--- Does this player live here — its owner, or holding a key?
local function livesHere(p)
    return p ~= nil and (isMine(p) or myKeys[p.id] == true)
end

--- 250000 → "250,000".
local function money(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local out = s:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    return (out:gsub('^,', ''))
end

-- ============================================
-- The key menu (on the manager)
-- ============================================
--
-- The sign becomes the menu, as an ATM's or a garage bay's does: Keys replaces the options with who
-- can get in and who is standing here to be let in. It asks the server every time it opens — who
-- is nearby changes by the second — and the server checks the distance again when a key is given.

function closeKeyMenu(id)
    if not keyMenuOpen[id] then return end
    keyMenuOpen[id] = nil
    removeSigns(id)
    if near[id] and props[id] then addSigns(props[id]) end
end

function openKeyMenu(id)
    local signId = signs[id] and signs[id].manager
    if not signId or not Interactions then return end
    keyMenuOpen[id] = true

    Interactions.setOptions(signId, { { id = 'wait', icon = 'lock', label = 'Checking…' } })

    CreateThread(function()
        local info, why = Callback('whip_core:property:keyInfo', id)
        if not keyMenuOpen[id] or not (signs[id] and signs[id].manager) then return end

        if type(info) ~= 'table' then
            Interactions.setOptions(signId, { {
                id = 'back', icon = 'back', label = type(why) == 'string' and why or 'Could not read the keys',
                callback = function() closeKeyMenu(id) end,
            } })
            return
        end

        local opts = { { id = 'back', icon = 'back', label = 'Back', callback = function() closeKeyMenu(id) end } }
        for _, n in ipairs(info.nearby or {}) do
            opts[#opts + 1] = {
                id = 'give_' .. tostring(n.serverId), icon = 'unlock',
                label = ('Give a key to %s'):format(n.name or 'them'),
                callback = function()
                    TriggerServerEvent('whip_core:server:propertyKeyGrant', id, n.serverId)
                    closeKeyMenu(id)
                end,
            }
        end
        for _, k in ipairs(info.holders or {}) do
            opts[#opts + 1] = {
                id = 'take_' .. tostring(k.charId), icon = 'lock',
                label = ('Take %s\'s key back'):format(k.name or 'their'),
                callback = function()
                    TriggerServerEvent('whip_core:server:propertyKeyRevoke', id, k.charId)
                    closeKeyMenu(id)
                end,
            }
        end
        if #opts == 1 then
            opts[2] = { id = 'none', icon = 'lock', label = 'Nobody has a key, and nobody is nearby' }
        end
        Interactions.setOptions(signId, opts)
    end)
end

-- ============================================
-- The buy menu (on the outside sign)
-- ============================================
--
-- "Purchase?" turns the sign into how to pay, as Keys does on the manager: cash (what is on them), and
-- each account they can pay from, with its balance. Picking one buys it; the server checks it all again
-- and says how it went. Sold, the property comes back owned and the sign becomes its manager.
--
-- On a sign post the one control under the listing is "Purchase?" itself, and it goes straight to how to pay.

function closeBuyMenu(id)
    askBuy[id] = nil   -- back to the price, too
    if not buyMenuOpen[id] then return end
    buyMenuOpen[id] = nil
    removeSigns(id)
    if near[id] and props[id] then addSigns(props[id]) end
end

local function buy(id, method, accountId)
    local signId = signs[id] and signs[id].outside
    if not signId or not buyMenuOpen[id] then return end
    Interactions.setOptions(signId, { { id = 'wait', icon = 'cash', label = 'Buying…' } })
    CreateThread(function()
        Callback('whip_core:property:purchase', id, method, accountId or 0)
        closeBuyMenu(id)   -- sold: the property's update has the manager up; refused: the sign as it was
    end)
end

function openBuyMenu(id)
    local signId = signs[id] and signs[id].outside
    if not signId or not Interactions then return end
    local open = {}
    buyMenuOpen[id] = open
    -- On a sign post the listing stays on the board, with how to pay under it.
    local onPost = posts[id] ~= nil

    Interactions.setOptions(signId, { { id = 'wait', icon = 'cash', label = 'Checking…' } })

    CreateThread(function()
        local info, why = Callback('whip_core:property:payOptions', id)
        if buyMenuOpen[id] ~= open or not (signs[id] and signs[id].outside) then return end

        local back = { id = 'back', icon = 'back', label = 'Back', callback = function() closeBuyMenu(id) end }
        if type(info) ~= 'table' then
            Interactions.setOptions(signId, { back, {
                id = 'why', icon = 'house', label = type(why) == 'string' and why or 'Could not reach the seller',
            } })
            return
        end

        local cash = {
            id = 'cash', icon = 'cash', label = ('Cash  ($%s)'):format(money(info.cash)),
            callback = function() buy(id, 'cash') end,
        }
        local accounts = {}
        for _, a in ipairs(info.accounts or {}) do
            accounts[#accounts + 1] = {
                id = 'bank_' .. tostring(a.accountId), icon = 'bank',
                label = ('%s  ($%s)'):format(a.label or 'Account', money(a.balance)),
                callback = function() buy(id, 'bank', a.accountId) end,
            }
        end

        local opts
        if onPost then
            -- Down the rows under the listing (PropertyListing.rowFor): Cash first and selected, then the accounts,
            -- then Back last.
            opts = { cash }
            for _, a in ipairs(accounts) do opts[#opts + 1] = a end
            opts[#opts + 1] = back
        else
            opts = { back, cash }
            for _, a in ipairs(accounts) do opts[#opts + 1] = a end
        end
        Interactions.setOptions(signId, opts)
    end)
end

-- ============================================
-- The theme menu (on the manager)
-- ============================================
--
-- Theme turns the sign into the home's looks, as Keys does: Back, then each theme. Each one's circle is a
-- swatch, not an icon: its walls over its floor with the trim between (html/interact3d/badge.html,
-- `swatch_`). Picking one asks the server (server/property_themes.lua), which redraws the home. The menu
-- stays up so the next can be tried, and marks the one in force when the server answers. The labels read
-- that live, so the selection never moves.

--- A theme's swatch, as the badge atlas names it: swatch_<walls>_<trim>_<floor>, six hex digits each.
local function swatchKey(t)
    local function hex(c)
        local s = type(c) == 'string' and c:match('^#?(%x%x%x%x%x%x)$')
        return s and s:lower() or nil
    end
    local walls = hex(t.walls)
    if not walls then return 'theme' end
    return ('swatch_%s_%s_%s'):format(walls, hex(t.trim) or walls, hex(t.floor) or walls)
end

local function closeThemeMenu(id)
    if not themeMenu[id] then return end
    themeMenu[id] = nil
    removeSigns(id)
    if near[id] and props[id] then addSigns(props[id]) end
end

local function openThemeMenu(id)
    local signId = signs[id] and signs[id].manager
    if not signId or not Interactions then return end
    local m = { current = nil, applying = nil }
    themeMenu[id] = m

    Interactions.setOptions(signId, { { id = 'wait', icon = 'theme', label = 'Checking…' } })

    CreateThread(function()
        local info, why = Callback('whip_core:property:themes', id)
        if themeMenu[id] ~= m or not (signs[id] and signs[id].manager) then return end

        if type(info) ~= 'table' or type(info.themes) ~= 'table' then
            Interactions.setOptions(signId, { {
                id = 'back', icon = 'back', label = type(why) == 'string' and why or 'Could not read its themes',
                callback = function() closeThemeMenu(id) end,
            } })
            return
        end

        m.current = math.tointeger(tonumber(info.current))
        local opts = { { id = 'back', icon = 'back', label = 'Back', callback = function() closeThemeMenu(id) end } }
        for _, t in ipairs(info.themes) do
            local themeId, name = math.tointeger(tonumber(t.id)), tostring(t.name or 'Theme')
            if themeId then
                opts[#opts + 1] = {
                    id = 'theme_' .. themeId, icon = swatchKey(t),
                    label = function()
                        if m.applying == themeId then return name .. '  (applying…)' end
                        if m.current == themeId then return name .. '  (in use)' end
                        return name
                    end,
                    callback = function()
                        if m.applying or m.current == themeId then return end
                        m.applying = themeId
                        TriggerServerEvent('whip_core:server:propertySetTheme', id, themeId)
                        -- No answer (a refusal for going too fast is silent): the next pick is open again.
                        SetTimeout(4000, function() if m.applying == themeId then m.applying = nil end end)
                    end,
                }
            end
        end
        Interactions.setOptions(signId, opts)
        -- On the one in force, as the menu opens.
        if m.current then Interactions.setSelection(signId, 'theme_' .. m.current) end
    end)
end

-- The server's answer to a pick.
RegisterNetEvent('whip_core:client:propertyThemeSet', function(propertyId, ok, themeId)
    local m = themeMenu[tonumber(propertyId)]
    if not m then return end
    m.applying = nil
    if ok then m.current = math.tointeger(tonumber(themeId)) end
end)

-- ============================================
-- The sign post
-- ============================================
--
-- The outside sign on a post (Config.PropertySignPosts, shared/property_math.lua's Sign posts).
-- A prop of this player's own, not networked: up while the property is for sale and near, down once somebody owns
-- it, as the outside sign's prompt is. It is kept apart from the prompts, which the buy and key menus take down and
-- put back, so it does not blink with them. Held whole: frozen, and its board cannot be knocked off.

local POST_LOAD_MS = 5000   -- how long its model may take to load before it is left out
local ROW_RATE     = 10.0   -- how fast its control glides between rows: the option stack's own slide (Config.Interact3D.fadeMs)

local function removePost(id)
    local s = posts[id]
    if not s then return end
    posts[id] = nil
    if s.entity and DoesEntityExist(s.entity) then DeleteEntity(s.entity) end
    PropertyListing.remove(id)
end

--- Its listing, printed on the post's board (client/property_listing.lua). Once the post stands.
local function refreshListing(id)
    local s, p = posts[id], props[id]
    if not (s and s.entity and p) then return end
    PropertyListing.set(id, s.entity, s.post, s.sign, {
        name = p.name, bays = p.bays, rooms = p.rooms, price = p.price, closed = p.active == false,
    })
end

--- Up for a property for sale whose outside sign names a post this server lists; down otherwise. A post already
--- standing in the same place is left alone.
local function syncPost(p)
    local sign = type(p.sign) == 'table' and p.sign.x and p.sign or nil
    local post = sign and not p.ownerCharId and PropertyMath.signPost(sign.post) or nil
    if not (sign and post) then removePost(p.id) return end
    local x, y, z, h = PropertyMath.promptToPost(post, sign.x, sign.y, sign.z, sign.heading or 0.0)
    local key = ('%s|%.3f|%.3f|%.3f|%.1f'):format(post.model, x, y, z, h)
    if posts[p.id] and posts[p.id].key == key then
        -- Standing already: its listing may still have changed (a new price, a rename).
        refreshListing(p.id)
        return
    end
    removePost(p.id)
    local mine = { key = key, post = post, sign = sign }
    posts[p.id] = mine
    CreateThread(function()
        local model = GetHashKey(post.model)
        if not IsModelInCdimage(model) then
            print(('[whip_core:properties] sign post %s is not in the game (is it streamed?)'):format(post.model))
            return
        end
        LoadModel(model, POST_LOAD_MS)   -- whip's loader, not a hand-written loop (audit 20, ARC-1)
        -- Taken down, or moved, while it loaded.
        if posts[p.id] ~= mine or not HasModelLoaded(model) then return end
        local e = CreateObjectNoOffset(model, x, y, z, false, false, false)
        SetModelAsNoLongerNeeded(model)
        if not e or e == 0 then return end
        SetEntityHeading(e, h)
        FreezeEntityPosition(e, true)
        SetEntityInvincible(e, true)
        SetDisableBreaking(e, true)
        SetDisableFragDamage(e, true)
        mine.entity = e
        refreshListing(p.id)
    end)
end

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for id in pairs(posts) do removePost(id) end
end)

-- ============================================
-- The signs
-- ============================================

function removeSigns(id)
    local s = signs[id]
    if not s then return end
    if Interactions then
        if s.outside then Interactions.remove(s.outside) end
        if s.manager then Interactions.remove(s.manager) end
    end
    signs[id] = nil
end

--- One prompt, as a sign on a wall: it stands at its heading, readable from the front and edge-on
--- from the side, rather than turning to face whoever walks past.
---
--- `extra`: more of Interactions.register's fields, over these (a sign post's control: its `follow` and `pull`).
local function registerSign(promptId, spot, options, condition, onBlur, extra)
    local data = {
        id = promptId,
        x = spot.x, y = spot.y, z = spot.z,
        heading = spot.heading or 0.0,
        group = 'properties',
        focusMode = 'near',
        onBlur = onBlur,
        options = options,
        condition = condition,
    }
    for k, v in pairs(extra or {}) do data[k] = v end
    Interactions.register(data)
end

function addSigns(p)
    syncPost(p)
    if signs[p.id] or not Interactions then return end
    local s = {}

    if not p.ownerCharId then
        -- ---- OUTSIDE: for sale ----
        -- No Furnish here, for anyone: an admin dressing a home before it is sold does it from inside,
        -- with /furnish.
        if type(p.sign) == 'table' and p.sign.x then
            s.outside = ('property_%d_outside'):format(p.id)
            local function price() return math.floor(tonumber((props[p.id] or p).price) or 0) end
            local function forSale()
                local cur = props[p.id]
                return cur ~= nil and cur.active ~= false and price() > 0
            end
            -- A post the game has (one not streamed is left out: syncPost), or the list below with no board under it.
            local post = posts[p.id] and posts[p.id].post
            if post and IsModelInCdimage(GetHashKey(post.model)) then
                -- On a sign post: the listing is printed on its board (client/property_listing.lua)
                -- and this is its one control, at the board's bottom left: "Purchase?", which turns into how to
                -- pay there, under the listing. Flat on the board: not pulled toward the camera. Which row it is on
                -- lives on the post's record, which outlasts this prompt: closing the menu takes the prompt down and
                -- puts it back, and it still glides down.
                local sign = p.sign
                local standing = posts[p.id]
                standing.fit = standing.fit or {}
                local x, y, z, h = PropertyListing.controls(post, sign, standing.row)
                registerSign(s.outside, { x = x, y = y, z = z, heading = h }, {
                    { id = 'purchase', icon = 'dollar', label = 'Purchase?', condition = forSale,
                      callback = function() openBuyMenu(p.id) end },
                }, function() return props[p.id] ~= nil end,
                -- How to pay folds back to "Purchase?" when you look away.
                function() closeBuyMenu(p.id) end, {
                    pull = 0.0,
                    scale = PropertyListing.CONTROL_SCALE,   -- the board's size, not arm's length
                    follow = function()
                        -- "Purchase?" on the bottom row; in a list, the selected option's own row. A line that is
                        -- the only one ("Checking…") holds the row it is on.
                        if not buyMenuOpen[p.id] then
                            standing.rowTo = 0.0
                        else
                            local index, _, count = Interactions.getSelection(s.outside)
                            if index and count > 1 then standing.rowTo = PropertyListing.rowFor(index, count --[[@as integer]]) end
                        end
                        local row = standing.row or 0.0
                        row = row + ((standing.rowTo or 0.0) - row) * math.min(1.0, GetFrameTime() * ROW_RATE)
                        standing.row = row
                        local fx, fy, fz, fh = PropertyListing.controls(post, sign, row, standing.fit)
                        return fx, fy, fz, fh, 0.0, nil, nil, nil, standing.fit
                    end,
                })
                signs[p.id] = s
                return
            end

            local function count(field) return math.floor(tonumber((props[p.id] or p)[field]) or 0) end
            -- The listing, one line each: its name, its garage bays, its rooms (when known),
            -- its price. Only the price does anything.
            registerSign(s.outside, p.sign, {
                {
                    id = 'info', icon = 'house',
                    label = function()
                        local cur = props[p.id] or p
                        local name = cur.name or 'Property'
                        if cur.active == false then return name .. '  (closed)' end
                        return name
                    end,
                },
                {
                    id = 'bays', icon = 'garage',
                    label = function()
                        local n = count('bays')
                        if n <= 0 then return 'No garage' end
                        return ('%d garage bay%s'):format(n, n == 1 and '' or 's')
                    end,
                },
                {
                    id = 'rooms', icon = 'house_door',
                    -- Known when its space is the interior's rooms and they have been read (server/properties.lua,
                    -- roomCount); left out otherwise.
                    condition = function() return count('rooms') > 0 end,
                    label = function()
                        local n = count('rooms')
                        return ('%d room%s'):format(n, n == 1 and '' or 's')
                    end,
                },
                {
                    id = 'price', icon = 'dollar',
                    -- Priced and open: a property with no price is not for sale.
                    condition = forSale,
                    -- E on the price asks "Purchase?"; E again opens how to pay. Scrolled off it, it is the price
                    -- again: read here, where the label is asked for while the sign is in front of you.
                    label = function()
                        if askBuy[p.id] then
                            local _, sel = Interactions.getSelection(s.outside)
                            if sel == 'price' then return 'Purchase?' end
                            askBuy[p.id] = nil
                        end
                        return ('$%s'):format(money(price()))
                    end,
                    callback = function()
                        if askBuy[p.id] then openBuyMenu(p.id) else askBuy[p.id] = true end
                    end,
                },
            }, function() return props[p.id] ~= nil end,
            -- How to pay, or "Purchase?", folds back to the sign when you look away.
            function() closeBuyMenu(p.id) end)
        end
    else
        -- ---- MANAGER: for the people who live there ----
        local placed = type(p.manager) == 'table' and p.manager.x ~= nil
        local spot = placed and p.manager or ((type(p.sign) == 'table' and p.sign.x) and p.sign) or nil
        if spot then
            s.manager = ('property_%d_manager'):format(p.id)
            registerSign(s.manager, spot, {
                {
                    id = 'info', icon = 'house',
                    label = function()
                        local cur = props[p.id] or p
                        local name = cur.name or 'Property'
                        if cur.active == false then return name .. '  (closed)' end
                        if isMine(cur) then return name .. '  (yours)' end
                        if myKeys[p.id] then return name .. '  (you have a key)' end
                        return name
                    end,
                },
                {
                    id = 'furnish', icon = 'furnish', label = 'Furnish',
                    -- Offered only where it would work, and never at the outside sign's spot (a manager not
                    -- placed yet stands there): the furnisher answers, the server checks on save.
                    condition = function() return placed and CanFurnishProperty ~= nil and CanFurnishProperty(p.id) end,
                    callback = function() if OpenFurnisher then OpenFurnisher(p.id) end end,
                },
                {
                    id = 'theme', icon = 'theme', label = 'Theme',
                    -- Its looks, when its interior's resource has some (server/property_themes.lua), for
                    -- whoever may furnish it, from the same spot: the sign becomes the list (the theme menu).
                    condition = function()
                        local cur = props[p.id]
                        return placed and cur ~= nil and cur.themes == true
                            and CanFurnishProperty ~= nil and CanFurnishProperty(p.id)
                    end,
                    callback = function() openThemeMenu(p.id) end,
                },
                {
                    id = 'keys', icon = 'lock', label = 'Keys',
                    -- The owner's, and only theirs: a key opens the door, it does not mint more keys.
                    condition = function() return isMine(props[p.id]) end,
                    callback = function() openKeyMenu(p.id) end,
                },
            },
            -- Only those who live here see it, and admins; a guest standing in the lounge does not.
            function()
                local cur = props[p.id]
                return cur ~= nil and (livesHere(cur) or devAllowed())
            end,
            -- The key and theme menus fold back to the first page when you look away.
            function() closeKeyMenu(p.id); closeThemeMenu(p.id) end)
        end
    end

    signs[p.id] = s
end

-- ============================================
-- Streaming
-- ============================================

StreamProps.addStream({
    name      = 'properties',
    -- A getter: propertiesSync rebinds `props` wholesale.
    defs      = function() return props end,
    -- Measured from the property's anchor (the centre of the sphere holding it), plus the sphere's
    -- radius — each def's `reach` (see adopt).
    range     = function() return Config.PropertyStreamRange or 60.0 end,
    isSpawned = function(id) return near[id] == true end,
    spawn     = function(p)
        near[p.id] = true
        addSigns(p)
        if PropertyStreamedIn then PropertyStreamedIn(p.id) end
    end,
    despawn   = function(id)
        near[id] = nil
        keyMenuOpen[id] = nil
        buyMenuOpen[id] = nil
        askBuy[id] = nil
        removeSigns(id)
        removePost(id)
        if PropertyStreamedOut then PropertyStreamedOut(id) end
    end,
})

-- ============================================
-- Am I inside one?
-- ============================================

local function setCurrent(id)
    if id == current then return end
    local left = current and props[current]
    current = id
    if left then
        WhipEmit('whip_core:property:exited', { propertyId = left.id, name = left.name })
    end
    local entered = id and props[id]
    if entered then
        WhipEmit('whip_core:property:entered', { propertyId = entered.id, name = entered.name })
    end
end

CreateThread(function()
    while true do
        if next(near) == nil then
            if current then setCurrent(nil) end
            Wait(1000)
        else
            local pos = GetEntityCoords(PlayerPedId())
            local found = nil
            -- The one you are already in first, so two properties touching at a wall do not
            -- flicker between each other on the line.
            local cur = current and near[current] and props[current]
            if cur and Shapes.containsAny(cur._shapes, pos.x, pos.y, pos.z) then
                found = current
            else
                for id in pairs(near) do
                    local p = props[id]
                    if p and Shapes.containsAny(p._shapes, pos.x, pos.y, pos.z) then
                        found = id
                        break
                    end
                end
            end
            setCurrent(found)
            Wait(500)
        end
    end
end)

-- ============================================
-- Server sync
-- ============================================

--- A wire record made usable here: its anchor as x/y/z for the stream, its shapes prepared.
local function adopt(w)
    local a = w.anchor or w.place or { x = 0.0, y = 0.0, z = 0.0 }
    w.x, w.y, w.z = a.x, a.y, a.z
    -- The anchor's radius rides along as the stream's reach, so a property bigger than the stream
    -- range stays in while you stand anywhere in it (the server's own near check adds it too).
    w.reach = tonumber(a.r) or 0
    w._shapes = {}
    for _, s in ipairs(w.shapes or {}) do
        local p = Shapes.prepare(s)
        if p then w._shapes[#w._shapes + 1] = p end
    end
    props[w.id] = w
end

local function forget(id)
    if current == id then setCurrent(nil) end
    near[id] = nil
    keyMenuOpen[id] = nil
    buyMenuOpen[id] = nil
    askBuy[id] = nil
    removeSigns(id)
    removePost(id)
    if PropertyStreamedOut then PropertyStreamedOut(id) end
end

RegisterNetEvent('whip_core:client:propertiesSync', function(list)
    for id in pairs(props) do forget(id) end
    props = {}
    for _, w in ipairs(type(list) == 'table' and list or {}) do
        if w and w.id then adopt(w) end
    end
    -- The stream's next pass (500 ms at most) puts back whatever is near.
end)

--- Is a property still in the same place with the same shapes? Compared as JSON: a false "moved"
--- only costs the full rebuild below.
---@return boolean
local function samePlacement(a, b)
    local function j(v) return json.encode(v or false) end
    return a ~= nil and b ~= nil and j(a.place) == j(b.place) and j(a.anchor) == j(b.anchor)
        and j(a.shapes) == j(b.shapes)
end

RegisterNetEvent('whip_core:client:propertyUpdated', function(w)
    if type(w) ~= 'table' or not w.id then return end

    -- Not moved: the record and the signs, nothing else. A full take-down would fire
    -- whip_core:property:exited and :entered at a player who never moved, and blink the furniture.
    local old = props[w.id]
    if near[w.id] and samePlacement(old, w) then
        adopt(w)
        removeSigns(w.id)
        addSigns(props[w.id])
        return
    end

    -- Moved, or not near: taken down and let the stream put it back, so a moved sign is rebuilt
    -- from the new record rather than patched.
    local wasCurrent = current == w.id
    forget(w.id)
    adopt(w)
    if wasCurrent then current = nil end
end)

RegisterNetEvent('whip_core:client:propertyDeleted', function(id)
    id = tonumber(id)
    if not id then return end
    forget(id)
    props[id] = nil
end)

--- Which properties this character holds a key to: at login, and whenever one comes or goes. Any
--- that are near have their signs rebuilt, since a key is what shows a keyholder the manager.
RegisterNetEvent('whip_core:client:propertyKeysMine', function(ids)
    local fresh = {}
    for _, id in ipairs(type(ids) == 'table' and ids or {}) do fresh[tonumber(id) or id] = true end
    local changed = {}
    for id in pairs(myKeys) do if not fresh[id] then changed[id] = true end end
    for id in pairs(fresh) do if not myKeys[id] then changed[id] = true end end
    myKeys = fresh
    for id in pairs(changed) do
        if near[id] and props[id] then
            removeSigns(id)
            addSigns(props[id])
        end
    end
end)

-- ============================================
-- Reads
-- ============================================

--- Every property this client knows, keyed by id. The client holds them all; the admin panel and
--- the furnisher read this rather than asking the server again.
function GetPropertyDefs() return props end

--- The property the player is standing in, or nil.
---@return table|nil
function GetCurrentProperty()
    return current and props[current] or nil
end

--- Is this property streamed in right now?
function IsPropertyNear(id) return near[tonumber(id) or -1] == true end

--- Is the player within `metres` of this property's SPACE (its walls, not its anchor; standing in it
--- counts, and so does above or below it)? For what should only be there close up: its furniture
--- (client/property_objects.lua, Config.PropertyFurnitureDistance).
---@param id number
---@param metres number|nil  0: inside only
---@return boolean
function IsNearPropertySpace(id, metres)
    local p = props[tonumber(id) or -1]
    if not p or not near[p.id] or not p._shapes or #p._shapes == 0 then return false end
    local pos = GetEntityCoords(PlayerPedId())
    return (Shapes.containsAny(p._shapes, pos.x, pos.y, pos.z, math.max(0.0, tonumber(metres) or 0.0)))
end

--- Does this character hold a key to it?
function HasPropertyKey(id) return myKeys[tonumber(id) or -1] == true end

--- Does this character live there: its owner, or holding a key? (A property's stash prompt shows only
--- to them, client/containers.lua; the server decides who may open it.)
function LivesInProperty(id) return livesHere(props[tonumber(id) or -1]) end

exports('GetCurrentProperty', function()
    local p = GetCurrentProperty()
    if not p then return nil end
    return { id = p.id, name = p.name, label = p.label, building = p.building,
             ownerCharId = p.ownerCharId, mine = isMine(p), key = myKeys[p.id] == true }
end)
