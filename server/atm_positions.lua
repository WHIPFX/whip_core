-- ============================================
-- ATM POSITIONS — server/atm_positions.lua (generated: do not edit by hand)
-- ============================================
--
-- Every cash machine GTA V places in its own map (prop_atm_01, prop_atm_02, prop_atm_03, prop_fleeca_atm), outdoors and
-- inside its interiors (an interior's machines turned and moved to where that interior stands), read from the game's
-- map files. The point is the machine's base, on the floor. 121 machines. Machines a map mod or an MLO adds are not here:
-- config.lua's Config.AtmExtraPositions adds them. Read by server/atm.lua (IsNearAtm, GetNearestAtm).

AtmPositions = {
    vector3(-3241.45, 997.91, 11.55),   -- prop_atm_03
    vector3(-3240.03, 1008.55, 11.83),   -- prop_atm_01 (interior)
    vector3(-3144.89, 1127.81, 19.84),   -- prop_atm_01
    vector3(-3043.83, 594.16, 6.73),   -- prop_atm_03
    vector3(-3040.20, 593.30, 6.91),   -- prop_atm_01 (interior)
    vector3(-2974.59, 380.13, 14.00),   -- prop_atm_03
    vector3(-2958.98, 487.31, 14.48),   -- prop_atm_03
    vector3(-2956.85, 487.22, 14.48),   -- prop_atm_03
    vector3(-2295.85, 357.93, 173.60),   -- prop_atm_02
    vector3(-2295.07, 356.26, 173.60),   -- prop_atm_02
    vector3(-2294.30, 354.61, 173.60),   -- prop_atm_02
    vector3(-2071.93, -317.29, 12.32),   -- prop_atm_02
    vector3(-1827.69, 784.47, 137.32),   -- prop_atm_01 (interior)
    vector3(-1570.77, -547.70, 33.93),   -- prop_atm_02
    vector3(-1569.84, -547.03, 33.93),   -- prop_atm_02
    vector3(-1430.66, -211.36, 45.47),   -- prop_atm_01
    vector3(-1415.48, -212.33, 45.50),   -- prop_atm_01
    vector3(-1410.74, -98.93, 51.40),   -- prop_atm_02
    vector3(-1410.18, -100.65, 51.40),   -- prop_atm_02
    vector3(-1391.34, -589.86, 29.32),   -- prop_atm_01 (interior)
    vector3(-1315.42, -834.43, 15.95),   -- prop_atm_03
    vector3(-1314.47, -835.69, 15.95),   -- prop_atm_03
    vector3(-1305.71, -706.69, 24.31),   -- prop_atm_02
    vector3(-1289.74, -227.16, 41.43),   -- prop_atm_01
    vector3(-1286.70, -213.78, 41.43),   -- prop_atm_01
    vector3(-1285.14, -223.94, 41.43),   -- prop_atm_01
    vector3(-1282.10, -210.56, 41.43),   -- prop_atm_01
    vector3(-1206.14, -325.03, 36.85),   -- prop_fleeca_atm
    vector3(-1205.38, -326.53, 36.85),   -- prop_fleeca_atm
    vector3(-1110.23, -1691.15, 3.38),   -- prop_atm_01
    vector3(-1091.89, 2709.05, 17.92),   -- prop_atm_01
    vector3(-1044.47, -2739.64, 8.12),   -- prop_atm_01
    vector3(-867.97, -186.34, 36.88),   -- prop_atm_03
    vector3(-867.01, -187.99, 36.88),   -- prop_atm_03
    vector3(-847.20, -340.43, 37.68),   -- prop_atm_02
    vector3(-846.65, -341.51, 37.67),   -- prop_atm_02
    vector3(-821.89, -1081.55, 10.14),   -- prop_atm_02
    vector3(-720.63, -415.52, 33.98),   -- prop_atm_02
    vector3(-718.26, -915.71, 18.22),   -- prop_atm_01 (interior)
    vector3(-712.94, -818.48, 22.74),   -- prop_atm_02
    vector3(-710.08, -818.48, 22.74),   -- prop_atm_02
    vector3(-660.68, -854.49, 23.46),   -- prop_atm_02
    vector3(-617.80, -708.86, 29.04),   -- prop_atm_03
    vector3(-617.80, -706.85, 29.04),   -- prop_atm_03
    vector3(-614.52, -705.60, 30.22),   -- prop_atm_03
    vector3(-611.86, -705.60, 30.22),   -- prop_atm_03
    vector3(-596.13, -1160.85, 21.33),   -- prop_atm_02
    vector3(-594.61, -1160.85, 21.33),   -- prop_atm_02
    vector3(-537.81, -854.94, 28.28),   -- prop_atm_03
    vector3(-526.78, -1223.37, 17.45),   -- prop_atm_03
    vector3(-386.46, 6046.41, 30.47),   -- prop_atm_02
    vector3(-303.23, -829.31, 31.42),   -- prop_atm_03
    vector3(-301.66, -829.59, 31.42),   -- prop_atm_03
    vector3(-282.71, 6226.43, 30.50),   -- prop_atm_02
    vector3(-273.37, -2024.21, 29.17),   -- prop_atm_02 (interior)
    vector3(-262.36, -2012.05, 29.17),   -- prop_atm_02 (interior)
    vector3(-259.28, -723.27, 32.70),   -- prop_atm_03
    vector3(-256.64, -715.89, 32.79),   -- prop_atm_03
    vector3(-254.52, -692.89, 32.58),   -- prop_atm_03
    vector3(-204.02, -861.01, 29.27),   -- prop_atm_03
    vector3(-165.58, 232.70, 93.93),   -- prop_atm_03
    vector3(-165.58, 234.77, 93.93),   -- prop_atm_03
    vector3(-132.67, 6366.88, 30.47),   -- prop_atm_02
    vector3(-97.64, 6455.73, 30.47),   -- prop_atm_02
    vector3(-95.87, 6457.46, 30.47),   -- prop_atm_02
    vector3(-57.40, -1751.75, 28.42),   -- prop_atm_01 (interior)
    vector3(-57.17, -92.38, 56.75),   -- prop_atm_01
    vector3(-30.10, -723.29, 43.22),   -- prop_atm_03
    vector3(-27.89, -724.11, 43.22),   -- prop_atm_03
    vector3(5.69, -919.96, 28.48),   -- prop_atm_02
    vector3(24.59, -945.54, 28.33),   -- prop_atm_02
    vector3(33.19, -1348.81, 28.50),   -- prop_atm_01 (interior)
    vector3(89.81, 2.88, 67.35),   -- prop_atm_03
    vector3(111.39, -774.84, 30.44),   -- prop_atm_03
    vector3(112.48, -819.81, 30.34),   -- prop_atm_03
    vector3(114.55, -775.97, 30.42),   -- prop_atm_03
    vector3(118.64, -883.57, 30.14),   -- prop_atm_03
    vector3(129.70, -1290.84, 28.27),   -- prop_atm_01 (interior)
    vector3(130.15, -1291.63, 28.27),   -- prop_atm_01 (interior)
    vector3(130.58, -1292.37, 28.27),   -- prop_atm_01 (interior)
    vector3(145.84, -1035.63, 28.37),   -- prop_fleeca_atm
    vector3(147.47, -1036.22, 28.37),   -- prop_fleeca_atm
    vector3(156.19, 6643.20, 30.59),   -- prop_atm_02
    vector3(158.80, 234.75, 105.64),   -- prop_atm_01
    vector3(173.82, 6638.22, 30.59),   -- prop_atm_02
    vector3(228.03, 337.85, 104.50),   -- prop_atm_01
    vector3(236.98, 219.88, 105.41),   -- prop_atm_02 (interior)
    vector3(237.41, 218.95, 105.41),   -- prop_atm_02 (interior)
    vector3(237.84, 218.03, 105.41),   -- prop_atm_02 (interior)
    vector3(238.27, 217.11, 105.41),   -- prop_atm_02 (interior)
    vector3(238.70, 216.19, 105.41),   -- prop_atm_02 (interior)
    vector3(264.87, 209.95, 105.41),   -- prop_atm_02 (interior)
    vector3(265.22, 210.90, 105.41),   -- prop_atm_02 (interior)
    vector3(265.56, 211.86, 105.41),   -- prop_atm_02 (interior)
    vector3(265.91, 212.82, 105.41),   -- prop_atm_02 (interior)
    vector3(266.26, 213.77, 105.41),   -- prop_atm_02 (interior)
    vector3(285.35, 142.98, 103.16),   -- prop_atm_02
    vector3(289.27, -1282.32, 28.66),   -- prop_atm_02
    vector3(289.53, -1256.79, 28.44),   -- prop_atm_02
    vector3(296.18, -896.23, 28.29),   -- prop_atm_02
    vector3(296.88, -894.32, 28.26),   -- prop_atm_02
    vector3(357.13, 174.08, 102.06),   -- prop_atm_01
    vector3(380.66, 322.84, 102.57),   -- prop_atm_01 (interior)
    vector3(527.78, -160.66, 56.14),   -- prop_atm_02
    vector3(540.22, 2671.68, 41.16),   -- prop_atm_01 (interior)
    vector3(1077.78, -776.97, 57.26),   -- prop_atm_02
    vector3(1137.81, -468.86, 65.70),   -- prop_atm_02
    vector3(1153.11, -326.90, 68.21),   -- prop_atm_01 (interior)
    vector3(1167.06, -455.65, 65.82),   -- prop_atm_02
    vector3(1171.52, 2703.14, 37.15),   -- prop_atm_01
    vector3(1172.46, 2703.14, 37.15),   -- prop_atm_01
    vector3(1687.40, 4815.90, 41.01),   -- prop_atm_01
    vector3(1700.69, 6426.76, 31.63),   -- prop_atm_01
    vector3(1703.32, 4934.05, 41.06),   -- prop_atm_01 (interior)
    vector3(1735.01, 6410.01, 34.04),   -- prop_atm_01 (interior)
    vector3(1822.97, 3682.58, 33.27),   -- prop_atm_01
    vector3(1968.39, 3743.08, 31.34),   -- prop_atm_01 (interior)
    vector3(2558.32, 350.99, 107.60),   -- prop_atm_02
    vector3(2559.05, 389.47, 107.62),   -- prop_atm_01 (interior)
    vector3(2564.00, 2584.55, 37.07),   -- prop_atm_01
    vector3(2683.59, 3286.30, 54.24),   -- prop_atm_01 (interior)
}
