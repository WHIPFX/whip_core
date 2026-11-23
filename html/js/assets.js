// ============================================
// WHIP ASSETS — which media pack holds a picture, a video or a map file (the NUI's half)
// ============================================
//
// The same answer as shared/assets.lua (WhipAssets.url), from the same index (js/assets-index.js, made by
// dev/assets_index.mjs): whipAssetUrl('img/props/prop_bench_01a.webp') is
// 'https://cfx-nui-whip_media_props/img/props/prop_bench_01a.webp' while that pack runs, else
// 'https://media.whipfx.net/media/img/props/prop_bench_01a.webp?v=<its tag>', or null when no area holds it. A
// plain script, as the index is: a page loads both with <script> (assets-index.js first); a module imports both
// (js/utils.js).

(function () {
    'use strict';

    /** The resource whose folder has `path`, or null. An area split over several resources goes by the name: the
     *  last whose run of names starts at or before it. */
    function resourceFor(path) {
        const p = String(path || '').replace(/^\/+/, '').toLowerCase();
        let found = null, foundLen = -1;
        for (const c of globalThis.WHIP_ASSET_CHUNKS || []) {
            const d = c.dir;
            if (d.length >= foundLen && p.startsWith(d + '/')) {
                if (d.length > foundLen) { found = null; foundLen = d.length; }
                if (!c.from || p.slice(d.length + 1) >= c.from) found = c.resource;
            }
        }
        return found;
    }

    // Where each pack comes from (GlobalState.whipMedia, server/media.lua): { base, packs: { [pack]: 'local' | tag } }.
    // Sent by client/ready.lua (this page) and client/dui_page.lua (a world page made with `assets`). A pack that
    // isn't running loads from WHIP's CDN, at the pack's tag so a release is a new address.
    let sources = null;
    window.addEventListener('message', function (e) {
        const d = e.data;
        if (d && d.action === 'whipAssetSources') sources = d.sources || null;
    });

    globalThis.whipAssetUrl = function (path) {
        const res = resourceFor(path);
        if (!res) return null;
        const p = String(path).replace(/^\/+/, '');
        const v = sources && sources.packs && sources.packs[res];
        // In lower case, as the CDN keeps them (shared/assets.lua says why)
        if (v && v !== 'local' && sources.base) {
            return sources.base + '/media/' + p.toLowerCase() + '?v=' + encodeURIComponent(v);
        }
        return 'https://cfx-nui-' + res + '/' + p;
    };
})();
