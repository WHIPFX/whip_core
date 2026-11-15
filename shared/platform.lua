-- ============================================
-- GAME PLATFORM — FiveM on GTA V Legacy, or on GTA V Enhanced
-- ============================================
--
-- ONE WHIP RUNS ON BOTH. Almost all of it is the same; where the two differ (models built for each, the
-- minimap's file, voice), the code asks here, in one place, and does that platform's thing:
--
--     if GamePlatform.enhanced then ... end                 -- whip_core's own files
--     exports.whip_core:GetPlatform()  --> 'legacy' | 'enhanced'   -- any resource, either side
--
-- EACH SERVER SAYS WHICH IT IS, in its server.cfg (there is no way for a script to tell by itself):
--
--     setr whip_platform enhanced    -- the Enhanced server
--                                    -- the Legacy server: nothing (or setr whip_platform legacy)
--
-- setr, so players' games see it too (a replicated convar). The server also hands its value on itself,
-- which is enough on Legacy, but a `set` never reached the game on FiveM for GTAV Enhanced (20 Oct 2026).
-- /whipplatform, in a player's F8, says what their game read. Anything but legacy or enhanced reads as
-- legacy, with a warning when the server starts.

GamePlatform = {}

local raw = string.lower(GetConvar('whip_platform', 'legacy'))

GamePlatform.name = raw == 'enhanced' and 'enhanced' or 'legacy'
GamePlatform.enhanced = GamePlatform.name == 'enhanced'
GamePlatform.legacy = not GamePlatform.enhanced

if IsDuplicityVersion() then
    if raw ~= 'legacy' and raw ~= 'enhanced' then
        print(('^3[whip_core] whip_platform is "%s": read as legacy. Set it to legacy or enhanced in server.cfg^7'):format(raw))
    end
    -- So players' games read it even from a `set` (on Legacy; Enhanced needs the setr).
    SetConvarReplicated('whip_platform', GamePlatform.name)
else
    -- What this game read when whip started, and what it reads now. Both legacy on an Enhanced server:
    -- the value never arrived (server.cfg needs setr). Only the second right: it arrived after whip started.
    -- Developer mode only. (Not DevCommand: shared scripts load before client/dev_commands.lua.)
    RegisterCommand('whipplatform', function()
        if not (DevToolsOn and DevToolsOn()) then
            UI.Notify('/whipplatform is a developer tool: turn developer mode on in /w', 'error')
            return
        end
        print(('[whip_core] platform: %s when whip started; whip_platform reads "%s" now')
            :format(GamePlatform.name, GetConvar('whip_platform', '(not set)')))
    end, false)
end

--- 'legacy' or 'enhanced': which GTA V this server runs on (server.cfg's whip_platform).
exports('GetPlatform', function() return GamePlatform.name end)
