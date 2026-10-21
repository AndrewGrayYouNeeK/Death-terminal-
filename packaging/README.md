# Packaging

Version **0.1.0**. `build.zig` (`default_version`) is the single source; `-Dversion=` overrides it. The rc file, winget, cask, formula and PKGBUILD carry the number too; bump them together.

```sh
zig build release                                # host target, ReleaseFast, stripped
zig build release -Dpackages=true                # Linux: + AppImage, .deb, .rpm
zig build release -Dtarget=x86_64-windows -Dpackages=true   # .zip + NSIS setup exe
zig build release -Dtarget=aarch64-macos -Dpackages=true    # .tar.gz + .app + .dmg
```

`-Dpackages` on macOS runs `macos/make-app.sh` (bundle, zip, and dmg). On
Windows it runs `windows/build-installer.sh` (`makensis`). Building the DMG
on Linux needs `genisoimage`, `zlib1g-dev`, and a C compiler. The Windows
installer needs `nsis`. The release workflow signs and notarizes the macOS
app when the Apple secrets are set, and still uploads unsigned artifacts
when they are not ([SIGNING.md](SIGNING.md)). Windows signing is still a TODO.

Output goes to `zig-out/release/`:

- **Staged trees:** `deathterminal-<ver>-<arch>-<os>/`, plus the archive made from each and a `SHA256SUMS`.
- **Linux trees:** follow the FHS: `bin/`, `share/{applications,icons,man,doc}`.
- **Windows trees:** flat: exe, docs and examples.

| Path | What |
|------|------|
| `archive.py` | tar.gz / zip + SHA256SUMS (used by `zig build release`) |
| `icons/` | `deathterminal.svg` and PNGs 16–512 (regenerate the PNGs with ImageMagick, see below) |
| `linux/deathterminal.desktop`, `linux/deathterminal.1` | desktop entry, man page |
| `linux/nfpm.yaml`, `linux/build-packages.sh` | .deb / .rpm via nfpm, AppImage via appimagetool (both downloaded into `packaging/.cache`). The .deb installs `deathterminal.desktop` |
| `appimage/AppRun` | AppImage entry point (bundled libcrypto + libxkbcommon; no args and no tty means `--gui`) |
| `aur/PKGBUILD` | Arch package from the source tag (skeleton: `sha256sums=SKIP`) |
| `windows/deathterminal.rc`, `.ico` | icon + version resource. `build.zig` generates the compiled rc so `-Dversion` is applied; this file stays the 0.1.0 reading copy |
| `windows/nsis/deathterminal.nsi`, `windows/build-installer.sh` | per-user NSIS setup exe (Start Menu shortcut runs `--gui`). Built on Linux with `makensis` |
| `windows/winget/` | winget manifests (portable zip; fill in the SHA256). The NSIS exe is a separate release asset |
| `windows/wix/deathterminal.wxs` | optional WiX v4 MSI (not built by CI) |
| `macos/Info.plist`, `macos/make-app.sh`, `macos/make-dmg.sh` | `.app` bundle, zip, and `.dmg`. `hdiutil` on a Mac; on Linux an HFS hybrid wrapped as UDIF. Ad-hoc `codesign` only when the tool exists |
| `macos/fetch-moltenvk.sh` | Pins MoltenVK 1.4.2 (`MoltenVK-macos.tar` + sha256) for the release workflow |
| `macos/sign-release.sh`, `macos/entitlements.plist`, `macos/gui-launcher.c` | Release-job signing: Developer ID, hardened runtime, `hdiutil` DMG, notarize, staple. Signs `Contents/Frameworks/libMoltenVK.dylib`. Copies artifacts through unsigned when secrets are absent |
| `SIGNING.md` | Developer ID setup, notarization, and the Windows/Linux TODOs. No secrets are stored here |
| `macos/deathterminal-cask.rb`, `macos/deathterminal.rb` | Homebrew cask (the .app) and formula (from source) skeletons |
| `ci/` | GitHub workflows to copy into `.github/workflows` (see `ci/README.md`) |

Icons:

```sh
cd packaging/icons
for s in 16 32 48 64 128 256 512; do
  convert -background none -density 300 deathterminal.svg -resize ${s}x${s} png/deathterminal-$s.png
done
convert png/deathterminal-{16,32,48,64,128,256}.png ../windows/deathterminal.ico
```

The AppImage needs no FUSE to build: appimagetool runs with `--appimage-extract-and-run`. To run the AppImage without FUSE, use `./deathterminal-*.AppImage --appimage-extract-and-run`.
