-- World-space interact prompts: textured triangles drawn by the engine, depth-tested, with no position passing
-- through a browser. What is drawn comes from a fixed three DUIs, however many prompts exist:
--   badge atlas   every badge state for every key in use in one texture (a state change is a different UV cell)
--   label atlas   N rows of text, repainted only when a row's text changes
--   preview       one picture for the highlighted option (512x288), repainted on a keypress
-- Two quads per prompt: the badge sits on the world point, the label is a fixed-size cell beside it (DUI is one-way, so
-- the text width is unknown). The reversed triangle winding is the correct one, and the third texture coordinate is 0.

local R = {}

-- Atlas geometry, shared with the two HTML pages.
-- Distinct glyphs the atlas has room for. Columns are claimed on demand and never released; a full atlas falls back to an E
-- (or the generic car for a logo). Whip asks for at most ~90; recount GLYPHS in badge.html before adding more.
local BADGE_COLS   = 96
-- px per square badge cell: 128 (12288 px wide, about 19 MB of VRAM), or fitted by attach() to the widest browser the game allows
-- (8192 on Enhanced, so 85). The columns stay at 96 either way. badge.html lays itself out from `cell`.
local BADGE_CELL   = 128
local BADGE_STATES = 3            -- idle / active / focused, in that row order

-- How much of a cell the visible disc fills (the `.disc` width in badge.html; the rest is glow margin). Config's pixel
-- height means the disc, so the target is divided back out. pushBadgeSetup sends this to the page.
local BADGE_DISC_FRAC = 0.78

local LABEL_W    = 1024           -- px, one row's width
local LABEL_ROW_H = 96            -- px, one row's height

local TXD_BADGE, TEX_BADGE = 'whip_interact_badge_txd', 'badge'
local TXD_LABEL, TEX_LABEL = 'whip_interact_label_txd', 'label'
local TXD_PREVIEW, TEX_PREVIEW = 'whip_interact_preview_txd', 'preview'

-- The preview picture's texture size, 16:9 like the vehicle pictures (512x288).
local PREVIEW_W, PREVIEW_H = 512, 288

-- The three browsers (client/dui_page.lua), made by R.attach and given back by R.detach.
local badgePage, labelPage, previewPage = nil, nil, nil

-- What the preview shows now, so a message goes out only on a change.
local previewSrc = nil
local attached = false

-- key letter -> atlas column. 'E' is claimed up front (the Interactions.register default).
local keyCols, keyList, keyCount = { E = 0 }, { 'E' }, 1

-- Label rows: [rowIndex] = { id = owner or nil, text = what is painted there }
local rows = {}
local rowsInUse = 0

-- ---- cached sizing ----
local badgeM = nil        -- badge QUAD height in metres (the cell, not the disc inside it)
local labelM = nil        -- label row height in metres; sized independently of the badge
--- The FOV the two figures above were derived for (resolution is not an input; see pxToMetres).
local sizedForFov = nil

--- The per-prompt animation state; declared here because R.clear() resets it.
local fx = {}

-- Scalars, not vectors, in the draw path: every vector operation allocates (about 29 per prompt per frame).
-- Sizing

--- The resolution every pixel figure in Config is quoted at (matches html/js/utils.js).
local REFERENCE_H = 1440.0

--- How tall in metres something must be to appear `px` tall on a 1440p screen at InteractActiveRange:
--- screen fraction = worldHeight / (2 * distance * tan(fov/2)). Divided by the reference height so the badge keeps the same
--- fraction of the screen at any resolution. GetGameplayCamFov is the vertical FOV, so aspect ratio needs no handling.
local function pxToMetres(px, fov)
    local range = Config.InteractActiveRange or 2.0
    return (px / REFERENCE_H) * 2.0 * range * math.tan(math.rad(fov) * 0.5)
end

