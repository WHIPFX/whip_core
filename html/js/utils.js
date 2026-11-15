// ========================================
// SHARED UTILITIES
// ========================================

import { getItemDefs, noteItemIconMissing, itemIconIsMissing } from './core/item-defs.js';
import { whenMet, amountMet, fillImagePath } from './core/item-rules.js';
import { NuiRouter } from './router.js';
// Which media pack holds each picture (plain scripts: the index first, then its asking, whipAssetUrl)
import './assets-index.js';
import './assets.js';

// Resolution scaling — UI designed at 1440p, scale to match any resolution.
// Sets --ui-scale CSS variable, used as zoom on inner content containers
// (not full-screen overlays). Backgrounds fill the screen, content scales,
// text stays sharp, mouse coords unaffected.
//
// THE 2560 x 1440 DESIGN FITS THE SCREEN BOTH WAYS: by its height on a 16:9 screen or a wider one, by its width
// on a narrower one (16:10, 5:4, 4:3), where scaling by the height alone made the 16:9 layouts wider than the
// screen (the inventory ran off both sides at 2560 x 1600). ui.js's radial wheel works it out the same way.
//
// --hud-scale is the height alone, for the gauges under the minimap (css/status-hud.css): they line up with the map's
// box, which follows the screen's height at every shape (client/minimap.lua), as the vehicle dial does.
(function() {
    function applyScale() {
        var s = Math.min(window.innerHeight / 1440, window.innerWidth / 2560);
        document.documentElement.style.setProperty('--ui-scale', s);
        document.documentElement.style.setProperty('--hud-scale', window.innerHeight / 1440);
    }
    applyScale();
    window.addEventListener('resize', applyScale);
})();

// ---- Where an item's icon lives ----
//
// A resource ships its own item art: the server knows which resource registered each item and
// sends `def.img`, an absolute https://cfx-nui-<resource>/... URL. Absent means whip_core owns
// the icon, at `img/items/<key>.png`.
//
// getItemDefs is an import from core/item-defs.js (a leaf module), not a bare global.
/** Where whip_core keeps an item's own art, and the stand-in when there is none. */
const CORE_ITEM_IMG = (itemKey) => 'img/items/' + itemKey + '.png';
const ITEM_IMG_MISSING = 'img/items/missing.png';

/**
 * @param {string} itemKey
 * @param {string} [img]  where the picture is, from a payload that says (the /whip item browser and
 *        ground manager): used while the inventory's own definitions have not reached the page yet —
 *        without it a satellite's item came from whip_core's folder, its OLD picture where one was left.
 */
export function itemImageUrl(itemKey, img) {
    // ASKED AND ANSWERED. Once this item's icon has failed everywhere it could live, go straight
    // to the placeholder instead of 404ing again — the request that fails is what makes the
    // browser draw its broken-image glyph for a frame, and a re-render happens on every move.
    // Same shape as vehicleImageUrl's numeric-model shortcut below. See core/item-defs.js.
    if (itemIconIsMissing(itemKey)) return ITEM_IMG_MISSING;

    const defs = getItemDefs();
    const def = defs && defs[itemKey];
    if (def && def.img) return def.img;
    if (img) return img;
    return CORE_ITEM_IMG(itemKey);
}

// ---- A picture that depends on the item (def.images: server/item_options.lua) ----
//
// The first of an item's `images` whose `when` passes and whose {parts} fill is its picture; none,
// and it is the item's own. A variant whose file is missing (the art is not made yet) falls back to
// the item's own picture (the error listener below) and is not asked for again.
//
// {make} is the maker of the car an item's `model` names, which only the game knows: the page asks
// client Lua (itemVehicleMakes) once per model, draws the item's own picture meanwhile, and swaps the
// variant in when the answer comes.

/** Variant URLs that failed to load. */
const _variantMissing = new Set();
/** [model] = the maker ('pegassi'), or '' when the game knows none. */
const _makes = new Map();
/** Models asked about and not answered yet, and the pictures waiting on each: [model] = Set of img. */
const _waiting = new Map();
/** What each waiting picture shows, to work it out again when its maker is known. */
const _waitingSlot = new WeakMap();
let _askQueued = false;

