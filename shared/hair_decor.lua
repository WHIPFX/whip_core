-- ============================================
-- HAIR DECORATIONS — the scalp decoration GTA Online puts under each freemode haircut (HairDecor)
-- ============================================
--
-- GTA Online draws a decoration (a "hair overlay", put on as a tattoo is) under most haircuts so the
-- hair blends into the scalp; set the hair component alone and the cut looks "glued on". This maps
-- each base-game hair drawable to the decoration GTA Online uses for it.
-- Source: https://forum.cfx.re/t/how-to-implement-your-original-freemode-ped-haircuts-correctly/4794727
-- (CritteR's table, with the corrections from post #12, found with GET_SHOP_PED_APPAREL_FORCED_COMPONENT_COUNT /
-- GET_FORCED_COMPONENT).
--
-- client/appearance.lua (applyTattoos) puts it on when the character has no hair fade of their own
-- (`hairFade`, shared/hair_fades.lua); a chosen fade takes its place. It is never saved: it follows the cut.
--
-- byBody[body][drawable] = { collection, overlay }, or false for "no decoration" (a bald head, say).
-- A drawable not listed (a newer DLC cut: Enhanced has many past 78 / 82) is looked up in the game's own
-- shop data (client/appearance.lua, hairDecorFor), and failing that gets `fallback`, the generic fuzz; set
-- HairDecor.fallback = nil to give those nothing.
-- Data and one lookup only.