--- Recompute both quad sizes, each from its own config number; only the label's height is config's (its width follows the
--- atlas row's proportions). Recomputed when the FOV changes (aiming, sprinting).
local function updateBadgeSize()
    local cfg = Config.Interact3D or {}

    local fov = GetGameplayCamFov()
    if not fov or fov <= 0 then
        badgeM = badgeM or 0.06
        labelM = labelM or 0.045
        return
    end

    if fov == sizedForFov then return end
    sizedForFov = fov

    if cfg.badgeMetres then
        badgeM = cfg.badgeMetres + 0.0
    else
        -- The disc's height to hit the target, scaled out to the whole atlas cell (which carries a transparent margin).
        badgeM = pxToMetres(cfg.badgePx or 68, fov) / BADGE_DISC_FRAC
    end

    labelM = pxToMetres(cfg.labelPx or 98, fov)
end

-- The prompt reach changed in /whip → Settings: the badge size is worked out again next frame.
Settings.onChange('InteractActiveRange', function() sizedForFov = nil end)
-- Same for Interact3D's sizes (badgePx, labelPx, badgeMetres); labelRows waits for a restart.
Settings.onChange('Interact3D', function() sizedForFov = nil end)

-- Themes: one more copy of the badge atlas per look in use. A style can ask for a theme (glass, rim, keycap, dot);
-- each is a whole second atlas with the same columns and different art. Made when a prompt first wears it, given back
-- THEME_IDLE_MS after its last draw (an atlas is a browser and ~19 MB). 'classic' is the atlas above.

--- [look] = its DuiPage. A look is a theme, with '+dark' on a dark shape ('keycap+dark'); each is its own atlas copy.
local themeAtlas = {}
local THEME_IDLE_MS = 60000

--- The look the renderer's own atlas (badgePage) is drawn in: the player's chosen shape and dark switch, else the server's
--- (InteractStyle.baseLook), so most prompts need no second atlas. Updated at the top of every frame.
local currentBase = 'keycap'

local function badgeSetup(look)
    look = tostring(look)
    return json.encode({
        cell = BADGE_CELL,
        cols = BADGE_COLS,
        keys = keyList,
        -- Sent, so the number lives in Lua only.
        discFrac = BADGE_DISC_FRAC,
        theme = look:match('^%a+') or 'keycap',
        dark = look:find('+dark', 1, true) ~= nil,
    })
end

local function pushBadgeSetup()
    if badgePage then badgePage:send(badgeSetup(currentBase), 'setup') end
    -- Every look's copy holds the same columns, so a new key goes to all of them.
    for look, t in pairs(themeAtlas) do t:send(badgeSetup(look), 'setup') end
end

--- A badge atlas's browser: the renderer's own (`look` nil) or a theme's.
local function badgePageFor(look, txd)
    return DuiPage.new({
        name = 'interact3d', url = 'interact3d/badge.html', txd = txd, tex = TEX_BADGE,
        -- (Asked when made: R.attach may have fitted the cell.)
        width = function() return BADGE_CELL * BADGE_COLS end,
        height = function() return BADGE_CELL * BADGE_STATES end,
        setup = function() return badgeSetup(look or currentBase) end,
        -- Told its setup again a moment after it is up: a browser may not be listening for the first message, leaving a blank atlas.
        -- (The label page's setup is not resent: it rebuilds its rows.)
        again = { 500, 1500 },
        -- A theme's is given back when unused for a while.
        idleMs = look and THEME_IDLE_MS or nil,
        -- The renderer's own refusal is said by R.attach.
        quiet = look == nil,
        without = look and ('prompts in the %s look are drawn in the default one'):format(look) or nil,
    })
end

--- The texture dictionary a look's badges are drawn from, making its atlas if needed. Until it is up, the renderer's own (default look, not blank).
---@param look string|nil  a style's `look`
---@return string txd
local function themeTxd(look)
    if look == nil or look == currentBase or not attached then return TXD_BADGE end
    local t = themeAtlas[look]
    if not t then
        t = badgePageFor(look, TXD_BADGE .. '_' .. (look:gsub('%+', '_')))
        themeAtlas[look] = t
    end
    if not t:ensure() or not t:up() then return TXD_BADGE end
    return t.txd
end

local function labelSetup()
    return { setup = { width = LABEL_W, rowH = LABEL_ROW_H, rows = #rows } }
end

function R.attach()
    if attached then return end
    attached = true

    local cfg = Config.Interact3D or {}
    local rowCount = math.max(1, math.floor(cfg.labelRows or 8))

    rows = {}
    for i = 1, rowCount do rows[i] = { id = nil, text = nil } end
    rowsInUse = 0

    -- Each browser becomes an ordinary live texture once handed to a runtime dictionary, so a SendDuiMessage changes the quads
    -- without a rebuild. Drawn in the player's shape and darkness (see currentBase).
    currentBase = InteractStyle.baseLook()

    -- A browser wider than the game allows throws and names the limit ("Invalid Width [1, 8192]" on Enhanced). The badge atlas
    -- is the one texture that reaches it, so the cell is fitted to that number and the atlas remade. Any other refusal leaves the renderer off.
    badgePage = badgePageFor(nil, TXD_BADGE)
    local made, why = badgePage:ensure()
    local maxW = not made and tonumber(tostring(why):match('Invalid Width %[%d+, (%d+)%]'))
    if maxW and maxW >= BADGE_COLS then
        BADGE_CELL = math.min(BADGE_CELL, maxW // BADGE_COLS)
        badgePage = badgePageFor(nil, TXD_BADGE)
        made, why = badgePage:ensure()
    end
    if not made then
        attached = false
        badgePage = nil
        print(('[whip_core:interact3d] the game refused the badge texture, so 3D prompts are off: %s'):format(tostring(why)))
        return
    end

    labelPage = DuiPage.new({ name = 'interact3d', url = 'interact3d/label.html', width = LABEL_W,
        height = LABEL_ROW_H * rowCount, txd = TXD_LABEL, tex = TEX_LABEL, setup = labelSetup,
        without = 'prompts show no words' })
    labelPage:ensure()

    -- The third browser: one picture for the focused prompt.
    previewPage = DuiPage.new({ name = 'interact3d', url = 'interact3d/preview.html', width = PREVIEW_W,
        height = PREVIEW_H, txd = TXD_PREVIEW, tex = TEX_PREVIEW, without = 'prompts show no pictures' })
    previewPage:ensure()
    previewSrc = nil

    updateBadgeSize()
end

function R.detach()
    if badgePage then badgePage:release(); badgePage = nil end
    for _, t in pairs(themeAtlas) do t:release() end
    themeAtlas = {}
    if labelPage then labelPage:release(); labelPage = nil end
    if previewPage then previewPage:release(); previewPage = nil end
    previewSrc = nil
    attached = false
    rows = {}
    rowsInUse = 0
end

--- Nothing on screen: the browsers stay (they are the expensive part); only the rows are handed back.
function R.clear()
    for i = 1, #rows do
        if rows[i].id then
            rows[i].id = nil
            rows[i].text = nil
            if labelPage then labelPage:send({ row = i - 1, text = '' }, i) end
        end
    end
    rowsInUse = 0

    -- The preview is blanked: its texture is live and would flash the previous picture.
    if previewPage then previewPage:send({ image = '' }, 'image') end
    previewSrc = nil

    -- The animation state goes too (a returning prompt fades in fresh).
    fx = {}
end

-- Keys and label rows

--- Which atlas column holds this key's badge, claiming one if new. A full atlas falls back rather than refusing to draw.
local function columnForKey(key)
    key = key or 'E'
    local col = keyCols[key]
    if col then return col end

    if keyCount >= BADGE_COLS then
        -- Fall back to something of the right kind: a manufacturer logo becomes the generic car;
        -- anything else the E.
        local fallback = key:sub(1, 4) == 'mfr_' and keyCols['car'] or 0
        print(('[whip_core:interact] badge atlas is full (%d keys) — "%s" will show as %s')
            :format(BADGE_COLS, tostring(key), fallback == 0 and 'E' or 'the generic car'))
        keyCols[key] = fallback or 0
        return fallback or 0
    end

    col = keyCount
    keyCols[key] = col
    keyCount = keyCount + 1
    keyList[keyCount] = key
    pushBadgeSetup()   -- rare: only the first time a new letter is ever seen
    return col
end

-- One row per option: repainting a row is asynchronous, so each of the focused prompt's options gets its own row and
-- scrolling changes which row the quad samples (a UV change). Only the focused prompt draws a label, so
-- Config.Interact3D.labelRows (8) is enough. With more options than rows, a rolling window holds the options around the
-- selection (3 behind, 4 ahead by default), each in row "option mod rows"; a step repaints only the row coming into the window.

--- Hand every row this prompt holds back to the pool.
local function releaseRow(e)
    local held = e._rows
    if not held then return end

    for k = 1, #held do
        local i = held[k]
        local row = rows[i]
        if row and row.id == e.id then
            row.id = nil
            row.text = nil
            rowsInUse = rowsInUse - 1
            if labelPage then labelPage:send({ row = i - 1, text = '' }, i) end
        end
        held[k] = nil
    end

    e._rows = nil
    e._row = nil
    e._slots = nil
end

--- Paint one row, only if what it says differs. The only place a repaint happens. Sent with its style's type (weight,
--- outline, case, shadow), so a row is set again when another style's prompt takes it; nil is the page's own look.
local function paintRow(i, text, st)
    local row = rows[i]
    if not row then return end
    text = text or ''
    local fmtKey = st and st.labelFmtKey or nil
    if row.text == text and row.fmtKey == fmtKey then return end
    row.text = text
    row.fmtKey = fmtKey
    if labelPage then labelPage:send({ row = i - 1, text = text, fmt = st and st.labelFmt or false }, i) end
end

--- Give this prompt a row per option, each saying what its option says. `e.optLabels` is the focused prompt's option list;
--- without it this falls back to the single selected label.
---@return boolean ok  false when the atlas had no room at all
local function ensureRow(e)
    local labels = e.optLabels
    local want = (labels and #labels > 0) and #labels or 1
    -- One slot per row, at most. With no more options than rows, slot k is option k.
    local slots = math.min(want, #rows)
    e._slots = slots

    local held = e._rows
    if not held then held = {}; e._rows = held end

    for k = 1, slots do
        local i = held[k]
        -- Claim a row for this slot if it holds no live one.
        if not (i and rows[i] and rows[i].id == e.id) then
            i = nil
            for j = 1, #rows do
                if not rows[j].id then
                    rows[j].id = e.id
                    rows[j].text = nil          -- unknown, so the paint below always lands
                    rowsInUse = rowsInUse + 1
                    i = j
                    break
                end
            end
            held[k] = i
        end
    end

    -- The window: `slots` options round the selection (a third behind, the rest ahead), held against the list ends.
    -- Option n lives in slot (n - 1) % slots + 1, so the window's options never share a slot.
    local sel = e.sel or 1
    if sel < 1 then sel = 1 elseif sel > want then sel = want end
    local lo = sel - math.floor((slots - 1) / 2)
    if lo > want - slots + 1 then lo = want - slots + 1 end
    if lo < 1 then lo = 1 end
    for n = lo, lo + slots - 1 do
        local i = held[(n - 1) % slots + 1]
        if i then
            -- The selected option takes e.label (the only one carrying a live status such as "Successful!"), every other its own.
            local text
            if n == sel then
                text = e.label
            else
                text = labels and labels[n] or e.label
            end
            paintRow(i, text, e.st)
        end
    end

    -- Options went away: give the surplus rows back.
    for k = slots + 1, #held do
        local i = held[k]
        local row = i and rows[i]
        if row and row.id == e.id then
            row.id = nil
            row.text = nil
            rowsInUse = rowsInUse - 1
            if labelPage then labelPage:send({ row = i - 1, text = '' }, i) end
        end
        held[k] = nil
    end

    -- Which row the quad samples: the selected option's slot, (sel - 1) % slots + 1 (same as the per-frame pick).
    e._row = held[(sel - 1) % slots + 1]

    return e._row ~= nil
end

-- Drawing

--- One textured quad as two triangles (client/world_quad.lua, shared with the garage bay outline).
local quadDraw = WorldQuad.draw

-- How wide a label's words are: a prompt centred on its point (`centre`) or kept inside a box (`fit`) needs the width. DUI is
-- one-way, so whip's own page measures it (html/js/label-measure.js) and answers once per label and look; until then, a guess.
-- Asked only for those prompts.

local LABEL_PAD  = 8                                     -- label.html: a row's left padding, px
local LABEL_TYPE = math.floor(LABEL_ROW_H * 0.56 + 0.5)  -- label.html: a row's type size, px
local textPx  = {}   -- [look .. '\1' .. text] = its width in row pixels, or false while asked
local askedAt = {}   -- [same key] = when it was asked (asked again if no answer in 3 s)
local textPxN = 0

local function wordsPx(text, st)
    local key = ((st and st.labelFmtKey) or '') .. '\1' .. text
    local px = textPx[key]
    if px then return px end
    local now = GetGameTimer()
    if px == nil or now - (askedAt[key] or 0) > 3000 then
        if px == nil then
            -- A bound: names come and go over a session.
            if textPxN >= 512 then textPx, askedAt, textPxN = {}, {}, 0 end
            textPxN = textPxN + 1
        end
        textPx[key], askedAt[key] = false, now
        local f = st and st.labelFmt
        SendNUIMessage({ action = 'i3dMeasure', key = key, text = text, px = LABEL_TYPE,
            weight = f and f.weight or nil, case = f and f.case or nil })
    end
    -- The guess: the bold face runs at about 0.6 of its size a character.
    return math.min(LABEL_W - 2 * LABEL_PAD, #text * LABEL_TYPE * 0.6)
end

RegisterNUICallback('i3dMeasured', function(d, cb)
    if type(d) == 'table' and type(d.key) == 'string' and textPx[d.key] == false then
        textPx[d.key] = tonumber(d.px) or false
    end
    cb('ok')
end)

-- Wrapped round a box: a sign prompt on one side of a box (a stash's 'face' prompt) may carry `wrap`, the box as seen from
-- that side. While it draws, wrapNow holds it and every quad (circle, ring, label, picture) goes through foldQuad: what runs
-- past an edge is cut and laid on round the corner, with the texture's u range cut to match.
-- wrap = { ox, oy   the side's middle, on the plane the prompt is drawn in
--          ax, ay   along the side, the way its `hi` edge lies
--          tx, ty   back into the box from the side
--          lo, hi   where the side's two edges are, along it from (ox, oy)
--          depth    how far the box goes back (the next sides' length) }
-- All on the box grown by the prompt's small gap. Such a prompt lies in its own plane, so its pull toward the camera is 0.

local wrapNow = nil
local cutBuf = {}   -- the cuts across one quad, reused: up to six, sorted

--- A point `s` along the box's outline from the side's middle (on the side between lo and hi, then round the corners), as a place on the ground plan.
local function unroll(W, s)
    local depth, width = W.depth, W.hi - W.lo
    local k, ex, ey, dir
    if s >= W.lo and s <= W.hi then return W.ox + W.ax * s, W.oy + W.ay * s end
    if s > W.hi then
        k, ex, ey, dir = s - W.hi, W.ox + W.ax * W.hi, W.oy + W.ay * W.hi, -1
    else
        k, ex, ey, dir = W.lo - s, W.ox + W.ax * W.lo, W.oy + W.ay * W.lo, 1
    end
    -- Round the first corner: back along the next side.
    if k <= depth then return ex + W.tx * k, ey + W.ty * k end
    ex, ey, k = ex + W.tx * depth, ey + W.ty * depth, k - depth
    -- Round the second: across the back.
    if k <= width then return ex + W.ax * dir * k, ey + W.ay * dir * k end
    ex, ey, k = ex + W.ax * dir * width, ey + W.ay * dir * width, k - width
    -- Round the third: back toward the side it started on (and no further round than that).
    return ex - W.tx * k, ey - W.ty * k
end

--- One quad of a wrapping prompt (see above). Its arguments are WorldQuad.draw's.
local function foldQuad(W, txd, tex, cx, cy, cz, rx, ry, rz, ux, uy, uz, w, h, u0, v0, u1, v1, a, tr, tg, tb)
    local hw, hh = w * 0.5, h * 0.5
    local ox, oy, ax, ay = W.ox, W.oy, W.ax, W.ay
    local hx, hy, hz = rx * hw, ry * hw, rz * hw
    local gx, gy, gz = ux * hh, uy * hh, uz * hh
    local tlx, tly, tlz = cx + gx - hx, cy + gy - hy, cz + gz - hz
    local trx, try_, trz = cx + gx + hx, cy + gy + hy, cz + gz + hz
    local blx, bly, blz = cx - gx - hx, cy - gy - hy, cz - gz - hz
    local brx, bry, brz = cx - gx + hx, cy - gy + hy, cz - gz + hz
    -- How far along the side each corner is (s), from its middle.
    local s1 = (tlx - ox) * ax + (tly - oy) * ay
    local s2 = (trx - ox) * ax + (try_ - oy) * ay
    local s3 = (blx - ox) * ax + (bly - oy) * ay
    local s4 = (brx - ox) * ax + (bry - oy) * ay
    local sMin, sMax = math.min(s1, s2, s3, s4), math.max(s1, s2, s3, s4)

    -- All of it on the side: as ever.
    if sMin >= W.lo and sMax <= W.hi then
        return quadDraw(txd, tex, cx, cy, cz, rx, ry, rz, ux, uy, uz, w, h, u0, v0, u1, v1, a, tr, tg, tb)
    end

    local k = rx * ax + ry * ay
    if math.abs(rz) < 0.01 and math.abs(ux) + math.abs(uy) < 0.01 and math.abs(k) > 0.99 and w > 0.0 then
        -- An upright quad along the side: cut where it meets each edge and corner, each piece drawn on its own side with its slice of the texture.
        local sc = (cx - ox) * ax + (cy - oy) * ay
        local n = 0
        local depth, width = W.depth, W.hi - W.lo
        for i = 1, 6 do
            local sb = (i == 1 and W.lo - depth - width) or (i == 2 and W.lo - depth) or (i == 3 and W.lo)
                or (i == 4 and W.hi) or (i == 5 and W.hi + depth) or (W.hi + depth + width)
            local x = (sb - sc) / k
            if x > -hw and x < hw then
                n = n + 1
                local j = n
                while j > 1 and cutBuf[j - 1] > x do cutBuf[j] = cutBuf[j - 1]; j = j - 1 end
                cutBuf[j] = x
            end
        end
        local xa = -hw
        for i = 1, n + 1 do
            local xb = (i <= n) and cutBuf[i] or hw
            if xb - xa > 0.0005 then
                local pax, pay = unroll(W, sc + k * xa)
                local pbx, pby = unroll(W, sc + k * xb)
                local dx, dy = pbx - pax, pby - pay
                local len = math.sqrt(dx * dx + dy * dy)
                if len > 0.0001 then
                    local ua = u0 + (xa + hw) / w * (u1 - u0)
                    local ub = u0 + (xb + hw) / w * (u1 - u0)
                    quadDraw(txd, tex, (pax + pbx) * 0.5, (pay + pby) * 0.5, cz, dx / len, dy / len, 0.0,
                             ux, uy, uz, xb - xa, h, ua, v0, ub, v1, a, tr, tg, tb)
                end
            end
            xa = xb
        end
        return
    end

    -- Anything else (a slanted ring piece): each corner laid round the box on its own.
    tlx, tly = unroll(W, s1)
    trx, try_ = unroll(W, s2)
    blx, bly = unroll(W, s3)
    brx, bry = unroll(W, s4)
    DrawTexturedPoly(tlx, tly, tlz, blx, bly, blz, trx, try_, trz, tr, tg, tb, a, txd, tex,
        u0, v0, 0.0, u0, v1, 0.0, u1, v0, 0.0)
    DrawTexturedPoly(trx, try_, trz, blx, bly, blz, brx, bry, brz, tr, tg, tb, a, txd, tex,
        u1, v0, 0.0, u0, v1, 0.0, u1, v1, 0.0)
end

--- Every quad this renderer draws: through foldQuad while a wrapping prompt draws (wrapNow).
local function drawQuad(txd, tex, cx, cy, cz, rx, ry, rz, ux, uy, uz, w, h, u0, v0, u1, v1, a, tr, tg, tb)
    if wrapNow then
        return foldQuad(wrapNow, txd, tex, cx, cy, cz, rx, ry, rz, ux, uy, uz, w, h, u0, v0, u1, v1, a, tr, tg, tb)
    end
    return quadDraw(txd, tex, cx, cy, cz, rx, ry, rz, ux, uy, uz, w, h, u0, v0, u1, v1, a, tr, tg, tb)
end

--- The opacity ladder from the prompt's style; 'default' is 0.35 / 0.85 / 1.0, as the NUI prompt.
---@return number 0..1
local function targetAlpha(st, focused, active)
    if focused then return st.focused end
    if active then return st.inReach end
    return st.seen
end

---@return number 0 idle | 1 in range | 2 focused
local function stateOf(focused, active)
    return focused and 2 or (active and 1 or 0)
end

--- The badge's tint: white, unless a flash is decaying. DrawTexturedPoly's colour multiplies the texture, so the disc takes the
--- colour and the dark parts stay dark. Two pulses, not a fade; keyframes for how much colour shows, 1 (full) to 0 (white).
local FLASH_CURVE = {
    { 0.00, 1.0 },   -- colour
    { 0.20, 1.0 },
    { 0.34, 0.0 },   -- white
    { 0.46, 0.0 },
    { 0.60, 1.0 },   -- colour again
    { 0.74, 1.0 },
    { 1.00, 0.0 },   -- and away
}

--- A style's `flash = 'fade'`: one colour, held a moment, then gone (quieter than two blinks).
local FLASH_FADE = {
    { 0.00, 1.0 },
    { 0.25, 1.0 },
    { 1.00, 0.0 },
}

--- How much of the flash colour is showing right now, 0..1.
local function flashAmount(curve, k)
    for i = 1, #curve - 1 do
        local a, b = curve[i], curve[i + 1]
        if k <= b[1] then
            local span = b[1] - a[1]
            if span <= 0 then return b[2] end
            local t = (k - a[1]) / span
            return a[2] + (b[2] - a[2]) * t
        end
    end
    return 0.0
end

--- The badge's tint: the style's own, unless a flash is running (Interactions.flash).
---@return number r, number g, number b
local function flashTint(e, st)
    local br, bg, bb = st.tintR, st.tintG, st.tintB
    if not e.flashAt then return br, bg, bb end

    local dur = st.flashMs
    local age = GetGameTimer() - e.flashAt
    if age < 0 or age >= dur then return br, bg, bb end

    local amt = flashAmount(st.flash == 'fade' and FLASH_FADE or FLASH_CURVE, age / dur)
    if amt <= 0.0 then return br, bg, bb end

    -- Toward the style's tint by (1 - amt). The dark glyph is unaffected, so it stays readable through the flash.
    local inv = 1.0 - amt
    local fr, fg, fb = e.flashR or br, e.flashG or bg, e.flashB or bb
    local r = fr + (br - fr) * inv
    local g = fg + (bg - fg) * inv
    local b = fb + (bb - fb) * inv
    return math.floor(r + 0.5), math.floor(g + 0.5), math.floor(b + 0.5)
end

-- Animation: every transition is a number advanced by hand (no CSS). Four things move separately:
--   alpha    the opacity ladder, eased between the three states
--   blend    a crossfade between two badge cells (a texture cannot tween, so both are drawn for a moment)
--   labelA   the label's own fade, on focus rather than the ladder
--   life     whether the prompt is arriving or leaving
-- FX outlive the entry: a prompt leaves `visible` the instant it leaves range, so this table keeps what it needs to finish the fade.

-- [id] = { a, state, prev, blend, labelA, alive, x, y, z, heading, icon, row, dist, label, sizeScale }
-- (Declared at the top of the file.)

--- Move `cur` toward `target` by a frame's worth of a `dur`-second transition (frame-rate independent).
local function approach(cur, target, dt, dur)
    if dur <= 0 then return target end
    local step = dt / dur
    if step >= 1.0 then return target end
    return cur + (target - cur) * step
end

--- The timed easings a style can ask for: progress 0..1 in, value progress out. 'smooth' is approach() above, the default.
local EASE = {
    linear = function(p) return p end,
    out    = function(p) local q = 1.0 - p return 1.0 - q * q * q end,
    inOut  = function(p)
        if p < 0.5 then return 4.0 * p * p * p end
        local q = 2.0 - 2.0 * p
        return 1.0 - q * q * q * 0.5
    end,
    -- Past the end by about a tenth, then back (a settle).
    back   = function(p) local q = p - 1.0 return 1.0 + 2.70158 * q * q * q + 1.70158 * q * q end,
}

--- Move one of an fx entry's values toward `target` over `dur` seconds, eased. 'smooth' (or an unknown easing) is approach().
--- Timed easings remember where they started, so each value has three companions (start, target, elapsed); `keys` names all four
--- as constant tables (K_*), so a frame builds no strings.
local function tween(e, keys, target, dt, dur, ease)
    local k = keys[1]
    local fn = EASE[ease]
    if not fn then
        e[k] = approach(e[k], target, dt, dur)
        return
    end
    local fromK, toK, tK = keys[2], keys[3], keys[4]
    if e[toK] ~= target then
        e[fromK] = e[k]
        e[toK] = target
        e[tK] = 0.0
    end
    local t = e[tK] + dt
    e[tK] = t
    if dur <= 0 or t >= dur then e[k] = target return end
    local from = e[fromK]
    e[k] = from + (target - from) * fn(t / dur)
end

local K_A     = { 'a', 'aFrom', 'aTo', 'aT' }
local K_LABEL = { 'labelA', 'labelFrom', 'labelTo', 'labelT' }
local K_IMAGE = { 'imageA', 'imageFrom', 'imageTo', 'imageT' }
local K_STACK = { 'stackA', 'stackFrom', 'stackTo', 'stackT' }
local K_SLIDE = { 'slide', 'slideFrom', 'slideTo', 'slideT' }
local K_BLEND = { 'blend', 'blendFrom', 'blendTo', 'blendT' }

--- 0..1 held to that range, as 0..255 (a 'back' easing overshoots; DrawTexturedPoly rejects an opacity past 1).
local function byte(x)
    if x <= 0.0 then return 0 end
    if x >= 1.0 then return 255 end
    return math.floor(x * 255.0 + 0.5)
end

local TAU = math.pi * 2.0

local K_HOLD = { 'holdA', 'holdFrom', 'holdTo', 'holdT' }

-- The ring a hold to use fills (holdMs): geometry, short quads round the prompt sampling the atlas's white cell
-- (column '__white'), painted by the colour argument (black track, the style's tint for the fill). It follows the prompt's
-- shape: a circle, or a rounded square for keycap.

local RING_SEGS = 48

--- A point `t` of the way round the ring's path (0..1, clockwise from the top) in the badge's plane (across, up), and the path's direction there.
--- A circle of radius `half`, or with a `corner` a rounded square of half-side `half`.
---@return number x, number y, number dx, number dy
local function ringPoint(t, half, corner)
    if not corner then
        local ang = t * TAU
        local s, c = math.sin(ang), math.cos(ang)
        return s * half, c * half, c, -s
    end
    local straight = half - corner          -- half of an edge's straight part
    local arc = corner * math.pi * 0.5      -- one corner's length
    local d = (t % 1.0) * (8.0 * straight + 4.0 * arc)
    -- The top edge's right half.
    if d < straight then return d, half, 1.0, 0.0 end
    d = d - straight
    -- Then each corner and the edge after it, clockwise; the last edge is the top edge's left half.
    for k = 1, 4 do
        if d < arc then
            local ang = (k - 1) * math.pi * 0.5 + d / corner   -- from straight up, clockwise
            local s, c = math.sin(ang), math.cos(ang)
            local ccx = (k <= 2) and straight or -straight
            local ccy = (k == 1 or k == 4) and straight or -straight
            return ccx + s * corner, ccy + c * corner, c, -s
        end
        d = d - arc
        local len = (k < 4) and (2.0 * straight) or straight
        if d < len then
            if k == 1 then return half, straight - d, 0.0, -1.0 end     -- the right edge, down
            if k == 2 then return straight - d, -half, -1.0, 0.0 end    -- the bottom, leftward
            if k == 3 then return -half, -straight + d, 0.0, 1.0 end    -- the left edge, up
            return -straight + d, half, 1.0, 0.0                        -- the top's left half
        end
        d = d - len
    end
    return 0.0, half, 1.0, 0.0
end

--- One piece of the ring: from `from` to `to` of the way round.
local function ringArc(cx, cy, cz, rx, ry, rz, ux, uy, uz, half, corner, perimeter, thick, from, to,
                       u0, v0, u1, v1, a, r, g, b)
    local px, py, dx, dy = ringPoint((from + to) * 0.5, half, corner)
    -- Along the path (clockwise), and out from it (a quarter turn).
    local tx, ty, tz = rx * dx + ux * dy, ry * dx + uy * dy, rz * dx + uz * dy
    local ox, oy, oz = -rx * dy + ux * dx, -ry * dy + uy * dx, -rz * dy + uz * dx
    -- A little long, so neighbours meet.
    local len = (to - from) * perimeter * 1.12
    drawQuad(TXD_BADGE, TEX_BADGE,
             cx + rx * px + ux * py, cy + ry * px + uy * py, cz + rz * px + uz * py,
             tx, ty, tz, ox, oy, oz, len, thick, u0, v0, u1, v1, a, r, g, b)
end

--- The whole ring: a dark track all the way round, and over it the part filled so far (`p`, 0..1), clockwise from the top.
--- `corner` nil is a circle; given, a rounded square. `dark`: track white, colours swapped as the prompt's are.
local function drawHoldRing(cx, cy, cz, rx, ry, rz, ux, uy, uz, half, corner, thick, p, a, r, g, b, dark)
    local col = columnForKey('__white')
    local u0, u1 = (col + 0.3) / BADGE_COLS, (col + 0.7) / BADGE_COLS
    local v0, v1 = 0.3 / BADGE_STATES, 0.7 / BADGE_STATES
    local perimeter = corner and (8.0 * (half - corner) + 2.0 * math.pi * corner) or (TAU * half)
    local trackA = math.floor(a * 0.55 + 0.5)
    local track = dark and 255 or 0
    local seg = 1.0 / RING_SEGS
    for i = 0, RING_SEGS - 1 do
        local from = i * seg
        if trackA >= 1 then
            ringArc(cx, cy, cz, rx, ry, rz, ux, uy, uz, half, corner, perimeter, thick, from, from + seg,
                    u0, v0, u1, v1, trackA, track, track, track)
        end
        if p > from then
            ringArc(cx, cy, cz, rx, ry, rz, ux, uy, uz, half, corner, perimeter, thick, from, math.min(p, from + seg),
                    u0, v0, u1, v1, a, r, g, b)
        end
    end
end

--- Which way is right, and which way is up, for this prompt. Nil when it should not be drawn: a fixed sign seen from behind.
---@return number|nil rx, number|nil ry, number|nil rz, number|nil ux, number|nil uy, number|nil uz
local function signOrientation(e, camX, camY, camZ)
    local h = math.rad(e.heading)
    local sinH, cosH = math.sin(h), math.cos(h)

    -- Right is negated: the rendered face is cross(right, up), and (cos h, sin h) would put it opposite the heading and
    -- backface culling would hide every sign. Negated, the face matches the heading and the art is not mirrored.
    local rx, ry = -cosH, -sinH

    -- Leaning back (`tilt`, degrees). Right stays level; the face turns up by the tilt, normal (-sin h cos t, cos h cos t, sin t),
    -- and up is that normal crossed with right: (sin t sin h, -sin t cos h, cos t). At 0 that is world-up.
    local t = e.tilt and math.rad(e.tilt) or 0.0
    local sinT, cosT = math.sin(t), math.cos(t)

    -- The prompt's style says; 'default' is Config.Interact3D.cullBehind. Not for a sign wrapped round a box (foldQuad): each
    -- piece faces out of its own side, so the GPU culls just the ones you cannot see.
    if not (e.st and e.st.cullBehind == false) and not e.wrap then
        -- The rendered normal is (-sin h, cos h), tilted up by t; a viewer behind that plane sees nothing to read.
        if (-sinH * cosT * (camX - e.x) + cosH * cosT * (camY - e.y) + sinT * ((camZ or e.z) - e.z)) <= 0.0 then
            return nil
        end
    end

    return rx, ry, 0.0, sinT * sinH, -sinT * cosH, cosT
end

--- The billboard basis: one orientation shared by every prompt, from the camera's axes. Faces the camera's plane, not its
--- position (a "look at" billboard near the screen edge tilts and a row fans). Roll is excluded: the quad pitches but never leans.
--- Computed once per frame in client/world_quad.lua (the /me bubbles use it too).
local billboardBasis = WorldQuad.billboardBasis

--- The prompts that want a label this score frame, nearest first: one reused list.
local wantRows = {}
local function nearerFirst(a, b) return (a.dist or 0) < (b.dist or 0) end

--- Draw one frame; called every frame while anything is visible. The second and third (the state changes and the ids
--- that left: interact_nui.lua's) are not needed here: this draws from `visible`.
---@param visible table        [id] = entry, everything in range this frame
---@param isScoreFrame boolean whether the caller scored this frame
---@param camPos vector3|nil  the camera's position, when read this frame
---@param cfx number|nil @param cfy number|nil @param cfz number|nil  the camera's forward, likewise
---@param passNow number|nil  GetGameTimer, as the caller read it this frame
function R.frame(visible, _, _, isScoreFrame, camPos, cfx, cfy, cfz, passNow)
    if not attached then return end

    updateBadgeSize()

    local cfg = Config.Interact3D or {}
    -- Decomposed once per frame; the scoring pass's reading when it made one.
    local camV = camPos or GetFinalRenderedCamCoord()
    local camX, camY, camZ = camV.x, camV.y, camV.z

    -- One orientation for every billboard (billboardBasis); signs (with a heading) work it out per prompt.
    local brx, bry, brz, bux, buy, buz = billboardBasis(cfx, cfy, cfz)

    -- The range badgeM and labelM were derived for; a prompt with its own range is rescaled against it (f.sizeScale). Guarded against zero (a divisor).
    local defaultActive = Config.InteractActiveRange or 2.0
    if defaultActive <= 0.0 then defaultActive = 2.0 end

    local bM = badgeM or 0.06
    -- Height from config, width from the atlas row's proportions (LABEL_W x LABEL_ROW_H texels) so the text does not stretch.
    local labelH = labelM or 0.045
    local labelW = labelH * (LABEL_W / LABEL_ROW_H)

    -- A prompt's look and timing are its style's, set below. This is the fallback for a prompt not yet scored and for one without a style.
    local defaultSt = InteractStyle.of(nil, nil)

    -- The player (or server) changed shape or went dark: the renderer's own atlas is redrawn. One compare a frame.
    if defaultSt.look ~= currentBase then
        currentBase = defaultSt.look
        if badgePage then badgePage:send(badgeSetup(currentBase), 'setup') end
    end

    -- The key to show where a prompt says 'E': the player's Interact binding, or A on a pad (Interactions.keyLabel).
    local liveE = Interactions.keyLabel()

    -- The label belongs to the focused prompt only; everything else in range stays a brighter ring. The row cap stays.
    -- Advance the animation every frame, not just score frames; the fx table keeps a departed prompt until its fade-out finishes.
    local dt = GetFrameTime()
    if dt <= 0.0 then dt = 1.0 / 60.0 end
    -- The clock a style's animations run on, in ms.
    local now = passNow or GetGameTimer()

    -- Mark everything gone, then un-mark what is still here; what stays marked fades out on its old position and art.
    for _, f in pairs(fx) do f.alive = false end

    for id, e in pairs(visible) do
        local f = fx[id]
        local arriving = false
        if not f then
            -- Arriving: starts invisible so it fades up. `bornAt` starts a style's appear animation; `phase` offsets an idle
            -- one by position so a row of bobbing prompts does not move as one.
            f = { a = 0.0, state = stateOf(e.focused, e.active), prev = nil, blend = 1.0,
                  labelA = 0.0, stackA = 0.0, imageA = 0.0, holdA = 0.0, slide = e.sel or 1,
                  bornAt = now, phase = ((e.x or 0.0) * 1.7 + (e.y or 0.0)) % TAU }
            fx[id] = f
            arriving = true
        end
        f.alive = true
        f.x, f.y, f.z = e.x, e.y, e.z
        f.pull = e.pull   -- its own pull toward the camera, if it has one (below)
        f.wrap = e.wrap   -- a sign wrapped round a box (foldQuad, above)
        f.centre = e.centre   -- its circle and words centred on its point (below)
        f.fit = e.fit         -- the box it stays inside (below)
        f.heading, f.icon, f.dist, f.label = e.heading, e.icon, e.dist, e.label
        f.tilt = e.tilt   -- a sign leaning back (a garage door swung up): signOrientation
        -- Its style, kept on the fx so a departed prompt fades out at its own pace.
        f.st = e.style or defaultSt
        f.pressAt = e.pressAt
        -- A hold to use (holdMs): how far through it is, and when one last finished.
        f.holdP, f.holdDoneAt = e.holdP, e.holdDoneAt
        if e.holdP then f.holdShown = e.holdP end

        -- Sized at the range the prompt is read from: badgeM is derived for Config.InteractActiveRange and pxToMetres is linear in
        -- range, so the ratio keeps every prompt badgePx tall when it becomes usable. sizeRange, not activeRange (setRange can widen
        -- it). `scale` makes a family of prompts bigger.
        f.sizeScale = ((e.sizeRange or defaultActive) / defaultActive) * (e.scale or 1.0)
        f.flashAt, f.flashR, f.flashG, f.flashB = e.flashAt, e.flashR, e.flashG, e.flashB
        f.image = e.image
        -- A picture only for the focused prompt: there is one preview browser.
        f.wantImage = (e.focused and e.image and e.image ~= '') and true or false

        f.wantLabel = (e.focused and e.label and e.label ~= '') and true or false
        f.targetA = targetAlpha(f.st, e.focused, e.active)
        -- A style's `appear = 'none'`: there at once (leaving still fades).
        if arriving and f.st.appear == 'none' then f.a = f.targetA end

        -- The stack. `optIcons` is shared by reference (rebuilt in place).
        f.availN    = e.availN or 1
        f.sel       = e.sel or 1
        f.optIcons  = e.optIcons
        f.optLabels = e.optLabels

        -- Which row the label quad samples, chosen every frame (rows are allocated on score frames): the selected option's
        -- slot in the window (ensureRow), (n - 1) % slots + 1. A UV change, so instant.
        local held, slots = f._rows, f._slots
        if held and slots and slots > 0 then
            local sel = f.sel
            if sel < 1 then sel = 1 end
            f._row = held[(sel - 1) % slots + 1]
        end

        -- Only the focused prompt stacks; everything else in range is a plain ring.
        f.wantStack = (e.focused and (e.availN or 1) > 1) and true or false

        local want = stateOf(e.focused, e.active)
        if want ~= f.state then
            -- A crossfade: the outgoing cell is drawn under the incoming one, opacities summing to the prompt's, until the blend completes.
            f.prev = f.state
            f.state = want
            f.blend = 0.0
            -- A timed easing remembers where it started: this one restarts from 0.
            f.blendTo = nil
            -- A style's `focus` animation runs from the moment the prompt becomes the one E acts on.
            if want == 2 then f.focusAt = now end
        end
    end

    -- Rows follow the fx, not `visible`, so a label fades out with its prompt. Recomputed on score frames only.
    -- The preview: sent only when it changes (one string compare), every frame because the selection moves every frame.
    local wantImage = nil
    for _, f in pairs(fx) do
        if f.alive and f.wantImage then wantImage = f.image; break end
    end
    if wantImage ~= previewSrc then
        previewSrc = wantImage
        if previewPage then previewPage:send({ image = wantImage or '' }, 'image') end
    end

    if isScoreFrame then
        for id, f in pairs(fx) do
            if f.alive and f.wantLabel then
                f.id = id
                wantRows[#wantRows + 1] = f
            end
        end
        table.sort(wantRows, nearerFirst)

        -- Released only once the label has faded, so a swap between prompts reads as a handover.
        for id, f in pairs(fx) do
            -- `_rows`, not `_row`: a prompt holds a set of rows, and `_row` is only the selected one.
            if f._rows and not (f.wantLabel and f.alive) and (f.labelA or 0) <= 0.02 then
                f.id = id
                releaseRow(f)
            end
        end

        for i = 1, #wantRows do
            ensureRow(wantRows[i])
        end
        for i = #wantRows, 1, -1 do wantRows[i] = nil end
    end

    local maxBias = cfg.depthBias or 0.30

    for id, e in pairs(fx) do
        -- Each movement (fading, the option-stack slide, the ring turning into the key) has its own speed and easing from the style;
        -- 'default' gives all three Config.Interact3D.fadeMs and 'smooth'.
        local st = e.st or defaultSt
        local fade, fe = st.fade, st.fadeEase
        tween(e, K_A, e.alive and e.targetA or 0.0, dt, fade, fe)
        tween(e, K_LABEL, (e.alive and e.wantLabel) and 1.0 or 0.0, dt, fade, fe)
        tween(e, K_IMAGE, (e.alive and e.wantImage) and 1.0 or 0.0, dt, fade, fe)
        tween(e, K_STACK, (e.alive and e.wantStack) and 1.0 or 0.0, dt, fade, fe)
        -- The hold ring comes in with a hold and goes when it ends.
        tween(e, K_HOLD, (e.alive and e.holdP) and 1.0 or 0.0, dt, fade, fe)

        -- The slide, seeded to the current selection so a prompt arriving on its second option does not slide in from the top.
        if not e.slide then e.slide = e.sel or 1 end
        tween(e, K_SLIDE, e.sel or 1, dt, st.slide, st.slideEase)
        if e.blend < 1.0 then
            tween(e, K_BLEND, 1.0, dt, st.crossfade, st.crossfadeEase)
            if e.blend > 0.995 then e.blend = 1.0; e.prev = nil end
        end

        -- Faded out: release what it holds and forget it.
        if not e.alive and e.a <= 0.004 then
            e.id = id
            releaseRow(e)
            fx[id] = nil
            goto nextFx
        end

        local rx, ry, rz, ux, uy, uz
        if e.heading then
            rx, ry, rz, ux, uy, uz = signOrientation(e, camX, camY, camZ)
        else
            rx, ry, rz, ux, uy, uz = brx, bry, brz, bux, buy, buz
        end

        -- Wrapped round a box: only a sign can be, and only while this one draws.
        wrapNow = (rx and e.heading and e.wrap) or nil

        if rx then
            local a = byte(e.a)

            -- A style's animations: three numbers, at rest for 'default' (skipped unless st.animated): a size for the whole
            -- prompt (appear 'pop'), a size for the circle alone (focus, idle, press; the layout keeps its resting size so the
            -- label does not jump), and a lift in circle heights (appear 'slide', idle 'bob').
            local animAll, animBadge, lift = 1.0, 1.0, 0.0
            -- A finished hold pops, whatever the style.
            if e.holdDoneAt then
                local p = (now - e.holdDoneAt) / 220.0
                if p >= 0.0 and p < 1.0 then animBadge = 1.0 + 0.24 * math.sin(math.pi * p) end
            end
            if st.animated then
                if st.appear == 'pop' or st.appear == 'slide' then
                    local p = st.appearS > 0 and (now - (e.bornAt or now)) / (st.appearS * 1000.0) or 1.0
                    if p < 1.0 then
                        if st.appear == 'pop' then animAll = 0.6 + 0.4 * EASE.back(p)
                        else lift = -(1.0 - EASE.out(p)) * 0.6 end
                    end
                end
                if e.state == 2 then
                    if st.focusAnim == 'pop' and e.focusAt then
                        local p = (now - e.focusAt) / 220.0
                        if p < 1.0 then animBadge = animBadge * (1.0 + 0.16 * math.sin(math.pi * p)) end
                    elseif st.focusAnim == 'pulse' then
                        animBadge = animBadge * (1.0 + 0.05 * math.sin(now * (TAU / 1200.0)))
                    end
                elseif st.idle == 'pulse' then
                    animBadge = animBadge * (1.0 + 0.07 * math.sin(now * (TAU / 1600.0) + (e.phase or 0.0)))
                elseif st.idle == 'bob' then
                    lift = lift + 0.12 * math.sin(now * (TAU / 2000.0) + (e.phase or 0.0))
                end
                if st.press == 'pop' and e.pressAt then
                    local p = (now - e.pressAt) / 200.0
                    if p >= 0.0 and p < 1.0 then animBadge = animBadge * (1.0 + 0.22 * math.sin(math.pi * p)) end
                end
            end

            -- Floating it off the thing it labels: a prompt at the object's position is occluded by it, so it is pulled toward
            -- the camera along the view ray (same pixel, in front, scaled so its screen size is unchanged). The bias is a fraction
            -- of the distance, so a prompt round a corner stays behind the corner.
            local dx, dy, dz = camX - e.x, camY - e.y, camZ - e.z
            local dist = math.sqrt(dx * dx + dy * dy + dz * dz)

            -- A prompt with its own pull (Interactions.register `pull`) gets exactly that (a prop's middle: as much as the prop is
            -- deep, up to most of the way to the camera where the usual cap is half); a sign wrapped round a box, none.
            local bias, shrink = 0.0, 1.0
            if dist > 0.05 then
                if e.pull then
                    bias = math.min(e.pull, dist * 0.85)
                else
                    bias = math.min(maxBias, dist * 0.5)
                end
                shrink = (dist - bias) / dist
            end

            local inv = bias / math.max(dist, 0.0001)
            local cx, cy, cz = e.x + dx * inv, e.y + dy * inv, e.z + dz * inv

            -- Everything in the quad's plane shrinks together (including the prompt's size scale) or badge and label drift apart.
            -- A style sizes the two apart (badgeScale, labelScale) safely: the label hangs from the badge's edge (bMs).
            local sc      = (e.sizeScale or 1.0) * shrink * animAll
            local bMs     = bM * sc * st.badgeScale
            local gapMs   = bMs * st.gap
            local ls      = sc * st.labelScale
            local labelWs = labelW * ls
            local labelHs = labelH * ls
            -- The circle as drawn: its resting size (bMs) times a focus, idle or press animation.
            local bDraw   = bMs * animBadge

            -- The lift moves the whole prompt up its own `up`, in circle heights.
            if lift ~= 0.0 then
                local l = lift * bMs
                cx, cy, cz = cx + ux * l, cy + uy * l, cz + uz * l
            end

            -- Centred on its point (`centre`): circle and words together. The prompt slides back along its right by half of what the
            -- words add, times how far they have faded in. Uses the widest words, not the selected option's, so circles stay in one column.
            if e.centre and e._row and (e.labelA or 0.0) > 0.004 and e.label and e.label ~= '' then
                local px = wordsPx(e.label, e.st)
                local labels = e.optLabels
                if labels then
                    for k = 1, #labels do
                        local t = labels[k]
                        if t and t ~= '' then
                            local w = wordsPx(t, e.st)
                            if w > px then px = w end
                        end
                    end
                end
                local wordsEnd = bMs * 0.5 + gapMs + labelWs * (LABEL_PAD + px) / LABEL_W
                local shift = (wordsEnd - bMs * BADGE_DISC_FRAC * 0.5) * 0.5 * e.labelA
                cx, cy, cz = cx - rx * shift, cy - ry * shift, cz - rz * shift
            end

            -- Kept inside a box (a follow's `fit`): the point is the box's left edge, the circle's left edge stands on it and the
            -- words run right. Words that would pass the right edge are set smaller (wordSize). Nothing moves sideways.
            local fit = e.fit
            local wordSize = 1.0
            if fit then
                local disc = bMs * BADGE_DISC_FRAC * 0.5
                cx, cy, cz = cx + rx * disc, cy + ry * disc, cz + rz * disc
                if (e.labelA or 0.0) > 0.004 and e.label and e.label ~= '' then
                    local room = fit.width - disc - (bMs * 0.5 + gapMs)
                    local words = labelWs * (LABEL_PAD + wordsPx(e.label, e.st)) / LABEL_W
                    if room > 0.0 and words > room then wordSize = room / words end
                end
            end

            -- The carousel: the selected option always sits at the anchor and the list slides through it. `slide` is a float
            -- easing toward the selected index; slot k sits at (k - slide).
            local step = bMs * (1.0 + st.stackGap)
            local slide = e.slide or e.sel or 1
            local pslot = (e.sel or 1) - slide
            local poff = -pslot * step
            local pcx, pcy, pcz = cx + ux * poff, cy + uy * poff, cz + uz * poff

            -- Badge: the key picks the column, the state the row (no repaint). 'E' is drawn as the player's actual key (liveE).
            local icon = e.icon
            if icon == 'E' or icon == nil then icon = liveE end
            local col = columnForKey(icon)
            local u0 = col / BADGE_COLS
            local u1 = (col + 1) / BADGE_COLS

            -- Mid-crossfade both cells are drawn, coplanar (no z-fighting). Written out twice to avoid a closure per prompt per frame.
            --
            -- (Held under 255: a 'back' crossfade overshoots 1.)
            local outA = (e.prev and e.blend < 1.0) and math.floor(a * (1.0 - e.blend) + 0.5) or 0
            local inA  = (e.prev and e.blend < 1.0) and math.min(255, math.floor(a * e.blend + 0.5)) or a

            -- The flash tints the badge only; the label keeps its own colour (a green word is harder to read).
            local tr, tg, tb = flashTint(e, st)

            -- At bDraw (the circle's size with animation); everything around it keeps the resting size (bMs). From the style's atlas (themeTxd).
            local btxd = themeTxd(st.look)
            if outA >= 1 then
                local s = e.prev
                drawQuad(btxd, TEX_BADGE, pcx, pcy, pcz, rx, ry, rz, ux, uy, uz, bDraw, bDraw,
                         u0, s / BADGE_STATES, u1, (s + 1) / BADGE_STATES, outA, tr, tg, tb)
            end
            if inA >= 1 then
                local s = e.state
                drawQuad(btxd, TEX_BADGE, pcx, pcy, pcz, rx, ry, rz, ux, uy, uz, bDraw, bDraw,
                         u0, s / BADGE_STATES, u1, (s + 1) / BADGE_STATES, inA, tr, tg, tb)
            end

            -- The hold ring (holdMs): just outside the disc, in the cell's margin, so it reads as the rim filling. In the style's
            -- tint; on a dark prompt black over a white track.
            if (e.holdA or 0.0) > 0.004 and e.holdShown then
                local ra = math.min(255, math.floor(a * e.holdA + 0.5))
                if ra >= 1 then
                    local thick = bMs * 0.07
                    local half = bDraw * BADGE_DISC_FRAC * 0.5 + thick * 0.9
                    -- The square prompt's corners: badge.html's 26% of the disc, grown by the gap.
                    local corner = (st.theme == 'keycap') and (bDraw * BADGE_DISC_FRAC * 0.26 + thick * 0.9) or nil
                    local hr, hg, hb = tr, tg, tb
                    if st.darkShape then hr, hg, hb = 10, 12, 18 end
                    drawHoldRing(pcx, pcy, pcz, rx, ry, rz, ux, uy, uz, half, corner, thick,
                                 e.holdShown, ra, hr, hg, hb, st.darkShape)
                end
            end

            -- The unselected options: drawn from the focused row of the atlas (the only row with a glyph), dimmed by alpha alone.
            -- `stackA` fades the whole stack with focus.
            if e.stackA and e.stackA > 0.004 and e.optIcons and (e.availN or 1) > 1 then
                local sa = math.min(255, math.floor(a * st.stackAlpha * e.stackA + 0.5))
                if sa >= 1 then
                    local sel = e.sel or 1
                    for k = 1, e.availN do
                        -- The selected one is the primary badge above; drawing it again would double its opacity.
                        if k ~= sel then
                            local koff = -(k - slide) * step
                            -- Outside the rows of its box (`fit`): fades out over half a row as it scrolls past.
                            local ka = sa
                            if fit then
                                local rowsUp = koff / step
                                local past = math.max(rowsUp - fit.above, -fit.below - rowsUp, 0.0)
                                ka = math.floor(sa * math.max(0.0, 1.0 - past * 2.0) + 0.5)
                            end
                            if ka >= 1 then
                                local kicon = e.optIcons[k]
                                if kicon == 'E' or kicon == nil then kicon = liveE end
                                local kcol = columnForKey(kicon)
                                drawQuad(btxd, TEX_BADGE,
                                         cx + ux * koff, cy + uy * koff, cz + uz * koff,
                                         rx, ry, rz, ux, uy, uz, bMs, bMs,
                                         kcol / BADGE_COLS, 2 / BADGE_STATES,
                                         (kcol + 1) / BADGE_COLS, 3 / BADGE_STATES,
                                         ka, tr, tg, tb)
                            end
                        end
                    end
                end
            end

            -- Label, offset along `right` to hang off the badge's edge (the badge stays on the world point). Hung off the
            -- selected badge (pcx) so it rides the slide. Its own alpha (focus) times the prompt's.
            if e._row and e.labelA > 0.004 then
                local la = math.min(255, math.floor(a * e.labelA + 0.5))
                if la >= 1 then
                    local lw, lh = labelWs * wordSize, labelHs * wordSize
                    local offset = (bMs * 0.5) + gapMs + (lw * 0.5)
                    local lv0 = (e._row - 1) / #rows
                    local lv1 = e._row / #rows
                    -- The style's label colour (the text is drawn white, so it multiplies straight through).
                    drawQuad(TXD_LABEL, TEX_LABEL,
                             pcx + rx * offset, pcy + ry * offset, pcz + rz * offset,
                             rx, ry, rz, ux, uy, uz, lw, lh,
                             0.0, lv0, 1.0, lv1, la, st.labelR, st.labelG, st.labelB)
                end
            end

            -- The picture above the text: aligned to where the text starts (the quad's left edge), since a row is
            -- 1024x96 texels with the words left-aligned.
            if e.imageA and e.imageA > 0.004 and e.image then
                local ia = math.min(255, math.floor(a * e.imageA + 0.5))
                if ia >= 1 then
                    -- Sized off the label, not the badge, so it scales with its text.
                    local imgH = labelHs * st.previewScale
                    local imgW = imgH * (PREVIEW_W / PREVIEW_H)

                    local leftEdge = (bMs * 0.5) + gapMs
                    -- Half the picture's width back, so its left edge lands on the text's.
                    local across = leftEdge + (imgW * 0.5)
                    -- Clear of the text by half of each, plus a gap proportional to the text.
                    local up = (labelHs * 0.5) + (imgH * 0.5) + (labelHs * 0.35)

                    drawQuad(TXD_PREVIEW, TEX_PREVIEW,
                             pcx + rx * across + ux * up,
                             pcy + ry * across + uy * up,
                             pcz + rz * across + uz * up,
                             rx, ry, rz, ux, uy, uz, imgW, imgH,
                             0.0, 0.0, 1.0, 1.0, ia, 255, 255, 255)
                end
            end
        end
        wrapNow = nil

        ::nextFx::
    end
end

-- Sign in to the registry (client/interact.lua, loaded before this file).
InteractRenderers.world = R
