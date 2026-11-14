# whip_core changelog

What changed in each version, for anyone whose resource uses whip.

Each version lists **Added**, **Changed** and **Removed**.

## 1.1.0

### Added

- `Whip.declare` in lib/satellite.lua: one declaring call, `Whip.declare:RegisterItem(...)`, made once whip_core is
  ready and again after every restart, with no `Whip.register` function around it. It takes the `Register…`,
  `Ensure…`, `On…` and `Watch…` exports, `SecureEvent`, `SecureCallback`, `AddAction`, `AddItemOption`, `AddPoint`
  and `AddWeapons`, refuses anything else, and prints whip_core's refusals. A resource that uses it needs
  `whip_requires '1.1'`.

## 1.0.0 (beta, not yet released)

The beta's clean-up before the release. Until 1.0 ships, names may still change; each change is listed here.

### Changed

- `AddAction` answers the id, or `false` and why, with the warnings third (`id, false, warnings`). It was
  `true, id, warnings`. `if not ok then` reads the same; code that used the second answer as the id must use the
  first.
- `GetNpcBy` and `GetVehicleImage` answer `nil` on a miss, like every lookup (they answered `false`).
- `WatchVehicleStat` refuses with `false, why`, like `WatchVehicleData` (it answered `nil`).
- `SpendMoneyHold`, `SettleMoneyHold`, `ReleaseVehicleEngine` and `DropHeldProps` give a reason with `false`.
- `GetVehicleBy` answers only the vehicle (its second value never crossed the export).
- `GiveVehicleKey`, `RemoveVehicleKey` and `TransferVehicle` take a person: a server id or `{ charId = n }`, for
  someone online. `GrantPermission` and `RevokePermission` take a server id, `{ charId = n }` or `{ userId = n }`.
- `GetNearestGarage`, `GetDoorByPosition` and `SpawnVehicle` take a vector3 (SpawnVehicle a vector4 too) where they
  took x, y, z.
- `SetPlayerMetadata` refuses whip's own keys: appearance, outfits, creatorPending, walk, mood, whipFlags,
  moneyHeldOwed, pourRefundOwed, lastSeat.
- `RetireItem` takes only your own key: refused for one another resource registered last (remembered across
  restarts).
- `UpdateJob`, `DeleteJob`, `UpdateShop`, `DeleteShop`, `UpdateGarage` and `DeleteGarage` refuse a row another
  running resource made or declares, and so do the shop calls that change one: `AddCatalogItem`,
  `RemoveCatalogItem`, `SetShopLayout`, `SetShopItemPrice` and `SetShopSlotPrice`.
- `RegisterVehicles` and `RegisterProps` check every model's owner before changing anything: a clash leaves
  your earlier list as it was.
- Stashes and doors (`CreateContainer`, `EnsureContainer`, `UpdateContainer`, `CreateDoor`, `UpdateDoor`,
  `AdoptOrCreateDoor`, `EnsureDoors`) take an action's `require` when it names one rule, refuse it when it names
  more, and say a field they do not read in the console.
- A resource registering item keys, right-click actions, stats, vehicle stats, server zones or permissions whose
  names do not start with its own name hears so once in the console (a warning, never a refusal).
- `WhipEmit(name, payload)` takes one name.
- `CreateGroundItem` takes one table.
- whip_gunny's callbacks are named in full on both sides (`'whip_gunny:...'`).

### Added

- `HoldRespawn`, `ReleaseRespawn`, `GetRespawnHold`: keep a downed player from respawning while your resource needs
  them down.
- Settings: `NeedDamage`, `RespawnTime`, `RespawnLocations`, `DeathScreen`, `UnlockOnExit`, `LockpickGame`,
  `CharSelectFades`.
- The death screen's `whip_core:death:screenChanged` event, for a resource drawing its own.
- `Whip.core` in lib/satellite.lua: a typed proxy that calls whip_core through `Whip.call`.
- `---@async` on the 145 exports that can wait, and `dev/waits.js --check` to keep that list true.
- A manifest line `whip_error_tap 'no'` to turn off the satellite helper's error tap.
- `RegisterClientHook` refuses a hook name whip does not have.
- `whip_core/COPYING` (GPL-3.0).

### Removed

Before 1.0:

- The bare event names (`playerLoaded`, `itemAdded`, `bankTransaction`, `shopOpened`, ...),
  `whip_core:vehicle:locked`, `whip_core:client:spawned`, `whip_core:client:uiStateChanged`,
  `whip_core:devModeChanged`, `whip_core:client:showSuccess` and `showError`.
- The time override: `SetPlayerTimeOverride`, `ClearPlayerTimeOverride`, `HasPlayerTimeOverride`,
  `GetPlayerTimeOverride` (use weather layers).
- Renamed: `ZoneGetDef` → `GetZoneDef`; `ZoneRegisterServer` / `ZoneRemoveServer` / `ZoneContainsServer` →
  `ZoneRegister` / `ZoneRemove` / `ZoneContains`; `JobClockOn` / `JobClockOff` / `GetActiveJob` → `ClockOn` /
  `ClockOff` / `GetPlayerJob`; `PlayerHasVehicleKey`, `HasKeyForVehicle` → `HasVehicleKey`; `TakePropertyKey` →
  `RemovePropertyKey`.
- `GetVehicleInfo`, `IsExternalUIOpen`, `SetAllowWeapon`, `IsSwappableInventory`, `GetDbZonesForSync`,
  `ToggleStatsDebug`, `ToggleVehStatDebug`, `ToggleVehDebug`.
- The five old interaction APIs (`Interact*`, `Radial*`, `VehiclePart*`, `AimTarget*`): `AddAction`.
- The first inventory API (`RegisterItemUse`, `GetSlotData`, `RemoveItemFromSlot`, `TakeItemFrom`, `PlaceItemAt`,
  `OpenContainer`, `CloseContainer`, `GetContainerItems`, `GetVehicleStorage`, `GetContainerSlots`,
  `GetContainerMaxWeight`, `DefineStoreKind`, the panel getters and setters, `UpdateShopCatalog`, `GetShopByKey`,
  `GetShopByContainerId`, `GetShopsByJob`, `GetOpenContainer`, `GetOpenVehicleStorage`, `GetOpenPanels`,
  `GetPlayerContainers`, `IsPlayerInventoryOpen`).
- The bank exports without `Bank` in their names (`CreateAccount`, `Deposit`, `Withdraw`, `Transfer`, ...).
- `GetJobByKey`, `EnsureVehicle`, `GetStatuses`, the housing exports (`GetHouse`, `GetHouses`, `GetHouseObjects`,
  `GetHouseObjectCount`).