function askMakes() {
    _askQueued = false;
    const models = [..._waiting.keys()].filter((m) => !_makes.has(m)).slice(0, 100);
    if (!models.length) return;
    nuiCallback('itemVehicleMakes', { models }).then((res) => {
        const makes = (res && res.makes) || {};
        for (const m of models) _makes.set(m, typeof makes[m] === 'string' ? makes[m] : '');
        for (const m of models) {
            const imgs = _waiting.get(m);
            _waiting.delete(m);
            if (!imgs) continue;
            for (const img of imgs) {
                const slotData = _waitingSlot.get(img);
                if (img.isConnected && slotData) setItemImage(img, slotData);
            }
        }
    });
}

function waitForMake(model, img, slotData) {
    let imgs = _waiting.get(model);
    if (!imgs) { imgs = new Set(); _waiting.set(model, imgs); }
    imgs.add(img);
    _waitingSlot.set(img, slotData);
    if (!_askQueued) { _askQueued = true; setTimeout(askMakes, 30); }
}

/** The picture an item's state picks from def.images, or null for the item's own. */
function variantUrl(def, slotData, img) {
    if (!def || !Array.isArray(def.images) || !def.imgRoot) return null;
    for (const v of def.images) {
        if (!v || typeof v.image !== 'string' || !whenMet(v.when, slotData.metadata)
            || !amountMet(v.amount, slotData.amount)) continue;
        const { path, waitModel } = fillImagePath(v.image, slotData.metadata, (m) => _makes.get(m));
        if (waitModel) { waitForMake(waitModel, img, slotData); return null; }
        if (!path) continue;
        // A link an admin pasted on its Items page (server/item_settings.lua checks its site) is used as it is.
        const url = /^https:\/\//.test(path) ? path : def.imgRoot + path;
        if (!_variantMissing.has(url)) return url;
    }
    return null;
}

/**
 * An item's picture into an <img>: the one its state picks (def.images), else its own, with the
 * missing-picture fallback below. Every slot that draws an item calls this, so one rule covers the
 * inventory, the hotbar and the wheel.
 * @param {HTMLImageElement} img
 * @param {{ item: string, metadata?: object }} slotData
 */
export function setItemImage(img, slotData) {
    const key = slotData.item;
    img.dataset.itemImg = '';
    img.dataset.itemKey = key;   // so the fallback knows what to retry
    delete img.dataset.itemImgRetried;
    const defs = getItemDefs();
    const variant = itemIconIsMissing(key) ? null : variantUrl(defs && defs[key], slotData, img);
    if (variant) {
        img.dataset.itemVariant = '';
        img.src = variant;
    } else {
        delete img.dataset.itemVariant;
        img.src = itemImageUrl(key);
    }
}

// ---- Vehicle and furniture pictures, emote videos: the media packs ----
//
// Not in whip_core: players download a resource again in full whenever anything in it changes, and
// these hundreds of MB hardly ever change while whip_core changes all the time. So they live in their
// own resources, the media packs (at most 256 MB each, by category), and are loaded from them by
// absolute URL, the cross-resource way theme.js and the satellites' item icons already use. Which one
// holds a file is js/assets.js's to say (whipAssetUrl). If it is not running they simply fail to load: a
// vehicle shows the missing.png stand-in (still in whip_core), a furniture tile is blank, and the
// emote menu reports a video that would not play.
export function assetUrl(path) {
    return globalThis.whipAssetUrl(path) || '';
}

// ---- Where a vehicle's picture lives ----
//
// img/vehicles/<model>.webp in its media pack (rendered outside the game). Simpler than the
// item case above: vehicle models are a game-wide namespace rather than something a resource
// registers, so there is no per-resource ownership to resolve.
//
// A numeric name is the documented degradation in server/vehicles.lua, where a model that could
// not be resolved is stored as a stringified hash instead. There is no picture of
// "-1651067813", so it goes straight to the placeholder rather than 404ing first.
export function vehicleImageUrl(model) {
    if (!model) return 'img/vehicles/missing.png';
    const key = String(model).toLowerCase();
    if (/^-?\d+$/.test(key)) return 'img/vehicles/missing.png';
    return assetUrl('img/vehicles/' + key + '.webp');
}

/** A furniture piece's icon. Named after its model by convention, the way vehicle pictures are. */
export function propImageUrl(model) {
    return assetUrl('img/props/' + model + '.webp');
}

