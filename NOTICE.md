# whip: licence notice

## whip's own code

whip_core and whip's own resources (whip_autos, whip_autos_shop, whip_chat, whip_fuel, whip_gunny,
whip_loadingscreen, whip_phone, whip_rope, whip_voice) are licensed under the GNU Lesser General Public License 3.0:
each resource's `LICENSE`, with the GPL 3.0 it builds on in `COPYING`. The code in the whip_media_* packs
(`fxmanifest.lua`, `server.lua`) is under the same licence.

The example resources (names ending in `_example` or `_examples`) are under the MIT licence, in their own `LICENSE`:
copy them into your own resources freely.

Your own resources that use whip through its exports are yours, under any licence you choose: see **Selling on whip**
in the docs.

## The whip name and logo

The licence covers whip's code, not its name or its logo. A modified copy or a fork must not be called whip, or use
whip's logo, in a way that suggests it is whip or comes from whip's author. Saying that your resource works with whip
is fine.

## Rockstar Games material

These are made from Grand Theft Auto V and are Rockstar Games' material, used under the Cfx.re Creator Platform
License Agreement. whip's licence does not cover them:

- the pictures, videos and map in the whip_media_* packs (clothing, props, tattoos, vehicles, blips, peds, emotes, the
  map tiles and map textures), and the map shapes in whip_media_map/map;
- the car makers' logos in whip_core/html/img/manufacturers;
- the game's names and data in whip's lists (weapons, peds, tattoos, voice lines, props, blips);
- the map files in whip_autos_shop, and the map packs shipped beside whip (whip_homes_mirrorpark,
  whip_graphics);
- GTA's settings page, `pause_menu_pages_settings.gfx` in whip_core's stream/scaleform and stream_enhanced/scaleform,
  which is the game's own with whip's questions added, and its class, decompiled, in whip_core/dev/pause_settings
  (whip's added functions in it are whip's code).

whip is not affiliated with, endorsed or sponsored by Rockstar Games or Take-Two Interactive.

## Third-party parts

Each keeps its own licence.

| What | Where | Licence |
|---|---|---|
| three.js, with its loaders and controls | whip_core (vehicle HUD), whip_autos, whip_loadingscreen, whip_phone, whip_voice | MIT |
| LiveKit JavaScript client | whip_voice/html/js/vendor | Apache 2.0 |
| Material Design Icons: the turbocharger glyph | whip_core/html/js/glyphs.js | Apache 2.0 |
| Fonts: Archivo Narrow, Arimo, Barlow, Barlow Condensed, Big Shoulders, Bricolage Grotesque, DM Mono, IBM Plex Mono, Inter, Michroma, Orbitron, Plus Jakarta Sans, Rajdhani, Roboto, Russo One, Saira, Saira Condensed, Saira Semi Condensed | each resource's fonts folder, and whip_phone/html/core/fonts.js | SIL Open Font License 1.1 |
| The English keyboard words, from hermitdave's FrequencyWords (OpenSubtitles 2018) | whip_core/html/keyboard/en.txt | CC BY-SA 4.0 |
| WildBrick142's Chameleon Paint [Add-On] 2.0 paint ramps | whip_autos/stream/vehicle_paint_ramps.ytd | Its author's terms: never to be sold or monetised, so a paid bundle must leave this file out |
| GTA V's map traced as shapes, by Regynate (gist.github.com/Regynate/01a82731994e592cbe5d7e1c1b055d33) | whip_media_map/map | No licence stated; the map is Rockstar's |
| DurtyFree's GTA V data dumps, which whip's game lists are made from (github.com/DurtyFree/gta-v-data-dumps) | whip_core lists (weapons, peds, tattoos, voice lines, props) | No licence stated; the data is the game's |

## Contributing

whip is owned by one author, which keeps its licence open to change for future versions. By sending code, art or
text to whip, you license it to whip's author under the MIT licence, so it can be released under whip's licence or
any later one.
