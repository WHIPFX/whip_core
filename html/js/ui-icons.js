/* ========================================
   UI ICONS — the small controls' icons, in one place

   Back, close, move up and down, and the tick: the controls every screen has. One family, drawn as
   the Settings page and the Object Viewer already draw their chevron: a 24x24 line, 2.4 wide, round
   ends, in currentColor. They replace the text characters these buttons used (‹ ← × ↑ ↓ ✓), which
   sat off the line and changed shape with the font.

   Sized by `.ui-ic` (css/base.css) at 1em, so an icon is as big as the text it stands for: a button
   keeps its own font-size and gets an icon to match.

   The interaction prompts' pictures (a door, a padlock, the car) are a different set: js/glyphs.js.
   ======================================== */

const PATHS = {
    back: '<path d="M15 5l-7 7 7 7"/>',
    close: '<path d="M6.5 6.5l11 11M17.5 6.5l-11 11"/>',
    up: '<path d="M6 14.5l6-6 6 6"/>',
    down: '<path d="M6 9.5l6 6 6-6"/>',
    check: '<path d="M5.5 12.5l4.2 4.2L18.5 7.5"/>',
};

/**
 * One icon's markup: fixed, no data in it, so it is safe for innerHTML.
 * @param {'back'|'close'|'up'|'down'|'check'} name
 * @param {string} [cls] another class beside ui-ic (a page's own size)
 * @returns {string}
 */
export function uiIcon(name, cls) {
    return '<svg class="ui-ic' + (cls ? ' ' + cls : '') + '" viewBox="0 0 24 24" aria-hidden="true">'
        + (PATHS[name] || '') + '</svg>';
}