/** An NPC's picture (the world builder's NPCs tab): img/peds/<model>.webp, by the same convention. The page
 *  draws a glyph where there is none yet. */
export function pedImageUrl(model) {
    return assetUrl('img/peds/' + String(model || '').toLowerCase() + '.webp');
}

// ---- The thing itself, not its picture's empty room (js/picture-bounds.js) ----
//
// A prop's, a car's or a ped's picture is the thing with room round it: a bed is wide and flat in a square
// picture, a ped a narrow figure in a tall one, so shown whole in a box the thing is small. picture-bounds.js
// (made by dev/picture_bounds.mjs) has the box round what is drawn in each, and fitPicture shows THAT as big as
// the img's own box allows: the img keeps its size and place, its picture is moved and scaled in it (its holder
// clips what spills, all of it see-through but a ped's body under a head). A picture with no bounds is left whole.

let _bounds = null;
let _boundsLoad = null;
const BOUNDS_OF = { prop: 'p', container: 'p', vehicle: 'v', npc: 'n', ped: 'n' };
// A picture loaded while hidden (a tab not open yet) has no box to fit to: fitted once it has one.
const _fitLater = typeof ResizeObserver === 'function'
    ? new ResizeObserver((entries) => {
        for (const e of entries) {
            if (!e.target.clientWidth) continue;
            _fitLater.unobserve(e.target);
            fitPicture(e.target);
        }
    })
    : null;

function pictureBounds() {
    if (!_boundsLoad) _boundsLoad = import('./picture-bounds.js').then((m) => (_bounds = m.BOUNDS || {}), () => (_bounds = {}));
    return _boundsLoad;
}

/**
 * Fit what is drawn in a media pack's picture to its <img>'s box, once the picture and the bounds are in.
 * The img says what it is: data-fit (prop, vehicle, npc) and data-model; data-fit-head: a ped's head and
 * shoulders only; data-fit-pad: the room left round it, a fraction of the box (0.04 if not said).
 * @param {HTMLImageElement} img
 */
export function fitPicture(img) {
    const key = BOUNDS_OF[img.dataset.fit];
    const model = String(img.dataset.model || '').toLowerCase();
    if (!key || !model) return;
    const go = () => {
        const b = _bounds && _bounds[key] && _bounds[key][model];
        const nw = img.naturalWidth, nh = img.naturalHeight, W = img.clientWidth, H = img.clientHeight;
        if (!b || !nw || !nh) return;
        if (!W || !H) { if (_fitLater && img.isConnected) _fitLater.observe(img); return; }
        // The drawn part, in the picture's own px: a ped's head, the top quarter of the figure, as wide as the box is.
        let x0 = (b[0] / 1000) * nw, y0 = (b[1] / 1000) * nh, x1 = (b[2] / 1000) * nw, y1 = (b[3] / 1000) * nh;
        if (img.dataset.fitHead !== undefined) {
            const hh = (y1 - y0) * 0.24, cx = (x0 + x1) / 2, hw = hh * (W / H);
            x0 = cx - hw / 2; x1 = cx + hw / 2; y1 = y0 + hh; y0 -= hh * 0.06;
        }
        // Where that sits in the box with the picture fitted whole (object-fit: contain), and how much bigger it may go.
        const c = Math.min(W / nw, H / nh), ox = (W - nw * c) / 2, oy = (H - nh * c) / 2;
        const pad = 1 - 2 * (img.dataset.fitPad !== undefined ? Number(img.dataset.fitPad) : 0.04);
        const rx = ox + x0 * c, ry = oy + y0 * c, rw = (x1 - x0) * c, rh = (y1 - y0) * c;
        const k = Math.min(4, (W * pad) / rw, (H * pad) / rh);
        if (!(k > 1.02)) return;
        const cx = rx + rw / 2, cy = ry + rh / 2;
        img.style.objectFit = 'contain';
        img.style.transformOrigin = `${cx}px ${cy}px`;
        img.style.transform = `translate(${W / 2 - cx}px, ${H / 2 - cy}px) scale(${k})`;
    };
    const ready = () => (img.complete && img.naturalWidth ? go() : img.addEventListener('load', go, { once: true }));
    if (_bounds) ready(); else pictureBounds().then(ready);
}

