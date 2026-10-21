# Mobile plan

Plan only. No iOS or Android target is built, and `build.zig` does not grow a phone
target in this change. Desktop packaging is the thing that ships here.

## What would have to move

YouNeeK Death Terminal is a desktop process. The pieces a phone build would trip over:

| Piece | Today | Why a phone cannot reuse it as-is |
| --- | --- | --- |
| Windows | X11, Wayland, Win32, Cocoa (`src/platform/window.zig`, `cocoa_backend.zig`) | No Android `Surface`, no UIKit. Cocoa dlopens AppKit, not UIKit. |
| Vulkan surfaces | `vkCreateXlibSurfaceKHR`, Wayland, Win32, `VK_EXT_metal_surface` (`src/renderer/gpu_present.zig`) | No `VK_KHR_android_surface`. The Metal path is a `CAMetalLayer` from AppKit. |
| Vulkan loader | `libvulkan.so.1`, `vulkan-1.dll`, MoltenVK (`src/renderer/loader.zig`) | `.ios` is listed next to `.macos` for dylib names only. Nothing creates an iOS view. Android is the `else` branch (`libvulkan.so`), which is not a surface. |
| PTY | POSIX `posix_openpt` on Linux/macOS, ConPTY on Windows (`src/terminal/pty.zig`) | iOS apps cannot `fork`/`posix_openpt` into a user shell. Android can open a PTY, but the useful shell is one you bundle, not a login on the device. |
| SSH | libssh2 is compiled only when `os.tag == .linux` (`build.zig` `addLibssh2`). Other targets print "only available on Linux" (`src/ssh/unsupported.zig`) | The client also assumes a POSIX tty: `poll`, `sigaction`, `pipe2`, glibc `malloc_usable_size` (`src/ssh/client.zig`, `src/ssh/session.zig`). |
| Fonts | fontconfig on Linux; a font-folder scan on Windows/macOS. JetBrains Mono is embedded | fontconfig and `~/Library/Fonts` are not on a phone. The embedded face is the one that already travels with the binary. |

The part that is actually portable is the VT grid, scrollback, and the software renderer
(`src/renderer/software.zig`), which already turns a frame into a packed RGBA buffer.
GPU present is a separate attach step per window system.

## Path A — Zig core on Android, NDK, Vulkan surface

Zig 0.13 can target `aarch64-linux-android` (and the 32-bit ABI). A realistic shape:

1. A small Kotlin activity owns the window, the soft keyboard, and an `ANativeWindow`.
2. The Zig core is a static library built with the NDK sysroot (`zig build -Dtarget=aarch64-linux-android`).
3. JNI (or a thin C ABI) passes key bytes, resize, and the RGBA frame. A later step can
   call `vkCreateAndroidSurfaceKHR` on that window.
4. libssh2 has to be built for Android. Today it is Linux-only and links the system
   `libcrypto`. Android needs a static libcrypto (BoringSSL or OpenSSL) and a session
   API that does not draw prompts by poking a POSIX tty.
5. Fonts: use the embedded JetBrains Mono. Do not depend on fontconfig.

Local shell: possible later, and only by bundling a shell (the Termux approach) or by
executing `/system/bin/sh`, which is a toybox and a poor default. v1 should not do this.

This reuses the glyph pipeline only after a new surface backend exists. The window
loop, X11/Wayland code, and `poll` integration do not come along. Effort is a new
platform backend plus an SSH port: `build.zig`, `src/ssh/*`, `src/renderer/gpu_present.zig`,
and a new Android project. It is the largest of the three paths if Vulkan is in scope
for the first build.

## Path B — iOS via MoltenVK

MoltenVK is already how macOS gets Vulkan (`VK_EXT_metal_surface` on a `CAMetalLayer`).
An iOS port would do the same on a `CAMetalLayer` hosted by UIKit, not by the current
AppKit backend. That means a new UIKit shell. `src/platform/cocoa_backend.zig` does not
become an iPhone app by retargeting the binary.

Blockers that are not packaging:

