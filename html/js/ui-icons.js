/* ========================================
   UI ICONS — the small controls' icons, in one place

   Back, close, move up and down, the tick, minus and plus: the controls every screen has. One family, drawn as
   the Settings page and the Object Viewer already draw their chevron: a 24x24 line, 2.4 wide, round
   ends, in currentColor.

   Sized by `.ui-ic` (css/base.css) at 1em, so an icon is as big as the text it stands for: a button
   keeps its own font-size and gets an icon to match.

   The interaction prompts' pictures (a door, a padlock, the car) are a different set: js/glyphs.js.
   ======================================== */

/** The paths, on a 24x24 grid centred on 12. Screens with their own <svg> (its size, its stroke) take the path from
 *  here, so each shape is drawn in one place. */
export const ICON_PATH = {
    back: '<path d="M15 5l-7 7 7 7"/>',
    forward: '<path d="M9 5l7 7-7 7"/>',
    close: '<path d="M6 6l12 12M18 6L6 18"/>',
    up: '<path d="M6 15l6-6 6 6"/>',
    down: '<path d="M6 9l6 6 6-6"/>',
    check: '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
    minus: '<path d="M5 12h14"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
};

/**
 * One icon's markup: fixed, no data in it, so it is safe for innerHTML.
 * @param {keyof typeof ICON_PATH} name
 * @param {string} [cls] another class beside ui-ic (a page's own size)
 * @returns {string}
 */
export function uiIcon(name, cls) {
    return '<svg class="ui-ic' + (cls ? ' ' + cls : '') + '" viewBox="0 0 24 24" aria-hidden="true">'
        + (ICON_PATH[name] || '') + '</svg>';
}
