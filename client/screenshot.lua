-- Screenshots: the game's picture, read once when asked by whip_core's own page (html/js/screenshot.js), not
-- screenshot-basic (which drew a texture every frame and halved Enhanced's frame rate). Whip's interface is not in the
-- picture unless opts.ui (html/js/page-picture.js; other resources' pages such as the phone are never included).
--
--   local data, why = exports.whip_core:TakeScreenshot({ format = 'png' })   -- yields; a data URL, or false + why
--
-- opts: format 'jpg' (default) | 'png' | 'webp'; quality 0-1 (jpg/webp, 0.92); width / height (the screen's size by
-- default; one given keeps the screen's shape); ui = true: with whip's interface (under a second longer);
-- frames (2 to 24) and every (ms, 33 to 1000): a burst read into one numbered grid (640 wide a frame, no ui);
-- upload = { url, field }: posted to that address as a file in a form, and the answer's text comes back instead.
--
-- The server asks with exports.whip_core:RequestScreenshot (server/screenshot.lua): the shot comes back to it only.

Screenshot = {}   -- whip_core's own files: Screenshot.take(opts) (the export is for other resources)

local WAIT_MS = 15000            -- for the page to answer one shot
local SEND_BPS = 1000000         -- a shot the server asked for goes back at this many bytes a second (a latent event)
local FORMATS = { jpg = true, jpeg = true, png = true, webp = true }

local _next = 0
local _waiting = {}   -- [id] = the promise of a shot someone still waits for (screen_probe.lua's way)

--- One shot. Yields. One given up on (WAIT_MS) is called off on the page too and its late answer is dropped.
---@param opts table|nil
---@param noUpload boolean|nil  the server's ask: never posted anywhere
---@return string|false data, string|nil why
local function take(opts, noUpload)
    opts = type(opts) == 'table' and opts or {}
    local fmt = type(opts.format) == 'string' and opts.format:lower() or 'jpg'
    if not FORMATS[fmt] then return false, 'format must be jpg, png or webp' end
    local upload = nil
    if not noUpload and type(opts.upload) == 'table' and type(opts.upload.url) == 'string' then
        upload = { url = opts.upload.url, field = type(opts.upload.field) == 'string' and opts.upload.field or 'file' }
    end
    local frames = math.max(1, math.min(24, math.floor(tonumber(opts.frames) or 1)))
    local every = math.max(33, math.min(1000, math.floor(tonumber(opts.every) or 100)))
    _next = _next + 1
    local id = _next
    local p = promise.new()
    _waiting[id] = p
    local waitMs = WAIT_MS + (frames > 1 and frames * every or 0)
    SendNUIMessage({
        action = 'screenshot', id = id, format = fmt, quality = tonumber(opts.quality),
        width = tonumber(opts.width), height = tonumber(opts.height), ui = opts.ui == true, upload = upload,
        frames = frames, every = every, waitMs = waitMs,
    })
    SetTimeout(waitMs, function()
        if _waiting[id] ~= p then return end
        _waiting[id] = nil
        SendNUIMessage({ action = 'screenshotCancel', id = id })   -- (still queued behind another: skipped)
        p:resolve(false)
    end)
    local a = Citizen.Await(p)
    if not a then return false, 'the page did not answer' end
    if not a.ok then return false, tostring(a.why or 'the shot failed') end
    return a.data
end

RegisterNUICallback('screenshotTaken', function(d, cb)
    cb({ ok = true })
    local id = type(d) == 'table' and tonumber(d.id) or nil
    local p = id and _waiting[id]
    if not (id and p) then return end   -- nobody waits for it any more (given up on): not kept
    _waiting[id] = nil
    p:resolve({ ok = d.ok == true, data = type(d.data) == 'string' and d.data or nil, why = d.why })
end)

---@param opts table|nil
---@return string|false data, string|nil why
function Screenshot.take(opts) return take(opts) end

exports('TakeScreenshot', function(opts) return take(opts) end)

--- The server's ask (RequestScreenshot): the shot goes back with the ask's number, slowly to not choke the connection.
RegisterNetEvent('whip_core:client:screenshot', function(reqId, opts)
    CreateThread(function()
        local data, why = take(opts, true)
        TriggerLatentServerEvent('whip_core:server:screenshot', SEND_BPS, reqId, data or '', data and '' or tostring(why))
    end)
end)
