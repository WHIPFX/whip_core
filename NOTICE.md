# WHIP: licence notice

Copyright (c) 2026 Whippy

## WHIP's own code

whip_core and WHIP's own resources (whip_autos, whip_autos_shop, whip_chat, whip_dealership, whip_fuel,
whip_gunny, whip_loadingscreen, whip_phone, whip_rope, whip_voice) are licensed under the GNU Lesser General Public License 3.0:
each resource's `COPYING.LESSER`, with the GPL 3.0 it builds on in `COPYING`. The code in the map packs
(whip_graphics, whip_homes_mirrorpark) and the whip_media_* packs is under the same licence, in each pack's own
`COPYING.LESSER` and `COPYING`.

One file is under the GNU General Public License 3.0 instead: whip_core's `shared/emote_list.lua`, the emote list,
because it is made from RPEmotes (below). Its licence is whip_core's `COPYING`.

The example resources (names ending in `_example` or `_examples`) are under the MIT licence, in their own `LICENSE`:
copy them into your own resources freely.

Your own resources that use WHIP through its exports are yours, under any licence you choose: see **Selling on
WHIP** in the docs.

## The WHIP name and logo

The licence covers WHIP's code, not its name or its logo. A modified copy or a fork must not be called WHIP, or use
WHIP's logo, in a way that suggests it is WHIP or comes from WHIP's author. Saying that your resource works with WHIP
is fine.

## Rockstar Games material

These are made from Grand Theft Auto V. They belong to Rockstar Games and Take-Two Interactive, not to WHIP: WHIP's
licence does not cover them and gives you no rights to them. They are here only to be used with GTA V on FiveM, where
Rockstar's terms for the platform apply (fivem.net/terms).

- the pictures, videos and map in the whip_media_* packs (clothing, props, tattoos, vehicles, blips, peds, emotes, the
  map tiles and map textures), and the map shapes in whip_media_map/map;
- the car makers' logos in whip_core/html/img/manufacturers;
- the game's names and data in WHIP's lists (weapons, peds, tattoos, voice lines, props, blips);
- the map files in whip_autos_shop, and the map packs shipped beside WHIP (whip_homes_mirrorpark,
  whip_graphics);
- GTA's settings page, `pause_menu_pages_settings.gfx` in whip_core's stream/scaleform and stream_enhanced/scaleform,
  which is the game's own with WHIP's questions added, and its class, decompiled, in whip_core/dev/pause_settings
  (WHIP's added functions in it are WHIP's code).

The emote preview videos in whip_media_previews were recorded in the game for WHIP: what they show is still
Rockstar's.

WHIP is not affiliated with, endorsed or sponsored by Rockstar Games or Take-Two Interactive.

## Third-party parts

Each keeps its own licence.

| What | Where | Licence |
|---|---|---|
| RPEmotes, by TayMcKenzieNZ, Mathu_lmn, MadsL and the RPEmotes community, which grew from DullPear's dpemotes (its first repository, github.com/TayMcKenzieNZ/rpemotes, is gone; it carries on as rpemotes-reborn, github.com/alberttheprince/rpemotes-reborn): many of the emotes, their commands and their prop placements | whip_core/shared/emote_list.lua | GPL 3.0 (whip_core's `COPYING`). Any copy keeps these credits and stays open source |
| txAdmin's death reasons, by André Tabarra (github.com/tabarra/txAdmin): many of the weapon names | whip_core/client/stats.lua, with its licence above the list | MIT, Copyright (c) 2019-2025 Take-Two Interactive Software, Inc. |
| three.js, with its loaders and controls | whip_core (vehicle HUD), whip_autos, whip_loadingscreen, whip_phone, whip_voice | MIT |
| LiveKit JavaScript client | whip_voice/html/js/vendor | Apache 2.0 |
| Material Design Icons: the turbocharger glyph | whip_core/html/js/glyphs.js | Apache 2.0 |
| Fonts: Archivo Narrow, Arimo, Barlow, Barlow Condensed, Big Shoulders, Bricolage Grotesque, DM Mono, IBM Plex Mono, Inter, Michroma, Orbitron, Plus Jakarta Sans, Rajdhani, Roboto, Russo One, Saira, Saira Condensed, Saira Semi Condensed | each resource's fonts folder, and whip_phone/html/core/fonts.js | SIL Open Font License 1.1 |
| The English keyboard words, from hermitdave's FrequencyWords (OpenSubtitles 2018) | whip_core/html/keyboard/en.txt | CC BY-SA 4.0 |
| WildBrick142's Chameleon Paint [Add-On] 2.0: the colour ramps whip_autos' Chameleon paints draw from | the separate resource chameleon_paint, installed beside WHIP, not part of it | Its author's terms: reupload and FiveM use with credit to WildBrick142, Disquse and Rockstar Games; never sold or monetised, so a paid bundle must leave it out |
| GTA V's map traced as shapes, by Regynate (gist.github.com/Regynate/01a82731994e592cbe5d7e1c1b055d33) | whip_media_map/map | No licence stated; the map is Rockstar's |
| DurtyFree's GTA V data dumps, which WHIP's game lists are made from (github.com/DurtyFree/gta-v-data-dumps) | whip_core lists (weapons, peds, tattoos, voice lines, props) | No licence stated; the data is the game's |

## Contributing

WHIP's own code is owned by one author, which keeps its licence open to change for future versions. By sending code,
art or text to WHIP, you license it to WHIP's author under the MIT licence, so it can be released under WHIP's licence
or any later one.
