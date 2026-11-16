// ========================================
// NUI ENTRY POINT — the one <script type="module"> the page loads.
//
// THE IMPORT LIST BELOW IS THE LOAD ORDER. It replaces the 37 <script> tags index.html used
// to carry; every feature module is imported for its side effects (router registrations,
// key scopes, delegated binders) and the import graph pulls the shared layers
// (utils, router, core/item-defs, core/inv-state, core/inv-ops) in dependency order. Order
// between feature modules is mostly immaterial — registrations are name-keyed and key
// scopes carry explicit priorities — but the list mirrors the historical tag order so a
// diff against the old page reads cleanly.
//
// ACCEPTED TRADE-OFF: under one module graph, a syntax error in ANY file fails the WHOLE
// page (classic tags failed alone). That is why `node --check` across html/js is a hard
// gate before every restart — see the plan's verification rule.
//
// If an action stops working, look for its NuiRouter.register() in the file that owns the
// feature — not here.
// ========================================

// FIRST: the page's errors go to client Lua as well as F8, for tools (shared/error_tap.lua). Before anything else
// loads, so it hears their errors too.
import './error-tap.js';

import { NuiRouter } from './router.js';

// EARLY, AND BEFORE ANY PANEL. It subscribes to the router's nav-scope change notification, and
// a panel registering its scope during its own import can flip that answer — a subscriber added
// afterwards would miss the first change and Lua would not know a panel was open.
import './controller.js';   // gamepad -> nav intent; see client/controller.lua for the other half

import './curtain.js';      // the blackout the character screen travels behind, and the logo over it while it loads
import './viewfinder.js';   // the camera item's overlay (client/items/camera.lua)
import './landing.js';      // the logo over a camera shot before the character screen (client/landing.lua)
import './characters.js';
import './spawn-pick.js';   // after Play, where to arrive, on the 3D map (client/charselect.lua's spawn picker)
import './creator.js';
// bank.js IS GONE. The full-screen /bank panel has been replaced by an ATM you walk up to
// (client/atm.lua) and the phone's bank app; nothing sends openBank any more. Its NuiRouter key
// scope was priority 140, which is now FREE — see the list in router.js.
import './core/inv-wire.js';   // the inventory system's inbound protocol
import './inventory.js';       // ...and its default renderer
import './hotbar.js';
import './interact.js';
import './label-measure.js';   // how wide a 3D prompt's words are, for a prompt centred on its point
import './aim-dot.js';      // the aim dot, whip's crosshair for any weapon (client/aim_dot.lua)
import './ui.js';
import './nui-caps.js';    // what the browser can do (js/caps.js), handed to Lua; /nuicaps gameview
import './screen-probe.js'; // ReadScreen / PressScreen: this page read and pressed by its words (client/screen_probe.lua)
import './screenshot.js';   // TakeScreenshot: the game's picture, read once when asked (client/screenshot.lua)
import './event-monitor.js';
import './shops.js';
import './status-hud.js';
import './composer.js';      // the capsule's text-field state; capsule.js owns which state it is in
import './prompt-typing.js'; // typing a value into a 3D prompt on a keyboard: the keys, to Lua (client/prompt_typing.lua)
import './vehicle-dial.js';  // the bottom-right 3D rev dial and its stat gauges; the dial itself loads on first use
import './vehicle-controls.js'; // a vehicle's pad buttons over the dial for a few seconds (client/pad.lua)
import './stats-debug.js';
import './radar-debug.js';
import './pad-debug.js';    // the /paddebug controller overlay
import './vehstat-debug.js';
import './ground-debug.js'; // Ground Items Debug, a section of the debug panel (tools/ground_debug.lua)
import './dev-menu.js';
import './coords.js';
import './portrait.js';      // GTA's headshot of the player, made into a picture (client/portrait.lua)
import './cam-editor.js';     // the Camera Creator's timeline (tools/camera.lua)
import './zone-editor.js';   // the in-world editor HUDs — NOT sections; they show
import './door-editor.js';   // while the /whip panel is suspended
import './editor-hud.js';    // the generic one, built from what a mode sends (tools/editor_hud.lua)
import './death.js';
// (The object viewer draws in the game now, from a DUI: html/interact3d/objview.html, tools/objectviewer.lua.)
import './theme.js';
import './ui-controls.js';   // whip's list for every <select>, and the stepper for every number box
import './furnisher.js';   // the property furniture editor — player-facing, not a /whip section
import './ov-panel.js';    // the object viewer's options (G) and its Move, on the furnisher's markers (tools/ov_panel.lua)
import './hand-edit.js';   // the hand position editor's item list, beside Move (tools/hand_edit.lua)
import './property-themes.js';   // a home's Theme, from its sign (client/property_themes.lua)
import './emotes.js';      // the emote menu (client/emotes.lua)
import './pause.js';       // whip's pause menu and its map (client/pause.lua)
import './minimap.js';     // whip's minimap, the 3D map in GTA's radar's place (client/minimap.lua)
import './renderer-loader.js';
import './director-loader.js';   // the Director's screen, imported on first open (client/director.lua)
import './systems-loader.js';    // the Systems Creator's, the same way (client/systems_editor.lua)

// ---- the /whip admin panel: shell first, then its sections (html/js/wp/) ----
import './whip-panel.js';
import './wp/time.js';
import './wp/containers.js';
import './wp/vehicles.js';
import './wp/vehicleModels.js';
import './wp/garages.js';
import './wp/shops.js';
import './wp/items.js';
import './wp/itemlog.js';
import './wp/phones.js';
import './wp/ground.js';
import './wp/jobs.js';
import './wp/banks.js';
import './wp/playerManager.js';
import './wp/zones.js';
import './wp/doors.js';
import './wp/properties.js';
import './wp/uitester.js';
import './wp/config.js';     // Settings → Config: config.lua's settings, edited in game
import './wp/director.js';   // the Director's management tab; its editor loads apart (director-loader.js)

// ONLY WHAT FIVEM SENDS. Every resource's page is a frame under one root page, and a
// sibling frame can postMessage straight into this one — re-label a pending dialog, run a clipboard
// copy that drops the mouse. SendNUIMessage arrives from this page itself, with no source, or from
// the root page that hosts the frames, depending on the FiveM build; a sibling frame is none of
// those, and the browser sets `source`, so it cannot pretend. Anything else is dropped.
function fromFiveM(event) {
    const s = event.source;
    return s === null || s === window || s === window.parent || s === window.top;
}

window.addEventListener('message', (event) => {
    if (!fromFiveM(event)) return;
    NuiRouter.dispatch(event.data);
});

document.addEventListener('keydown', (e) => NuiRouter.handleKey(e));