/** A map blip's icon by its GTA sprite id: img/blips/<id>.webp (the pause map's, and the shop wizard's Map
 *  step). White, tinted to the blip's colour by an SVG filter where it is drawn. */
export function blipImageUrl(sprite) {
    return assetUrl('img/blips/' + (Number(sprite) || 0) + '.webp');
}

/** A tattoo's picture (the character editor's Tattoos): img/tattoos/<overlay>.webp, the overlay name in lower
 *  case — unique across every collection, so no folder per collection. */
export function tattooImageUrl(overlay) {
    return overlay ? assetUrl('img/tattoos/' + String(overlay).toLowerCase() + '.webp') : null;
}

/** An emote or walk preview: the `video` field of shared/emote_list.lua, such as 'Emotes/wave.webm'. */
export function emoteVideoUrl(video) {
    return assetUrl('video/emotes/' + video);
}

// ---- Clothing pictures: img/clothing (a media pack per body) ----
//
// A folder per body and slot, a file per item and colour, named by the item's GTA collection and its
// number inside it (client/appearance.lua, clothingIcons, explains why not the card number):
//     img/clothing/female/p0_hats/female_prop0_mp_f_heist4_002_03.webp
const CLOTHING_SLOTS = {
    component: { 0: '00_head', 1: '01_masks', 2: '02_hair', 3: '03_arms_gloves', 4: '04_pants', 5: '05_bags',
                 6: '06_shoes', 7: '07_accessories', 8: '08_undershirts', 9: '09_vests_armour', 10: '10_decals', 11: '11_tops' },
    prop: { 0: 'p0_hats', 1: 'p1_glasses', 2: 'p2_ears', 6: 'p6_watches', 7: 'p7_bracelets' },
};

/**
 * One clothing picture's name, without its folder or '.webp' ('male_11_mp_m_vinewood_004_00'), or null
 * when there is none to ask for. It is also that item's key in the character editor's names
 * (editorNamesUrl), which name each picture.
 * @param {string} gender  'male' | 'female'
 * @param {'component'|'prop'} kind
 * @param {number} slot     the component (0-11) or prop slot (0, 1, 2, 6, 7)
 * @param {string} name     '<collection>_<item>', e.g. 'mp_m_vinewood_004' ('' = no name)
 * @param {number} texture  the colour, 0 and up
 */
export function clothingPictureName(gender, kind, slot, name, texture) {
    const folder = CLOTHING_SLOTS[kind] && CLOTHING_SLOTS[kind][slot];
    if (!folder || !name || (gender !== 'male' && gender !== 'female')) return null;
    const tag = kind === 'prop' ? 'prop' + slot : String(slot);
    const tex = String(Math.max(0, Number(texture) || 0)).padStart(2, '0');
    return `${gender}_${tag}_${name}_${tex}`;
}

/** One clothing picture's address (the arguments as clothingPictureName's), or null. */
export function clothingIconUrl(gender, kind, slot, name, texture) {
    const picture = clothingPictureName(gender, kind, slot, name, texture);
    return picture ? assetUrl(`img/clothing/${gender}/${CLOTHING_SLOTS[kind][slot]}/${picture}.webp`) : null;
}

/** The character editor's names (js/editor-names.js, written by whip_core/dev/editor_names.js): a classic
 *  script that sets window.WHIP_EDITOR_NAMES. whip_core's own, not with the pictures: the names show even when a
 *  media pack is not running. */
export function editorNamesUrl() {
    return 'js/editor-names.js';
}

// Fallback for a vehicle picture that has not been captured yet. One stage rather than the
// item handler's two, because a vehicle image has only one place it can live.
document.addEventListener('error', function(e) {
    if (e.target.tagName !== 'IMG' || e.target.dataset.vehImg === undefined) return;
    e.target.src = 'img/vehicles/missing.png';
    e.target.removeAttribute('data-veh-img');   // prevent an infinite loop
}, true);

