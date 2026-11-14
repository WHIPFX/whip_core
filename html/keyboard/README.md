# Keyboard languages

Whip's on-screen keyboard (for controller players) types in a **language pack**. Each pack is two files in
this folder, named by the language's two-letter code:

| File | What it holds |
|---|---|
| `<code>.json` | The pack's name, its letter keys and its accents (below) |
| `<code>.txt` | The words it suggests, one a line, **most common first** (the order is the ranking). Lines starting with `#` are skipped. |

English (`en`) comes with whip. To offer another language:

1. Put its two files here (for example `fr.json` and `fr.txt`).
2. Add its code to `Config.Keyboard.Languages` in `config.lua` (for example `{ 'en', 'fr' }`).
3. Restart whip_core.

Players then pick it in the pause menu (Settings → Server → Controller → Keyboard language), or switch with
the language key on the keyboard. With the setting on "Game language" they get the language GTA is set to,
when the server offers it.

## The .json file

```json
{
    "name": "Français",
    "rows": [
        ["a", "z", "e", "r", "t", "y", "u", "i", "o", "p", "'"],
        ["q", "s", "d", "f", "g", "h", "j", "k", "l", "m", "."],
        ["w", "x", "c", "v", "b", "n", ",", "?", "!"]
    ],
    "accents": { "e": "éèêë", "a": "àâ", "c": "ç", "u": "ùûü", "i": "îï", "o": "ô" }
}
```

- `rows`: the three rows of letters, exactly **11, 11 and 9** keys. The numbers above them, Caps, delete,
  the symbols page and the bottom row are the keyboard's own.
- `accents`: a letter's other forms. On a controller, holding A on that letter opens them. Suggestions
  ignore accents, so typing `cafe` already offers `café`.

## The .txt file

`dev/keyboard_words.js` makes one from a frequency list in hermitdave's FrequencyWords format, with a
block list taken out:

```
node dev/keyboard_words.js fr fr_50k.txt fr_block.txt
```

## Credits

- `en.txt`: hermitdave's [FrequencyWords](https://github.com/hermitdave/FrequencyWords) (OpenSubtitles
  2018), licensed **CC BY-SA 4.0**. The list here is an adaptation of it (cut to 20,000 words, split
  contractions joined back, rude words taken out) under the same licence.
- Rude words taken out with the help of
  [LDNOOBW](https://github.com/LDNOOBW/List-of-Dirty-Naughty-Obscene-and-Otherwise-Bad-Words) (CC BY 4.0).
