fx_version 'cerulean'
game 'gta5'

name 'rs-aidoc'
author 'RealitySucksRP'
description 'RS AI Doc - Dr. Graves autonomous infected trauma responder'
version '0.1.13'

lua54 'yes'

shared_scripts {
    'config.lua',
    'shared/dialogue.lua'
}

client_scripts {
    'bridge/rs_entities.lua',
    'bridge/client.lua',
    'client/audio.lua',
    'client/medical.lua',
    'client/main.lua'
}

server_scripts {
    'bridge/server.lua',
    'server/settlements.lua',
    'server/responders.lua',
    'server/medical.lua',
    'server/main.lua'
}

dependency '/onesync'

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/app.js',
    'html/sounds/*.ogg'
}

-- Integration fallbacks are included directly in this resource.
