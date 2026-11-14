-- ============================================
-- Dev Tools — Interior Probe (server half)
-- ============================================
--
-- Writes a client's /propprobe report to whip_core/dev/probe/, so the numbers the Properties
-- rebuild depends on are on disk where they can be read and diffed, rather than in someone's F8
-- console. See tools/property_probe.lua for what a report contains.
--
-- INTO AN EXISTING FOLDER. SaveResourceFile is not guaranteed to create directories, which is why
-- dev/probe/ keeps a README in it.

local PROBE_DIR = 'dev/probe/'

SecureEvent('whip_core:server:propertyProbeSave', {
    ace       = 'whip.devtools',
    rateLimit = 2000,
    params = {
        {'label', 'string', 48},
        {'body',  'string', 2000000},
    },
}, function(source, _, label, body)
    -- A file name, not a path: lowercase letters, digits, dash and underscore only.
    local safe = label:lower():gsub('[^%w%-_]', '_'):sub(1, 48)
    if safe == '' then safe = 'interior' end

    -- Whose, in the name: two players probing together can save in the same second, and
    -- without it one file would take the other's name and write over it.
    local path = ('%s%s_%s_p%d.json'):format(PROBE_DIR, os.date('%Y%m%d_%H%M%S'), safe, tonumber(source) or 0)
    local ok = SaveResourceFile(GetCurrentResourceName(), path, body, #body)
    if not ok then
        print(('[whip_core:probe] SaveResourceFile FAILED for %s'):format(path))
        TriggerClientEvent('whip_core:client:propertyProbeSaved', source, false, 'disk write failed')
        return
    end

    print(('[whip_core:probe] %s saved %s (%d bytes)'):format(GetPlayerName(source) or source, path, #body))
    TriggerClientEvent('whip_core:client:propertyProbeSaved', source, true, path)
end)
