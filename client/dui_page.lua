-- ============================================
-- DUI PAGES — whip_core's screens in the world, each one browser
-- ============================================
--
-- A DUI is a whole browser: a page under html/, loaded from this resource (never the internet), drawing into a texture
-- the game can sample. whip lays pieces of that texture in the world with WorldQuad (client/world_quad.lua), so they
-- depth-test and never lag the camera. Every DUI in whip_core is made here, so they all keep the same rules:
--
--   1. ONE BROWSER PER SYSTEM, never one per thing. The page is an atlas of cells and each thing on screen is a quad
--      drawn from its cell's UVs, so the browser count does not grow with what is on screen.
--   2. A CHANGE IS A UV SWAP OR A MESSAGE, never a new browser, and a message goes only when something changed.
--   3. MADE ON FIRST USE, GIVEN BACK WHEN IDLE. A browser renders and holds its texture whether or not anything draws
--      it. `idleMs` gives it back that long after it was last used; a page without one is kept until its owner gives
--      it back (page:release()) or whip_core stops.
--   4. A STILL PAGE. It animates only while something it shows is happening.
--
--   local page = DuiPage.new({
--       name   = 'directorspots',              -- for prints: [whip_core:directorspots]
--       url    = 'interact3d/zones.html',      -- under html/ (or a whole nui:// address); a function is asked each time
--       width  = 512, height = 1536,           -- numbers, or functions asked when it is made
--       txd    = 'whip_dzones', tex = 'zones', -- the runtime texture its quads draw from
--       idleMs = 60000,                        -- optional: given back this long after it was last used (a function:
--                                              -- asked each time; nil or 0 keeps it)
--       setup  = function() return {...} end,  -- optional: the page's setup, sent first once it is up
--       again  = { 500, 1500 },                -- optional: setup sent again this long after it is up (a page made
--                                              -- mid-game can miss its first message), then onAgain()
--       onAgain = fn, onGone = fn,             -- optional: after each resend / after the browser is given back
--       bootMs = 700,                          -- optional: not up before this long after it is made
--       assets = true,                         -- optional: the page shows media pack pictures (html/js/assets.js):
--                                              -- it is told where they come from before its setup, and on a change
--       without = 'spot markers will not draw',-- the refusal print's words; quiet = true prints nothing
--   })
--
--   page:ensure()       made now if it is not, and counts as used. false, why: the game refused it (asked once only).
--   page:used()         drawn from this frame: not given back for idleMs from now
--   page:up()           made, and the page is listening: a message goes straight in
--   page:send(msg, key) a table (sent as JSON) or a JSON string. Before the page is up it waits (a waiting message with
--                       the same `key` is replaced); with no browser it is dropped (whoever makes it again sends anew)
--   page:exists()       a browser is held
--   page:release()      given back now

DuiPage = {}

local Page = {}
Page.__index = Page

-- A page that never says it is available counts as up after this long.
local UP_WAIT_MS = 10000
local UP_POLL_MS = 50

--- [page] = true while it holds a browser: whip_core's stop gives every one back.
local live = {}

local function asked(v)
    if type(v) == 'function' then return v() end
    return v
end

local function urlOf(u)
    u = asked(u)
    if u:find('://', 1, true) then return u end
    return ('nui://%s/html/%s'):format(GetCurrentResourceName(), u)
end

local function sendNow(p, msg)
    if msg == nil or not p.dui then return end
    SendDuiMessage(p.dui, type(msg) == 'string' and msg or json.encode(msg))
end

--- Run one of the owner's hooks; a broken one is printed, never left to stop the page.
local function hook(p, fn, ...)
    if not fn then return nil end
    local ok, res = pcall(fn, ...)
    if not ok then
        print(('[whip_core:%s] %s'):format(p.name, tostring(res)))
        return nil
    end
    return res
end

local function idleOf(p)
    local ms = asked(p.opts.idleMs)
    return (type(ms) == 'number' and ms > 0) and ms or nil
end

--- The idle check: one timer for each browser, run again until it has been unused for idleMs.
local function armIdle(p)
    if not p.dui or p.idleGen == p.gen then return end
    local ms = idleOf(p)
    if not ms then return end
    local gen = p.gen
    p.idleGen = gen
    local function check()
        if p.idleGen ~= gen then return end
        local idle = idleOf(p)
        if not idle then
            p.idleGen = nil   -- (switched off since: kept; page:used() arms it again if it comes back)
            return
        end
        local left = p.lastUsed + idle - GetGameTimer()
        if left <= 0 then
            p:release()
        else
            SetTimeout(left, check)
        end
    end
    SetTimeout(ms, check)
end

--- Waits for the browser to be available (and bootMs), then sends the setup and whatever waited.
local function waitUp(p, gen)
    CreateThread(function()
        local deadline = GetGameTimer() + UP_WAIT_MS
        while p.gen == gen and not IsDuiAvailable(p.dui) and GetGameTimer() < deadline do Wait(UP_POLL_MS) end
        local boot = p.madeAt + (p.opts.bootMs or 0) - GetGameTimer()
        if boot > 0 then Wait(boot) end
        if p.gen ~= gen then return end
        p.isUp = true
        local o = p.opts
        if o.assets then sendNow(p, { action = 'whipAssetSources', sources = GlobalState.whipMedia }) end
        if o.setup then sendNow(p, hook(p, o.setup)) end
        local waiting = p.queue
        p.queue = {}
        for i = 1, #waiting do sendNow(p, waiting[i].msg) end
        for _, ms in ipairs(o.again or {}) do
            SetTimeout(ms, function()
                if p.gen ~= gen then return end
                if o.setup then sendNow(p, hook(p, o.setup)) end
                hook(p, o.onAgain)
            end)
        end
    end)
end

--- Tell every page made with `assets` where the media packs' pictures come from now (client/ready.lua, on a change of
--- GlobalState.whipMedia). One not up yet is told when it is.
---@param sources table|nil
function DuiPage.sendAssetSources(sources)
    for p in pairs(live) do
        if p.isUp and p.opts.assets then sendNow(p, { action = 'whipAssetSources', sources = sources }) end
    end
