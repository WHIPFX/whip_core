-- The café from whip's tutorial (docs.html: Your First Resource, then Your First Job), finished: a coffee item,
-- a counter that sells it, a job with baristas who clock on, brew under a bar the server times, and get paid.
-- Read it beside the docs; every line is explained there.

fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'whip_cafe_example'
description 'The tutorial café: an item, a counter, a job (whip example)'
version '1.0.0'

dependency 'whip_core'
whip_requires '1.1'   -- the whip that has Whip.declare

shared_scripts {
    '@whip_core/lib/satellite.lua',   -- whip's helper: gives you Whip.declare
    'shared.lua',
}
server_script 'server.lua'
client_script 'client.lua'

-- The coffee's picture: whip shows an item's picture from html/img/items/<item key> in the resource that
-- registered it. Listed here, or the inventory cannot load it.
files {
    'html/img/items/*.webp',
}
