# Default public garages and transfers

The core provisions 16 default public garages during startup, after existing garages, bays and
properties have loaded. Each managed location has one bay. Missing bays are restored, the nearest
existing bay keeps its ID, and surplus bays at managed locations are removed.

The locations are defined in `server/jbc_garage_setup.lua`: Public Garage, Motel Parking, Casino
Parking, San Andreas Parking, Spanish Avenue Parking, Caesars 24 North and West, Laguna, LSIA,
Vespucci Beach, Motor Hotel, Route 68 Liquor, Sandy Shores, Paleto Bay, Pillbox and Grapeseed.

## Existing servers

Keep the resource name `whip_core` and preserve your server's `config.lua`. Remove the old
`ensure whip_garages` entry before starting this version. Existing locations owned by that add-on
are adopted by the core without changing their garage keys or moving stored vehicle records.

The setup skips a missing default when a public garage already exists within 25 metres of its
marker or bay, or a private garage is within 8 metres. Existing custom/private garages are not
managed. The original stock `legion_square` garage at its stock position is treated as a default.
Edits to a managed default's bays are reconciled at the next restart; edit the definitions when
changing those locations permanently. Back up the database before upgrading an existing server.

## Transfer a stored vehicle

Enable **Link public garages** in **/whip → Settings → Vehicles**. It defaults off. At a public
bay with an eligible stored vehicle, choose **Transfer vehicle**, select the vehicle and its
destination, then confirm. Retrieve it at the destination garage. Disabling the setting stops new
transfers and leaves already transferred vehicles at their current garages.

The server checks the player's location, routing bucket, ownership, vehicle state and destination
again when committing. Destinations must be public, have a bay and belong to a running resource
(when resource-owned). Depot/impound garages, private garages, temporary/session vehicles, cars
that are out, and vehicles already in another transition are excluded. Transfers use the native
vehicle transition lock and persistence function.

## Validation

Run `lua5.4 dev/garage_defaults_test.lua` from the repository root for the offline regression
checks. These use the production garage setup, vehicle persistence and transfer callbacks with
stubbed database/native boundaries. They do not replace an FXServer integration test.

In a test server, verify first startup and restart, adoption from `whip_garages`, an existing custom
garage near a default, storage/retrieval, enabling and disabling transfers, cancelling both popup
steps, walking away before confirmation, and two simultaneous requests for the same vehicle.

Originally prepared as the JBC default-garages modifications on 2026-11-15; ported onto the current
upstream source for this contribution. WHIP's original licenses and notices are retained.
