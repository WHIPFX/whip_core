-- ============================================
-- PED OUTFIT — what a GTA ped wears, part by part
-- ============================================
--
-- A ped model has its own clothes: each of its parts (head, hair, upper body, legs, feet...) comes in a few styles,
-- each style in a few colours, and on top it may wear props (a hat, glasses, a watch). Which ones it has differs from
-- one model to the next, so they are read off a ped of that model (PedOutfit.options) and an outfit only names those.
--
-- AN OUTFIT is a flat table, as the Director keeps it on an NPC (its page: Outfit; def.outfit) and the server sends it
-- in the NPC's brain (server/npcs.lua): c<part>d / c<part>t a part's style and colour, p<prop>d / p<prop>t a prop's
-- (p<prop>d = -1: none). A part it does not name is as the game made the ped.
--
-- Only the game that owns a networked ped can dress it (the others see what that game sends): client/npcs.lua puts a
-- run's NPC's outfit on as the brain arrives, and the world builder its copy (client/furnish_builder.lua dressNpc).

PedOutfit = {}

local PARTS = 11      -- components 0-11
local PROPS = { 0, 1, 2, 6, 7 }   -- hat, glasses, ears, watch, bracelet
local PROP_OK = { [0] = true, [1] = true, [2] = true, [6] = true, [7] = true }
local MAX_INDEX = 999

--- An outfit as the game puts it on: { c = { { i, d, t } }, p = { { i, d, t } } }, from its flat table; nil for none.
--- What is not a part or a prop it knows, or not a whole number in range, is left out.
---@param flat table|nil
---@return table|nil
function PedOutfit.read(flat)
    if type(flat) ~= 'table' then return nil end
    local c, p = {}, {}
    for i = 0, PARTS do
        local d, t = math.tointeger(tonumber(flat['c' .. i .. 'd'])), math.tointeger(tonumber(flat['c' .. i .. 't']))
        if d and d >= 0 and d <= MAX_INDEX then
            c[#c + 1] = { i = i, d = d, t = (t and t >= 0 and t <= MAX_INDEX) and t or 0 }
        end
    end
    for _, i in ipairs(PROPS) do
        local d, t = math.tointeger(tonumber(flat['p' .. i .. 'd'])), math.tointeger(tonumber(flat['p' .. i .. 't']))
        if d and d >= -1 and d <= MAX_INDEX then
            p[#p + 1] = { i = i, d = d, t = (t and t >= 0 and t <= MAX_INDEX) and t or 0 }
        end
    end
    if #c == 0 and #p == 0 then return nil end
    return { c = c, p = p }
end

--- The flat table with only what PedOutfit.read takes (what the world builder's copy is sent): nil for none.
---@param flat table|nil
---@return table|nil
function PedOutfit.clean(flat)
    local o = PedOutfit.read(flat)
    if not o then return nil end
    local out = {}
    for _, x in ipairs(o.c) do out['c' .. x.i .. 'd'], out['c' .. x.i .. 't'] = x.d, x.t end
    for _, x in ipairs(o.p) do out['p' .. x.i .. 'd'], out['p' .. x.i .. 't'] = x.d, x.t end
    return out
end

--- Put an outfit (PedOutfit.read's) on a ped: only what is not already so, and only styles and colours its model has.
---@param ped number
---@param outfit table|nil
function PedOutfit.apply(ped, outfit)
    if type(outfit) ~= 'table' or not ped or ped == 0 or not DoesEntityExist(ped) then return end
    for _, x in ipairs(outfit.c or {}) do
        if x.d < GetNumberOfPedDrawableVariations(ped, x.i) and x.t < GetNumberOfPedTextureVariations(ped, x.i, x.d)
            and (GetPedDrawableVariation(ped, x.i) ~= x.d or GetPedTextureVariation(ped, x.i) ~= x.t) then
            SetPedComponentVariation(ped, x.i, x.d, x.t, 0)
        end
    end
    for _, x in ipairs(outfit.p or {}) do
        if PROP_OK[x.i] then
            if x.d < 0 then
                if GetPedPropIndex(ped, x.i) ~= -1 then ClearPedProp(ped, x.i) end
            elseif x.d < GetNumberOfPedPropDrawableVariations(ped, x.i) and x.t < GetNumberOfPedPropTextureVariations(ped, x.i, x.d)
                and (GetPedPropIndex(ped, x.i) ~= x.d or GetPedPropTextureIndex(ped, x.i) ~= x.t) then
                SetPedPropIndex(ped, x.i, x.d, x.t, true)
            end
        end
    end
end

local optionsOf = {}   -- [model] = { c, p } once read

--- What a ped model can wear: { c = { { i, n, t = { colours of each style } } }, p = (the same for props) }, only the
--- parts with more than one look (a prop: any, since none is one). Read off a ped of that model made here for it,
--- unseen and gone at once; kept for the model. WAITS (it loads the model): call from a thread. nil and why when it
--- will not load.
---@param model string|nil
---@return table|nil options
---@return string|nil why
function PedOutfit.options(model)
    if type(model) ~= 'string' or not model:match('^[%w_]+$') or #model > 64 then return nil, 'not a ped model name' end
    local key = model:lower()
    if optionsOf[key] then return optionsOf[key] end
    local hash = LoadModel(key, 8000)
    if not hash then return nil, model .. ' is not a model this game has, or did not load' end
    if not IsModelAPed(hash) then
        SetModelAsNoLongerNeeded(hash)
        return nil, model .. ' is not a ped'
    end
    -- Out of sight under the camera, not networked, gone before the next frame.
    local at = GetFinalRenderedCamCoord()
    local ped = CreatePed(4, hash, at.x, at.y, at.z - 60.0, 0.0, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return nil, model .. ' could not be made' end
    SetEntityVisible(ped, false, false)
    FreezeEntityPosition(ped, true)
    local c, p = {}, {}
    for i = 0, PARTS do
        local n = GetNumberOfPedDrawableVariations(ped, i)
        local t, choices = {}, 0
        for d = 0, n - 1 do
            t[d + 1] = math.max(1, GetNumberOfPedTextureVariations(ped, i, d))
            choices = choices + t[d + 1]
        end
        if choices > 1 then c[#c + 1] = { i = i, n = n, t = t } end
    end
    for _, i in ipairs(PROPS) do
        local n = GetNumberOfPedPropDrawableVariations(ped, i)
        if n > 0 then
            local t = {}
            for d = 0, n - 1 do t[d + 1] = math.max(1, GetNumberOfPedPropTextureVariations(ped, i, d)) end
            p[#p + 1] = { i = i, n = n, t = t }
        end
    end
    DeleteEntity(ped)
    optionsOf[key] = { c = c, p = p }
    return optionsOf[key]
end
