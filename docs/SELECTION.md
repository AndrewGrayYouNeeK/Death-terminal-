# Selection, clipboard, scrollback and search

![selection, search highlights and scrollbar](images/selection.png)

## Mouse

| Gesture | Effect |
|---|---|
| Left drag | Select characters (autoscrolls past the top/bottom edge) |
| Double-click | Select a word (letters, digits, non-ASCII and `word_chars`) |
| Triple-click | Select the whole logical line (soft-wrapped rows are joined) |
| Shift+click | Extend the current selection |
| Ctrl+Alt+drag (or Alt+drag) | Rectangular/block selection |
| Middle-click | Paste PRIMARY |
| Ctrl+click | Open the URL or OSC 8 hyperlink under the pointer |
| Wheel | Scroll history on the normal screen (`scroll_lines` per notch); arrow keys / mouse reports in the alternate screen |

If the application turned on mouse reporting (htop, vim `mouse=a`, tmux),
clicks go to the application. Hold **Shift** to select anyway.
Many window managers (xfwm4, GNOME, KDE) grab Alt+drag to move windows, which is
why Ctrl+Alt+drag also starts a block selection.

Selections use absolute line numbers, so they stay on the same text while
output scrolls and while you scroll the view. Wide (CJK/emoji) cells are
always selected whole. Trailing blanks are trimmed; soft-wrapped rows are
copied without a newline. Switching to/from the alternate screen clears the
selection.

Releasing the button copies the selection to PRIMARY (X11/Wayland; emulated
in-process on Windows). With `copy_on_select = true` it is also copied to
CLIPBOARD.

## Keyboard (defaults)

| Keys | Action |
|---|---|
| Ctrl+Shift+C | `copy` selection to CLIPBOARD |
| Ctrl+Shift+V | `paste` CLIPBOARD |
| Shift+Insert | `paste_selection` (PRIMARY) |
| Ctrl+Shift+F | `search` |
| Shift+PgUp / Shift+PgDn | `scroll_page_up` / `scroll_page_down` |
| Shift+Home / Shift+End | `scroll_top` / `scroll_bottom` |
| Ctrl+Shift+Up / Down | `scroll_line_up` / `scroll_line_down` |
| Ctrl+Shift+A | `select_all` |
| Ctrl+= / Ctrl+- / Ctrl+0 | `zoom_in` / `zoom_out` / `zoom_reset` |

Scroll bindings act on the normal screen only; in the alternate screen
(less, vim) the key is passed through to the application, e.g. Shift+PgUp sends
`CSI 5;2~`. Typing returns the view to the bottom.

Rebind with `keybind = chord=action` lines; `chord=none` removes a default.
Chords are `+`-joined modifiers (`ctrl`, `shift`, `alt`, `super`) and an X11
keysym name or a single character (`ctrl+shift+c`, `shift+page_up`, `ctrl+=`).
Other actions: `clear_selection`.

## Paste

Pastes are wrapped in `ESC[200~ … ESC[201~` when the application enabled
bracketed paste (?2004); embedded end markers are stripped. When bracketed paste
is off and the text contains a newline, a red bar asks for confirmation
(`y`/Enter pastes, `n`/Esc cancels) — disable with `paste_confirm = false`.

## OSC 52

`osc52 = write` (default) lets programs set CLIPBOARD/PRIMARY with
`ESC]52;c;<base64>ESC\`. `read-write` also answers `ESC]52;c;?` queries with
the clipboard contents; `off` ignores OSC 52. Reading is off by default because
any program (including over SSH) could otherwise read your clipboard.

## Search

Ctrl+Shift+F opens a bar at the bottom (seeded with the selection if any).
Matches in scrollback and on screen highlight as you type; the current match is
orange.

| Key | Effect |
|---|---|
| Enter / Up / Ctrl+P | Previous (older) match |
| Shift+Enter / Down / Ctrl+N | Next (newer) match |
| Alt+C | Toggle case sensitivity (default: ASCII case-insensitive) |
| Alt+R | Toggle POSIX extended regex (not on Windows) |
| Ctrl+U | Clear query |
| Esc / Ctrl+G / Ctrl+C | Close |

## Links

Ctrl+click on `http(s)://`, `ftp://`, `file://` or `mailto:` text (detected
across soft wraps, trailing punctuation trimmed, parentheses balanced) or on an
OSC 8 hyperlink runs `url_open_command` (default `xdg-open`, `open` on macOS)
with the URL as its only argument — no shell is involved. Other schemes are
refused.

## Config keys

| Key | Default | |
|---|---|---|
| `copy_on_select` | `false` | Also copy to CLIPBOARD on release |
| `paste_confirm` | `true` | Confirm multi-line unbracketed pastes |
| `osc52` | `write` | `off`, `write`, `read-write` |
| `scrollbar` | `true` | Show a scrollbar while scrolled back |
| `scroll_lines` | `3` | Lines per wheel notch (1–100) |
| `word_chars` | `-_./~:@%+#?&=` | Extra characters that count as part of a word |
| `url_open_command` | `xdg-open` | Program used for Ctrl+click |
| `selection_background` | `#3B5BA5` | |
| `selection_foreground` | none | Keep the text colour if unset |
| `keybind` | — | `chord=action`, repeatable |

## Limitations

- X11: selections larger than the server's maximum request size are refused
  (INCR is supported for receiving, not for sending).
- Search does not match across soft-wrapped rows; case folding is ASCII only;
  matches are recomputed when the query changes, not when text changes in place.
- The selection is not cleared when the text under it is rewritten.
- The Wayland and Win32 clipboard paths compile but were not tested on real
  compositors / Windows; Ctrl+click does nothing on Windows yet.
