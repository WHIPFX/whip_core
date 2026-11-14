-- ============================================
-- STATEBAG KEYS — shared between client and server
-- ============================================
--
-- The names of the fields whip writes onto entities and players. Both sides must agree exactly, or
-- the client silently reads nil. Shared so the server (writer) and client (reader) use one string.
-- Not in config.lua: these are not settings.

--- The vehicle's whip id, stamped on the entity when the server creates or adopts it. Replicates
--- with the entity, so any client can tell which vehicle this is the moment it streams in.
VEHICLE_STATE_KEY = 'whipVehicleId'

--- Set (true) on street cars whip has adopted; absent on vehicles whip owns. Never written as
--- `false`: an absent key replicates nothing.
VEHICLE_SESSION_KEY = 'whipVehicleSession'

--- The stats this vehicle has, as one table: { fuel = 62.5, nitro = 40, ... }. On the entity's bag,
--- so every client with the car streamed in sees changes (a passenger watches the fuel climb).
---
--- A table, unlike the other keys: satellites register their own stats, so the set isn't fixed.
--- Any stat changing re-replicates the whole table.
---
--- Stored values only: an absent key means "at its registered default". Never read it raw (a full
--- tank reads nil). Client: ResolveVehicleStat / ResolveAllVehicleStats (client/vehicle_stats.lua);
--- server: VehicleStats.get / getAll. Presence means the car has the stat (a fitted nitrous bottle
--- appears here and goes when `clearAtMin` retires it).
VEHICLE_STATS_KEY = 'whipStats'

--- The current value of every `live` stat this vehicle carries: { boost = 87.4, ... }
---
--- Its own key because live values change several times a second, and re-sending the whole stat
--- block for each change is expensive. Presence still lives in the block above (HasVehicleStat,
--- `showWhenPresent`, the garage cards); only the number is read from here. The copy in the main
--- block is stale for live stats; read values through GetVehicleStat, which knows the difference.
VEHICLE_LIVE_KEY = 'whipLive'

--- How the vehicle should look: the stored appearance block, as the row holds it.
---
--- Colours, mods and extras are client-side natives, so the server can't paint a car. A statebag
--- (not an event) replicates on stream-in, so a client arriving later still gets it. Written at
--- spawn and on every appearance change, applied in client/vehicles.lua. Absent = a stock car.
VEHICLE_APPEARANCE_KEY = 'whipAppearance'

--- Arbitrary per-vehicle data a resource has attached: { turbo_mod = true, ... }
---
--- Not stats: no range, default, gauge or drain. Opaque to whip — anything json-encodable, keyed by
--- name, replicated and persisted with the vehicle, never drawn, decayed, clamped or consumed.
--- Stored values only, as above.
VEHICLE_DATA_KEY = 'whipVehData'

--- Which of a vehicle's doors are open, as a bitmask: bit N set means door N is up.
---
--- SetVehicleDoorOpen is local: only the network owner's call replicates; anyone else's is snapped
--- back. Requesting control would migrate ownership off the driver. So the server writes this mask
--- and every client, the owner included, applies it to its own copy; with everyone agreeing there is
--- nothing to snap back.
---
--- A bitmask, not a table: written on a keypress, and an integer diffs cheaply. Door indices are the
--- game's: 0-3 doors, 4 bonnet, 5 boot, 6/7 rear doors where the model has them. Absent = all closed.
---
--- The server keeps its own copy (Vehicles.getDoorMask / setDoorMask) and never reads this bag back:
--- the network owner could write it. The Sentinel restores a forged mask from that copy.
VEHICLE_DOORS_KEY = 'whipVehDoors'

--- What an admin holds an entity to with the object viewer (server/object_viewer.lua): a bitmask, 1 hidden,
--- 2 invincible, 4 frozen. Absent = none.
---
--- On the ENTITY, not sent once: those three natives only take on the game that owns the entity, and the owner
--- changes as players come and go. Every client keeps the ones it owns to the mask (client/ov_effects.lua), so the
--- hold follows the entity to its next owner and goes with it. The server's own copy is the truth (the Sentinel).
ENTITY_OV_HOLD_KEY = 'whipOvHold'

--- Why a vehicle's engine will not run (HoldVehicleEngine, server/vehicle_stats.lua): the reason its driver is
--- shown, absent when nothing holds it. On the ENTITY, so whoever drives it next refuses to start at once on their
--- own game. The server's holds are the truth: the Sentinel puts back a reason the car's owner game wrote itself.
VEHICLE_ENGINE_HOLD_KEY = 'whipEngineHold'

-- ============================================
-- PLAYER STATEBAG KEYS
-- ============================================
--
-- Watched by the Sentinel (server/sentinel.lua). The server writes them only through
-- Sentinel.setPlayerKey; satellites can't write them (SetSentinelPlayerKey takes only the caller's
-- own keys). A direct `Player(src).state.x =` write is treated as tampering: reverted and logged.
--
-- At their default the modifiers and mood are absent, never 1.0 or an empty name. Dead, escorted and
-- job go to `false` when they end and are cleared to absent at logout.
--
-- Prefixed `whip` so another resource's `isDead` is its own. Inside whip_core use these constants;
-- other scripts read the names (`Player(id).state.whipDead`).
--
-- No name or charId here: a bag replicates to every client. Another player's name is asked for
-- (GetPlayerFullName, under Config.ShowPlayerNames); a charId never leaves the server but to its owner.

PLAYER_DEAD_KEY     = 'whipDead'        -- boolean; absent while alive at load
PLAYER_JOB_KEY      = 'whipJob'         -- job KEY string, or false when off duty
PLAYER_ESCORTED_KEY = 'whipEscorted'    -- boolean
PLAYER_ESCORTER_KEY = 'whipEscortedBy'  -- holder's server id, or nil
PLAYER_DMGMOD_KEY   = 'whipDamageMod'   -- number, or ABSENT when exactly 1.0
PLAYER_MELEEMOD_KEY = 'whipMeleeMod'    -- number, or ABSENT when exactly 1.0
PLAYER_MOOD_KEY     = 'whipMood'        -- facial expression (a /mood name), or ABSENT for none
