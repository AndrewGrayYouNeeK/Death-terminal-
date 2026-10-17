# Performance

How DeathTerminal schedules work, the knobs you can set, and measured numbers.
Run `zig build bench` (always ReleaseFast) to reproduce the micro-benchmarks;
`zig build bench -- frames` skips the slow parser section.

## How a frame is produced

1. **Sleep.** The GUI loop blocks in `poll()` on the PTY and the window
   connection. With nothing pending the timeout is infinite, so an idle
   terminal makes no wakeups and uses no CPU (there are no timers: the cursor
   does not blink).
2. **Coalesced PTY reads.** When the PTY is readable the loop reads 64 KiB at
   a time and parses until the PTY is empty, `read_budget_kb` (default 1 MiB)
   has been parsed, or about 8 ms have passed. Then it handles window events
   (keys, mouse, resize) before parsing more. With `cat bigfile` or `yes`
   running, input is never more than one batch behind.
3. **Pacing.** A redraw happens at most every `1/max_fps` s (default 120)
   while output streams, and only if something changed. Expose and resize
   force a redraw.
4. **Damage tracking.** `Frame.build` keeps the quads of every row and
   re-shapes only rows whose cells, highlight marks (selection/search) or
   block cursor changed. Frame-wide state (grid size, cell size, glyph-atlas
   epoch, reverse video, selection colours) triggers a full rebuild. The
   non-block cursor and the scrollbar are a tiny overlay that is always
   rebuilt. If nothing changed, nothing is drawn.
5. **GPU upload and draw.** Each cell quad is a 32-byte instance
   (pixel position/size as f32, atlas texel rect as u16, RGBA8 colour, kind);
   the viewport and atlas scales are push constants. A CPU mirror is updated
   only in the damaged ranges, and each frame-in-flight slot's persistently
   mapped instance buffer receives only the ranges it hasn't seen yet. Glyph
   atlas changes (dirty rectangle, or everything after a reset) are copied
   through a per-slot staging buffer, recorded in the frame's own command
   buffer. Everything is drawn with one instanced `vkCmdDrawIndexed`.
6. **Frames in flight.** Two frames can be queued. Each slot has its own
   command buffer, an image-available semaphore and an in-flight fence; each
   swapchain image has a render-finished semaphore. The CPU waits only when
   the GPU is two frames behind. The only full GPU waits are swapchain
   re-creation, instance-buffer growth and atlas-image growth. An out-of-date
   or suboptimal swapchain is re-created on the next frame.
7. **Software fallback.** Without a Vulkan text pipeline, the CPU rasteriser
   redraws only the pixel bands of dirty rows (and of the old/new overlay)
   and blits through Vulkan or XPutImage/SHM/GDI.

## Config keys

In config.lua these live under `render.` (`config.render.present_mode = "mailbox"`;
see [CONFIG.md](CONFIG.md)); the names below are the legacy config.txt keys.
They apply live on reload.

| Key | Default | |
|---|---|---|
| `present_mode` | `fifo` | `fifo` (vsync), `mailbox` (low-latency vsync, no tearing), `immediate` (no vsync, may tear), `fifo_relaxed`; `vsync` is an alias for `fifo`. If the surface doesn't support the mode: mailbox → immediate → fifo, immediate → mailbox → fifo. The chosen mode is logged at startup. |
| `vsync` | — | `true` = `fifo`, `false` = `mailbox` |
| `max_fps` | `120` | Upper bound on redraws per second while output streams; `0` = only the present mode limits it |
| `read_budget_kb` | `1024` | PTY bytes parsed per batch before input/drawing get a turn (16–65536); there is also a fixed ~8 ms time budget |

Set `DT_PERF_STATS=1` to print frames presented, unchanged frames skipped,
loop wakeups and PTY bytes/batches when the GUI exits.

## Measurements

The machine is a cloud VM with Xvfb-style X11 (`DISPLAY=:2`) and **llvmpipe**
(Mesa software Vulkan). There is no real GPU, so GPU times are CPU times here.
"Before" is `feat/selection` (milestone 5) built with the same flags.

