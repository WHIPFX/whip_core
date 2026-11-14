# GTA's settings page, with whip's questions

`stream/scaleform/pause_menu_pages_settings.gfx` (and the same file in `stream_enhanced/scaleform/`) is GTA V's own
settings page with whip's questions added, so the pause menu's Settings page (`client/game_settings.lua`,
`html/js/settings-page.js`) can read GTA's settings and change them through GTA. The source of the change is
`PAUSE_MENU_PAGES_SETTINGS.as` here: GTA's class for that page, decompiled, with `getColumn` and the `whip*`
functions added, and one line at the end of `setupPage` that keeps GTA's video memory bar for whip. Nothing else in the
file is changed, and GTA's own settings menu works as before.

Legacy and Enhanced have the same file, byte for byte (game build 3889), so one build serves both.

## Building it

You need GTA's own `pause_menu_pages_settings.gfx`. Export it with CodeWalker or OpenIV from
`update\update.rpf\x64\data\cdimages\scaleform_frontend.rpf\pause_menu_pages_settings.gfx`. Take the update.rpf copy,
not the older one in x64b.rpf. Then, with [FFDec](https://github.com/jindrapetrik/jpexs-decompiler) and Java:

1. Make a folder holding only this class, at the path FFDec expects:
   `<folder>\scripts\__Packages\com\rockstargames\gtav\pauseMenuPages\PAUSE_MENU_PAGES_SETTINGS.as`
2. Import it into GTA's file:
   `java -jar ffdec.jar -cli -importScript <GTA's .gfx> <new .gfx> <folder>`
3. Check it: `java -jar ffdec.jar -cli -export script <out folder> <new .gfx>`. Every script but this one should
   match GTA's file, and this one should read as the source does.
4. Copy the new file over both `stream\scaleform\` and `stream_enhanced\scaleform\` copies.

Import only this one class. Importing every script recompiles Rockstar's others too, and four of them come out
different.

FFDec's compiler misreads `(a ? b : c)[i]`, so the source writes such a thing as an `if ... else`.

## When GTA updates

A game update can change GTA's own `pause_menu_pages_settings.gfx`. whip's copy then replaces the newer one until it
is built again from the new file. If the Settings page stops answering after an update ("GTA's settings page did not
answer"), export the new file and build again.