- **No local shell.** App Store processes do not get a PTY, `fork`, or `/bin/sh`.
  Every session is a remote one. SSH-first is not a product choice on iOS; it is the
  only choice.
- **Toolchain.** `zig build -Dtarget=aarch64-ios` needs an Apple SDK sysroot. Linux CI
  cross-compiles macOS by dlopening AppKit and linking only libSystem. That trick does
  not produce an installable iOS app, and this repo has no macOS SDK.
- **SSH is still Linux-only**, with the same libcrypto and POSIX tty assumptions as Android.
- **MoltenVK redistribution and signing** are App Store problems (bitcode/privacy
  manifests, a paid team, notarization). `packaging/SIGNING.md` already has no Apple
  secrets for the desktop app.

The software renderer avoids MoltenVK for a first build: draw the RGBA buffer in a
`UIView`. Vulkan can wait until a Mac with the SDK exists.

Effort matches path A for the Zig core, and adds a hard dependency on Apple hardware
and a store account before anyone can install it. It should not be the first phone.

## Path C — Thin shell, SSH client, touch keyboard

Keep the phone UI native (Kotlin on Android, SwiftUI on iOS) or, if one UI codebase
is worth more than two thin shells, Flutter. The Zig core is a library, not the
window.

What the library should expose, and nothing else:

- Create a terminal grid (cols, rows) and feed it bytes.
- Return the cell grid or the RGBA buffer from `SoftwareRenderer`.
- Open an SSH session: host, user, key, known_hosts callbacks, a channel of bytes
  in and out, resize. Prompts (password, host key) return to the shell as events
  instead of reading the tty.
- No X11, Wayland, Win32, Cocoa, or Vulkan symbol in this build.

The shell draws that buffer, owns the touch keyboard, and maps gestures:

- Printable keys and IME text become UTF-8 on the channel.
- A bar for Esc, Tab, Ctrl, arrows, and `Ctrl+C` (the desktop app has no touch input path).
- Scroll and selection talk to the existing scrollback and selection code, or a
  smaller subset of it.
- Font is the embedded JetBrains Mono at a scale the shell picks.

Flutter is the right call only if the same Dart UI must ship to both stores and
nobody wants a platform text view. The pixels already exist in Zig, so a native
canvas (Android `SurfaceView` / iOS `UIView`) is less work than reimplementing the
grid in Dart. Prefer the native shell unless a single UI codebase is an explicit goal.

What has to change in this repo for that library:

- Stop treating SSH as a Linux `main`. `addLibssh2` must build for the phone target
  against a static libcrypto, and `src/ssh/session.zig` must accept prompts through
  a callback instead of `Tty`.
- `src/ssh/client.zig`'s `poll`/`sigaction` loop stays a desktop front end. The
  library gets a non-blocking read/write on the channel.
- `src/terminal/pty.zig` is not linked into the iOS library. On Android it stays
  out of v1 as well.
- A C ABI in something like `src/mobile/abi.zig` (not written yet) so Kotlin and
  Swift do not import Zig.

## Recommendation

**Path C, Android first, SSH-only, software renderer.**

iOS has no local shell, and Android's local shell is not the product this codebase
is close to. The built-in SSH client is the feature that makes a phone build useful,
and it is also the feature that does not exist off Linux yet. Port that, draw the
grid with the software renderer, and put a touch keyboard in a Kotlin shell.

Do not start with a Vulkan surface. `attachMetal` and a future `attachAndroid` are
follow-ups once a session is on screen. Do not start with iOS: the same library API
is what SwiftUI would call, but it waits on an Apple SDK and a signing team that
desktop CI also does not have.

Order of work when someone picks this up:

1. Static libssh2 + libcrypto for `aarch64-linux-android`, with prompt callbacks.
2. C ABI: resize, write input, read the RGBA frame, start/stop an SSH channel.
3. Kotlin shell: surface, touch keyboard, known_hosts and password UI.
4. Only then consider a bundled Android shell, `VK_KHR_android_surface`, or an iOS
   shell over the same ABI.