end

---@param opts table  see the header
function DuiPage.new(opts)
    return setmetatable({
        opts = opts, name = opts.name or 'dui', txd = opts.txd, tex = opts.tex,
        dui = nil, isUp = false, gen = 0, queue = {}, lastUsed = 0, madeAt = 0, idleGen = nil, failed = nil,
    }, Page)
end

---@return boolean made, string|nil why
function Page:ensure()
    self.lastUsed = GetGameTimer()
    if self.dui then
        if self.idleGen ~= self.gen then armIdle(self) end
        return true
    end
    if self.failed then return false, self.failed end
    local o = self.opts
    -- A browser bigger than the game allows throws ("Invalid Width [1, 8192]" on GTA V Enhanced): said to the owner,
    -- which can make a smaller one.
    local made, handle = pcall(CreateDui, urlOf(o.url), asked(o.width), asked(o.height))
    if not made or not handle then
        self.failed = tostring(handle or 'no browser')
        if not o.quiet then
            print(('[whip_core:%s] the game refused the browser, so %s: %s'):format(self.name,
                o.without or 'it will not draw', self.failed))
        end
        return false, self.failed
    end
    self.dui = handle
    self.gen = self.gen + 1
    self.isUp = false
    self.madeAt = GetGameTimer()
    live[self] = true
    -- Registering the same dictionary and texture name again after a browser was given back is fine.
    CreateRuntimeTextureFromDuiHandle(CreateRuntimeTxd(self.txd), self.tex, GetDuiHandle(handle))
    waitUp(self, self.gen)
    armIdle(self)
    return true
end

function Page:used()
    self.lastUsed = GetGameTimer()
    if self.dui and self.idleGen ~= self.gen then armIdle(self) end
end

function Page:up()
    return self.isUp
end

function Page:exists()
    return self.dui ~= nil
end

---@param msg table|string
---@param key any|nil
function Page:send(msg, key)
    if not self.dui or msg == nil then return end
    if self.isUp then
        sendNow(self, msg)
        return
    end
    local waiting = self.queue
    if key ~= nil then
        for i = 1, #waiting do
            if waiting[i].key == key then
                waiting[i].msg = msg
                return
            end
        end
    end
    waiting[#waiting + 1] = { key = key, msg = msg }
end

function Page:release()
    if not self.dui then return end
    local handle = self.dui
    self.dui, self.isUp, self.queue, self.idleGen = nil, false, {}, nil
    self.gen = self.gen + 1
    live[self] = nil
    pcall(DestroyDui, handle)
    hook(self, self.opts.onGone)
end

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for p in pairs(live) do p:release() end
end)