### In the GUI (ReleaseFast, 80×24, JetBrains Mono 11 pt)

| Test | Before | After |
|---|---:|---:|
| Idle CPU, 10 s with a prompt (`/proc/<pid>/stat` utime+stime) | 2 ticks (0.2 %), 16 ms poll wakeups | **0 ticks (0.0 %)**, `top` 0.0 % |
| `time cat` 22.9 MB `seq 1 3000000` (3 M short lines) | 18.4 s | **1.83 s** |
| `time cat` 29.7 MB base64 (76-column lines) | 24.3 s | **0.57 s** |
| `yes` running: Ctrl+C, type `touch /tmp/x`, Enter → file exists | 158 ms (155 ms is xdotool typing) | 126 ms (124 ms is xdotool typing) |
| `timeout 5 yes`: frames | — | 307 presented + 245 unchanged frames skipped (all-`y` screens look the same), 8 120 loop wakeups |

Raw PTY throughput on this VM (`script -qc "cat …" /dev/null > /dev/null`):
the seq file takes 1.89 s, the base64 file 0.45 s and `yes` gives 4.7 MB/s.
So `cat` now runs at the speed of the kernel PTY. Input latency under load was
already fine before (the old loop serviced the window after every 4 KiB read);
the change is that output no longer takes 10–40× longer than it should.

### `zig build bench` (120×50 grid, 10 k scrollback)

Parser/emulator throughput, 32 MiB per workload fed in 64 KiB chunks. Expect
±15 % run-to-run noise on this VM.

| Workload | Before MiB/s | After MiB/s |
|---|---:|---:|
| ASCII text (CRLF lines) | 10.6 | **105–131** |
| `yes` (`y\r\n`) | 0.5 | **7.9–8.8** |
| SGR colours | 21.2 | **50–53** |
| UTF-8 / CJK / emoji | 11.5 | **28.5** |
| Cursor movement (TUI-style) | 24.3 | **30–34** |

Where the gains come from: scrolling used to `memmove` the whole screen per
line. Now a row map is rotated and only the new row is cleared. Scrollback
stores lines without trailing blanks, printable-ASCII runs skip the
UTF-8/parser state machine, and CR/LF in the ground state run directly.

Frames (JetBrains Mono 11 pt, 5 300 instances on a 120×50 screen of
coloured text):

| Step | Before | After |
|---|---:|---:|
| Build, everything changed | 1.11 ms (every frame) | 1.24 ms |
| Build, 1 dirty row | 1.11 ms | **0.06 ms** |
| Build, nothing changed | 1.11 ms (and drawn) | **0.02 ms** (not drawn) |
| Instances uploaded for 1 dirty row | 5 300 × 64 B = 339 KB | **3 × 32 B = 96 B** |
| Pack all instances (full upload) | — | 0.007 ms |
| Software raster, full | 1.64 ms | 1.83 ms |
| Software raster, 1 dirty row (incl. build) | 1.64 ms + build | **0.12 ms** |
| Streaming: parse 1 MiB of `yes` + damage frame | — | 117 ms (8.5 MiB/s) |

Reflow on resize with 10 k lines of history: 120→80 columns 130–150 ms,
80→120 columns 65–75 ms.

## Known limits

- `yes` parses at about 8 MiB/s (about 330 ns per line, mostly clearing and
  trimming 120-column rows). That is faster than this VM's PTY delivers, but it
  is the next thing to optimise (lazy row clearing / tracked row extents).
- Reflowing 10 k lines of scrollback takes ~0.1 s, done synchronously in the
  resize handler. During a window drag, every intermediate size reflows.
- The whole swapchain image is redrawn each presented frame (the GPU only
  uploads damage). Partial presentation (`VK_KHR_incremental_present`) is not
  used.
- Bash/readline redraws its prompt on SIGWINCH using the old line width, so
  after a reflowing resize you can see a duplicated prompt or a lost row next to
  it. Other reflowing terminals behave the same without shell integration.
- Numbers come from llvmpipe; on a real GPU, the GPU side should be much
  cheaper.