// Global fallback for missing item images — any <img> inside the NUI that
// has the data-item-img attribute and fails to load gets swapped.
// Uses capture-phase so it works even when error events don't bubble, and
// lives on document so it survives cloneNode on child elements.
//
// TWO STAGES, because there are now two ways to fail. A satellite's icon can 404 — its resource
// is stopped, or the author forgot the files{} line in their manifest — and falling straight to
// missing.png would hide a picture whip_core may well still have. So try whip_core's own folder
// first, and only give up after that.
document.addEventListener('error', function(e) {
    if (e.target.tagName !== 'IMG' || e.target.dataset.itemImg === undefined) return;

    const key = e.target.dataset.itemKey;
    // A picture the item's state picked (setItemImage) that is not there: the item's own picture
    // instead, and that variant is not asked for again. Its own then goes through the stages below.
    if (e.target.dataset.itemVariant !== undefined) {
        _variantMissing.add(e.target.getAttribute('src'));
        delete e.target.dataset.itemVariant;
        e.target.src = itemImageUrl(key);
        return;
    }
    if (key && !e.target.dataset.itemImgRetried) {
        const core = CORE_ITEM_IMG(key);
        // ONLY IF IT IS SOMEWHERE ELSE. With no `def.img` the first attempt WAS whip_core's own
        // folder, so retrying it is a second identical 404 and a second frame of broken glyph for
        // nothing. getAttribute rather than .src: the property answers with the absolute URL the
        // browser resolved, which never equals the relative one we set.
        if (e.target.getAttribute('src') !== core) {
            e.target.dataset.itemImgRetried = '1';
            e.target.src = core;
            return;
        }
    }

    // Given up: it is not in the satellite's resource and not in whip_core's folder. Remembered,
    // so the next render of this item starts at the placeholder instead of failing its way here
    // again — see the note in core/item-defs.js.
    if (key) noteItemIconMissing(key);

    e.target.src = ITEM_IMG_MISSING;
    e.target.removeAttribute('data-item-img');   // prevent infinite loop
}, true);

export function nuiCallback(name, data) {
    return fetch('https://whip_core/' + name, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(data || {})
    }).then(r => r.json()).catch(() => ({}));
}

/**
 * Text made safe to put in HTML — in an element OR an attribute value.
 *
 * QUOTES TOO, AND 0 IS "0": a value inside `data-x="…"` or `title="…"` must not close the
 * attribute (the furnisher puts catalog text there), and the number 0 is not ''.
 */
export function escapeHtml(str) {
    if (str === null || str === undefined) return '';
    return String(str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

/**
 * Decode HTML character references in a developer-authored display string —
 * '&#9654;' → '▶', '&amp;' → '&'. Context-option icons and meta-field labels are
 * documented (docs.html, config.lua) as taking '&#128188;'-style values, a contract from
 * when they flowed through innerHTML; the DOM-built rendering keeps it by decoding here.
 *
 * XSS-safe on purpose: DOMParser builds an INERT document — scripts never run, nothing
 * touches the page — and only its textContent comes back, so any actual markup collapses
 * to its text. Callers assign the result via textContent, never innerHTML. Do NOT use it
 * on player-typed values; those should display exactly as typed.
 */
export function decodeTextEntities(str) {
    if (typeof str !== 'string' || str.indexOf('&') === -1) return str;
    return new DOMParser().parseFromString(str, 'text/html').documentElement.textContent;
}

// The form-field helpers (clamp, getNumVal, setNumVal, setMax, getSliderFloat, setSliderVal)
// moved to creator.js — every one of their 52 call sites lives there, and a "shared" file
// that only one file shares from is a dependency edge for nothing.


// ROUTER REGISTRATION — clipboard copy is generic dev-tool plumbing, so it lives with the
// shared helpers rather than any one panel.
// `ok` SAYS WHETHER IT COPIED: both ways can be refused while another resource holds the NUI focus and
// this page has none, so execCommand's answer counts too.
NuiRouter.register('copyToClipboard', (d) => {
    navigator.clipboard.writeText(d.text).then(function() {
        nuiCallback('clipboardDone', { ok: true });
    }).catch(function() {
        // CEF denies the async clipboard API outside secure gestures often enough that the
        // deprecated execCommand path stays as the fallback.
        let el = document.createElement('textarea');
        el.value = d.text;
        el.style.position = 'fixed';
        el.style.left = '-9999px';
        document.body.appendChild(el);
        el.select();
        let ok = false;
        try { ok = document.execCommand('copy') === true; } catch (e) { ok = false; }
        document.body.removeChild(el);
        nuiCallback('clipboardDone', { ok: ok });
    });
});