HairDecor = {
    fallback = { 'mpBeach_overlays', 'FM_Hair_Fuzz' },
    byBody = {
        m = {
            [0]  = false,
            [1]  = { 'multiplayer_overlays', 'NG_M_Hair_001' },
            [2]  = { 'multiplayer_overlays', 'NG_M_Hair_002' },
            [3]  = { 'multiplayer_overlays', 'NG_M_Hair_003' },
            [4]  = { 'multiplayer_overlays', 'NG_M_Hair_004' },
            [5]  = { 'multiplayer_overlays', 'NG_M_Hair_005' },
            [6]  = { 'multiplayer_overlays', 'NG_M_Hair_006' },
            [7]  = { 'multiplayer_overlays', 'NG_M_Hair_007' },
            [8]  = { 'multiplayer_overlays', 'NG_M_Hair_008' },
            [9]  = { 'multiplayer_overlays', 'NG_M_Hair_009' },
            [10] = { 'multiplayer_overlays', 'NG_M_Hair_010' },
            [11] = { 'multiplayer_overlays', 'NG_M_Hair_011' },
            [12] = { 'multiplayer_overlays', 'NG_M_Hair_012' },
            [13] = { 'multiplayer_overlays', 'NG_M_Hair_013' },
            [14] = { 'multiplayer_overlays', 'NG_M_Hair_014' },
            [15] = { 'multiplayer_overlays', 'NG_M_Hair_015' },
            [16] = { 'multiplayer_overlays', 'NGBea_M_Hair_000' },
            [17] = { 'multiplayer_overlays', 'NGBea_M_Hair_001' },
            [18] = { 'mpBusiness_overlays', 'FM_Bus_M_Hair_000_a' },
            [19] = { 'mpBusiness_overlays', 'FM_Bus_M_Hair_001_a' },
            [20] = { 'mpHipster_overlays', 'FM_Hip_M_Hair_000_a' },
            [21] = { 'mpHipster_overlays', 'FM_Hip_M_Hair_001_a' },
            [22] = { 'multiplayer_overlays', 'NGInd_M_Hair_000' },
            -- 23: not a shop haircut (no decoration known; gets the fallback)
            [24] = { 'mpLowrider_overlays', 'LR_M_Hair_000' },
            [25] = { 'mpLowrider_overlays', 'LR_M_Hair_001' },
            [26] = { 'mpLowrider_overlays', 'LR_M_Hair_002' },
            [27] = { 'mpLowrider_overlays', 'LR_M_Hair_003' },
            [28] = { 'mpLowrider2_overlays', 'LR_M_Hair_004' },
            [29] = { 'mpLowrider2_overlays', 'LR_M_Hair_005' },
            [30] = { 'mpLowrider2_overlays', 'LR_M_Hair_006' },
            [31] = { 'mpBiker_overlays', 'MP_Biker_Hair_000_M' },
            [32] = { 'mpBiker_overlays', 'MP_Biker_Hair_001_M' },
            [33] = { 'mpBiker_overlays', 'MP_Biker_Hair_002_M' },
            [34] = { 'mpBiker_overlays', 'MP_Biker_Hair_003_M' },
            [35] = { 'mpBiker_overlays', 'MP_Biker_Hair_004_M' },
            [36] = { 'mpBiker_overlays', 'MP_Biker_Hair_005_M' },
            -- 37-71: the same cuts again (filled in below)
            [72] = { 'mpGunrunning_overlays', 'MP_Gunrunning_Hair_M_000_M' },
            [73] = { 'mpGunrunning_overlays', 'MP_Gunrunning_Hair_M_001_M' },
            [74] = { 'mpVinewood_overlays', 'MP_Vinewood_Hair_M_000_M' },
            [75] = { 'mpTuner_overlays', 'MP_Tuner_Hair_001_M' },
            [76] = { 'mpSecurity_overlays', 'MP_Security_Hair_001_M' },
            [77] = { 'mpSum2_overlays', 'MP_Sum2_Hair_000_M' },
            [78] = { 'mpSum2_overlays', 'MP_Sum2_Hair_002_M' },
        },
        f = {
            [0]  = false,
            [1]  = { 'multiplayer_overlays', 'NG_F_Hair_001' },
            [2]  = { 'multiplayer_overlays', 'NG_F_Hair_002' },
            [3]  = { 'multiplayer_overlays', 'NG_F_Hair_003' },
            [4]  = { 'multiplayer_overlays', 'NG_F_Hair_004' },
            [5]  = { 'multiplayer_overlays', 'NG_F_Hair_005' },
            [6]  = { 'multiplayer_overlays', 'NG_F_Hair_006' },
            [7]  = { 'multiplayer_overlays', 'NG_F_Hair_007' },
            [8]  = { 'multiplayer_overlays', 'NG_F_Hair_008' },
            [9]  = { 'multiplayer_overlays', 'NG_F_Hair_009' },
            [10] = { 'multiplayer_overlays', 'NG_F_Hair_010' },
            [11] = { 'multiplayer_overlays', 'NG_F_Hair_011' },
            [12] = { 'multiplayer_overlays', 'NG_F_Hair_012' },
            [13] = { 'multiplayer_overlays', 'NG_F_Hair_013' },
            [14] = { 'multiplayer_overlays', 'NG_F_Hair_014' },
            [15] = { 'multiplayer_overlays', 'NG_F_Hair_015' },
            [16] = { 'mpHipster_overlays', 'FM_F_Hair_017_a' },
            [17] = { 'mpHipster_overlays', 'FM_F_Hair_017_a' },
            [18] = { 'mpBusiness_overlays', 'FM_Bus_F_Hair_b' },
            [19] = { 'mpBusiness_overlays', 'FM_Bus_F_Hair_b' },
            [20] = { 'mpHipster_overlays', 'FM_F_Hair_020_a' },
            [21] = { 'multiplayer_overlays', 'NGBea_F_Hair_001' },
            [22] = { 'mpHipster_overlays', 'FM_Hip_F_Hair_000_a' },
            [23] = { 'multiplayer_overlays', 'NGInd_F_Hair_000' },
            -- 24: not a shop haircut (no decoration known; gets the fallback)
            [25] = { 'mpLowrider_overlays', 'LR_F_Hair_000' },
            [26] = { 'mpLowrider_overlays', 'LR_F_Hair_001' },
            [27] = { 'mpLowrider_overlays', 'LR_F_Hair_002' },
            [28] = { 'mpLowrider2_overlays', 'LR_F_Hair_003' },
            [29] = { 'mpLowrider2_overlays', 'LR_F_Hair_003' },
            [30] = { 'mpLowrider2_overlays', 'LR_F_Hair_004' },
            [31] = { 'mpLowrider2_overlays', 'LR_F_Hair_006' },
            [32] = { 'mpBiker_overlays', 'MP_Biker_Hair_000_F' },
            [33] = { 'mpBiker_overlays', 'MP_Biker_Hair_001_F' },
            [34] = { 'mpBiker_overlays', 'MP_Biker_Hair_002_F' },
            [35] = { 'mpBiker_overlays', 'MP_Biker_Hair_003_F' },
            [36] = { 'multiplayer_overlays', 'NG_F_Hair_014' },
            [37] = { 'mpBiker_overlays', 'MP_Biker_Hair_006_F' },
            [38] = { 'mpBiker_overlays', 'MP_Biker_Hair_005_F' },
            -- 39-75: the same cuts again (filled in below)
            [76] = { 'mpGunrunning_overlays', 'MP_Gunrunning_Hair_F_000_F' },
            [77] = { 'mpGunrunning_overlays', 'MP_Gunrunning_Hair_F_001_F' },
            [78] = { 'mpVinewood_overlays', 'MP_Vinewood_Hair_F_000_F' },
            [79] = { 'mpTuner_overlays', 'MP_Tuner_Hair_000_F' },
            [80] = { 'mpSecurity_overlays', 'MP_Security_Hair_000_F' },
            [81] = { 'mpSum2_overlays', 'MP_Sum2_Hair_001_F' },
            [82] = { 'mpSum2_overlays', 'MP_Sum2_Hair_003_F' },
        },
    },
}

-- The second copy of the base cuts (the game lists them twice; the non-shop cut is not repeated, so the
-- offset drops by one after it): male 1-22 -> 37-58, 24-36 -> 59-71; female 1-23 -> 39-61, 25-38 -> 62-75.
-- GTA Online's barber sets some of the copies wrong (post #12); the first copy's decoration is the right one.
do
    local function mirror(t, from, to, offset)
        for d = from, to do
            if t[d] ~= nil and t[d + offset] == nil then t[d + offset] = t[d] end
        end
    end
    local m, f = HairDecor.byBody.m, HairDecor.byBody.f
    mirror(m, 1, 22, 36); mirror(m, 24, 36, 35)
    mirror(f, 1, 23, 38); mirror(f, 25, 38, 37)
end

--- This table's entry for a haircut.
---@param body string    'm' | 'f'
---@param drawable number the hair component's drawable
---@return table|false|nil  { collection, overlay }; false: no decoration; nil: not listed (ask the game, then `fallback`)
function HairDecor.listed(body, drawable)
    local t = HairDecor.byBody[body]
    if not t then return nil end
    return t[tonumber(drawable) or -1]
end
