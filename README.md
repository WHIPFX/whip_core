# whip_core

The core of [WHIP](https://github.com/WHIPFX/txAdmin-recipe), a complete framework for FiveM servers: characters,
inventory, money and banks, jobs, shops, vehicles and garages, homes, the UI, the Director and an in-game admin panel.
Every other WHIP resource is built on it.

## Features

- **Characters.** Several per account, each with a full appearance editor, saved outfits and a choice of where to
  arrive.
- **Inventory.** Items are physical: cash is banknotes, bags weigh what they hold, and items can be dropped, thrown,
  stashed or kept in a car's boot.
- **Money and banks.** Personal, savings, shared and business accounts, and ATMs.
- **Jobs.** Ranks, permissions, clocking on and off, and a business bank account for the owner.
- **Shops.** Unlimited stock, player-run stock with their own prices, or the server's own.
- **Vehicles and garages.** Keys are items, cars keep their damage and stay in the world, and garages park them.
- **Homes.** Players buy, furnish and store things in their homes, and hand out keys.
- **Health and needs.** Health, armour, hunger, thirst and oxygen, death with respawn and revive, and escorting.
- **The world.** Lockable doors, zones, shared time and weather, and server-run NPCs.
- **UI.** HUD, minimap, pause menu, prompts, radial and emote menus, notifications, progress bars and skill checks,
  with controller support and themes.
- **The Director.** Missions, heists and stories built in game from cards, with no code.
- **Admin panel.** `/whip` manages players, items, vehicles, shops, jobs, banks, homes, doors, zones and every
  setting. Most of the world is built from it in game.
- **Security.** The server validates everything a player's game sends before any resource's code runs.
- **Activity log.** A timeline for every character and every item.

## Requirements

- FiveM's server with txAdmin: **FiveM Legacy** (FXServer artifact 38435 or newer, game build 3407 or newer) or
  **GTA V Enhanced** (cfx-server).
- OneSync.
- MariaDB 10.2.3+ or MySQL 8.0.16+.
- [oxmysql](https://github.com/WHIPFX/oxmysql), started before whip_core.

WHIP is a whole framework: don't run it beside another framework, inventory or target resource.

## Installation

WHIP installs as a **new server**, with [WHIP's txAdmin recipe](https://github.com/WHIPFX/txAdmin-recipe). The recipe
downloads every WHIP resource and oxmysql, creates the database, turns on OneSync, writes `server.cfg` and makes your
txAdmin account an admin. It can't be added to an existing server.

There's no SQL to import: whip_core creates its tables on its first start. **Quick Start** in `docs.html` shows the
`server.cfg` the recipe writes.

## First run

1. Start the server. After `Framework loaded successfully!`, the console prints a `whip setup` report. Each line
   marked **FIX** says what to change. Type `whipsetup` in the console to see it again.
2. Join and make a character. The recipe enforces Steam, so your Cfx.re account needs a linked Steam account.
3. Type `/w` and turn on developer mode. Your txAdmin account is already an admin.

To make someone else an admin, have them type `/w`: the console prints the `add_ace` line to add for them.

## Admin tools

Both need the `whip.devtools` ACE, which the recipe gives `group.admin`.

| Command | What it is |
| --- | --- |
| `/w` | Quick tools: noclip, invisibility, god mode, coordinates, the Object Viewer, debug overlays and Dungeon Mode |
| `/whip` | The admin panel: players and bans, vehicles, the economy, the world, the Director, the Monitor and settings |

**Developer mode.** `/w` opens to a single switch. Until you turn it on, you're treated as an ordinary player. While
it's on, your HUD shows a **Developer Access Enabled** mark. It turns off every time you join.

When you need help, type `whipsupport` in the server console: it prints the version, the setup report and recent
errors in one block.

## For players

| Key | Does |
| --- | --- |
| **F2** | Inventory |
| **Tab** | Hotbar; **1** to **5** use its slots |
| **E** | Interact |
| **F1** | Radial menu |
| **F3** | Emote menu; **X** stops an emote |
| **L** | Lock or unlock your car |
| **Mouse wheel** | Engine on (up) or off (down) |

Players can rebind these in **Settings > Key Bindings > FiveM**.

## Configuration

`config.lua` controls characters, money, inventory sizes, items, needs, respawn, jobs, time and weather, vehicles,
garages, shops and the HUD. Most settings can also be changed in game in `/whip` → Settings → Config, and a value saved
there overrides `config.lua` until you reset it. See **Configuration** in `docs.html`.

## Documentation

`docs.html` is WHIP's full documentation. Open it in a browser; it works offline. Server owners start with
**Quick Start**; developers with **Your First Resource**.

## For developers

Resources built on WHIP (satellites) declare `dependency 'whip_core'`, load
`shared_script '@whip_core/lib/satellite.lua'`, and call whip_core through its exports:
`exports.whip_core:AddItem(...)`. Start with these sections of `docs.html`:

| Section | Covers |
| --- | --- |
| **Your First Resource**, **Your First Job** | A coffee stand, then staff and pay, step by step |
| **The calls you'll use** | The exports most resources need |
| **Coming from QBCore, ESX or ox** | WHIP's equivalent of each call you know |
| **SecureEvent & SecureCallback** | Declaring what a client event may send, checked before your handler runs |
| **Settings pages for your resource** | Your own page in `/whip` → Settings |

`types/` gives your editor autocomplete for every export. `docs/examples/` holds two complete example resources.

## The rest of WHIP

| Resource | What it is |
| --- | --- |
| [whip_gunny](https://github.com/WHIPFX/whip_gunny) | Weapons: magazines, calibers, melee, throwables and attachments |
| [whip_fuel](https://github.com/WHIPFX/whip_fuel) | Fuel tanks, pumps with a hose, and the jerry can |
| [whip_rope](https://github.com/WHIPFX/whip_rope) | A physics rope to carry, tie and tow with |
| [whip_phone](https://github.com/WHIPFX/whip_phone) | The Duo phone, with apps as modules |
| [whip_autos](https://github.com/WHIPFX/whip_autos), [whip_autos_shop](https://github.com/WHIPFX/whip_autos_shop) | Whiplash: customisation, turbos and nitrous, and the shop in Burton |
| [whip_voice](https://github.com/WHIPFX/whip_voice) | 3D voice chat, on a voice server it runs itself |
| [whip_chat](https://github.com/WHIPFX/whip_chat), [whip_loadingscreen](https://github.com/WHIPFX/whip_loadingscreen) | Chat and the loading screen |
| [whip_media_clothing_male](https://github.com/WHIPFX/whip_media_clothing_male), [whip_media_clothing_female](https://github.com/WHIPFX/whip_media_clothing_female) | Clothing pictures for the character editor |
| [whip_media_props](https://github.com/WHIPFX/whip_media_props) | Pictures for the furniture catalog |
| [whip_media_previews](https://github.com/WHIPFX/whip_media_previews) | Vehicle, NPC and tattoo pictures, and emote previews |
| [whip_media_map](https://github.com/WHIPFX/whip_media_map) | The pause menu's 3D map, blip icons and minimap tiles |
| [whip_homes_mirrorpark](https://github.com/WHIPFX/whip_homes_mirrorpark) | Every Mirror Park house as a walk-in home, plus 25 garages |
| [whip_graphics](https://github.com/WHIPFX/whip_graphics) | LED streetlights and WHIP's lighting and sky |

## Updating

Read `CHANGELOG.md`, copy out `pack_exports/` (the Director and property packs you exported), then replace the
`whip_core` folder with the latest release. whip_core updates its tables on the next start.

## License

whip_core is licensed under the GNU LGPL 3.0: see `COPYING.LESSER`, and `COPYING` for the GPL 3.0 it builds on. One
file is GPL 3.0 instead: the emote list, `shared/emote_list.lua`, made from RPEmotes. The example resources in
`docs/examples/` are MIT. Resources that use WHIP through its exports are your own, under any licence: see
**Selling on WHIP** in `docs.html`.

`NOTICE.md` lists what the licence doesn't cover: the WHIP name and logo, Rockstar Games material, and third-party
code, fonts and data under their own licences.
