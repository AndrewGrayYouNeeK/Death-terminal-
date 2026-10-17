# VT / xterm compatibility

DeathTerminal advertises `TERM=xterm-256color` and implements the subset of
xterm that full-screen programs rely on. Emulation lives in
`src/terminal/terminal.zig`, the parser in `src/terminal/ansi_parser.zig`,
input encoding in `src/terminal/input.zig`; tests are in
`src/terminal/vt_test.zig`, `ansi_parser.zig`, and `input.zig`.

## Supported

| Area | Sequences |
|------|-----------|
| C0 | BEL, BS, HT, LF/VT/FF, CR, SO/SI (C0 inside CSI executes in place) |
| ESC | IND `D`, NEL `E`, HTS `H`, RI `M`, DECSC `7`, DECRC `8`, RIS `c`, DECKPAM `=`, DECKPNM `>`, charsets `(` `)` (B, 0), DECALN `#8` |
| Cursor | CUU/CUD/CUF/CUB, CNL/CPL, CHA/HPA, VPA, CUP/HVP, HPR/VPR, CHT/CBT, `CSI s`/`CSI u` |
| Editing | ED (0–3, ?J), EL (0–2, ?K), IL/DL, ICH/DCH, ECH, REP, SU/SD, insert mode (IRM), LNM |
| Margins | DECSTBM; scrollback only collects lines from full-screen primary scrolling |
| Modes | DECCKM 1, DECCOLM 3 (80/132 switching when allowed; ?40 and `window.allow_column_switch` gate it), DECSCNM 5, DECOM 6, DECAWM 7, X10 mouse 9, blink 12, DECTCEM 25, 47/1047/1048/1049, 1000/1002/1003/1004/1006, 2004; DECRQM reports them |
| SGR | 0–9, 21–29, 30–37/90–97, 40–47/100–107, 38/48 with `5;n` and `2;r;g;b` (also colon forms), 39/49; 58/59 parsed and ignored |
| Reports | DA1 `CSI ? 62 ; 22 c`, DA2 `CSI > 1 ; 10 ; 0 c`, DSR 5/6, DECXCPR, XTVERSION, OSC 10/11 `?` queries |
| OSC | 0/2 title, 7 cwd, 8 hyperlinks (≤ 2048 bytes, ≤ 4096 links, control bytes rejected), BEL or ST terminated, capped at 8 KiB |
| Cursor style | DECSCUSR 0–6 (block / underline / bar) |
| Input | xterm key encoding (DECCKM, keypad mode, SS3 F1–F4, `CSI 1;mod X`, tilde keys), Alt as ESC prefix, mouse legacy + SGR, focus `CSI I`/`CSI O`, bracketed paste wrapper |

## Not supported (yet)

- 80/132-column switching resizes headless grids only; GUI panes keep the window layout width (DECCOLM still clears, homes and resets margins)
- Left/right margins (DECSLRM/DECLRMM), double-width/height lines, VT52 mode, soft fonts, sixel
- Reflow on resize, underline colour/curly underline, blinking text
- OSC 52 is handled (see [SELECTION.md](SELECTION.md)); selection/paste UI lives outside the emulator

## Verification (headless)

`tools/headless_drive.py` runs `deathterminal --headless` in a pseudo-terminal,
sends keystrokes, and prints the rendered grid.

- **vim** (`vim -u NONE -N`): opens on the alternate screen, insert mode, `:set number`, `:%s`, arrows, `:split` and `Ctrl+E` scrolling inside a split (scroll regions), and `:q!` restores the shell screen and cursor.
- **less**: paging, reverse scroll (`k`, uses RI/scroll region), search, and quit restores the screen.
- **htop**: meters, process table, and function-key bar render in place; quit restores the screen.
- **tmux** (`-f /dev/null`): status line, vertical and horizontal splits with line-drawing borders, scrolling inside a pane, `tput colors` reports 256.
- **vttest 2.7**:
  - Menu 1 (cursor movement): the 80-column border, autowrap, control chars inside sequences, and leading zeros all pass. The 132-column passes (border, autowrap) also pass in headless since 0.1.0 (DECCOLM resizes the grid).
  - Menu 2 (screen features): wrap, tab set/reset, soft/jump scroll regions, origin mode, and the SGR pattern all pass. 132-column screens (light/dark background, wrap) render at 132 columns in headless.
  - Menu 3.8 (VT100 charsets): DEC special graphics map correctly.
  - Menu 6 (reports): DSR 5/6 and DA1 are answered correctly.
  - Menu 8 (VT102): insert/delete line accordion, IRM, DCH, and ICH pass at 80 columns.
