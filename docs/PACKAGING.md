# Packaging

Templates for Homebrew, winget, Scoop, and Flatpak live under `packaging/`.
Nothing here is published. Do not create a git tag or a GitHub Release for
these files, and do not submit a manifest while it still contains a
`__VERSION__`, `__SHA256_…__`, or `__URL_…__` placeholder. Those
placeholders are not download URLs.

The older skeletons at `packaging/macos/deathterminal-cask.rb`,
`packaging/macos/deathterminal.rb`, and `packaging/windows/winget/` still
name `v0.1.0` release assets. Do not submit those. Use the files this
document lists.

## Release time

When a real release exists and its `SHA256SUMS` is in hand:

```sh
packaging/update-manifests.sh <version> <path-to-SHA256SUMS>
```

The script reads basenames (two-space `sha256sum` lines, or a leading `*`).
It requires all of:

| File | Filled into |
|---|---|
| `DeathTerminal-<version>-aarch64.dmg` | Homebrew cask (arm) |
| `DeathTerminal-<version>-x86_64.dmg` | Homebrew cask (intel) |
| `deathterminal-<version>-x86_64-linux.tar.gz` | Homebrew formula, Flatpak |
| `deathterminal-<version>-x86_64-windows.zip` | winget, Scoop |

Those names are what `zig build release -Dpackages=true` already writes
(`DeathTerminal-*.dmg` from `packaging/macos/make-app.sh`, the `.tar.gz`
from `packaging/archive.py`, the Windows zip from the same archiver).
If any name is missing, the script exits and writes nothing. It does not
create a tag or a release. The metainfo `<release date>` becomes the UTC
day the script ran; change it if that is not the release day.

After it runs, review the diff. The cask URL uses Homebrew `#{version}`
and `#{arch}` (`arch` is `aarch64` / `x86_64`, matching the dmg names).
The other URLs are concrete
`https://github.com/AndrewGrayYouNeeK/Death-terminal-/releases/download/v<version>/…`
links. Submit only once that release is actually downloadable.
`brew audit --online`, a winget validation that fetches the installer, and
`flatpak-builder` (it downloads the archive) cannot pass before then.

`checkver` / Homebrew `livecheck` are intentionally absent. Add them after
the first release exists.

### Where each file goes

| Path | Submit to |
|---|---|
| `packaging/homebrew/Casks/deathterminal.rb` | a tap's `Casks/deathterminal.rb` |
| `packaging/homebrew/Formula/deathterminal.rb` | a tap's `Formula/deathterminal.rb` |
| `packaging/winget/*.yaml` | `microsoft/winget-pkgs` `manifests/d/DeathTerminal/DeathTerminal/<version>/` |
| `packaging/scoop/deathterminal.json` | a Scoop bucket |
| `packaging/flatpak/` | Flathub, app id `org.youneek.DeathTerminal` |

The Linux formula installs the official x86_64 archive only. It has no
`version` stanza: after the script fills the URL, Homebrew reads the
version from `deathterminal-<version>-x86_64-linux.tar.gz`. CI does not
build an aarch64 Linux archive. A source formula is not what the script
can fill: `SHA256SUMS` lists release binaries, not the git tag archive. The binary is linked against system `libX11`, `libwayland-client`,
`libxkbcommon`, FreeType, HarfBuzz, fontconfig, and `libssl.so.3`. Those
come from the dynamic loader, not the Homebrew cellar. macOS users get the
cask (the `.dmg` / `.app`), not this formula.

The Flatpak installs that same archive plus a desktop file, metainfo, and
icons resized from `site/logo.png`. It does not install the archive's
`share/icons` tree. `--filesystem=host` is set because it is a terminal.
GPU rendering inside the sandbox still needs a host Vulkan driver; the app
falls back to software rendering when it cannot load one. The runtime is
`org.freedesktop.Platform` 26.08 (24.08 is already marked end-of-life by
`flatpak-builder-lint`). A full `flatpak-builder` build was not run: this environment has no
Flatpak runtime installed, and the archive URL does not exist until
release time. `flatpak-builder-lint manifest` reports one error,
`appid-url-not-reachable`: it requests `https://youneek.org` for the
`org.youneek` id and that host presents a self-signed certificate. The
id stays `org.youneek.DeathTerminal` as specified. Flathub will keep
failing that check until the domain serves a publicly trusted
certificate, or the id is changed.

## macOS app

`packaging/macos/make-app.sh` is what `zig build release -Dtarget=…-macos -Dpackages=true`
runs. It reads the version from the staged directory name
`deathterminal-<version>-<arch>-macos` (that name is the `-Dversion=` passed
to the build) and writes it to both `CFBundleShortVersionString` and
`CFBundleVersion`.

`packaging/macos/Info.plist` sets:

- bundle id `com.github.andrewgrayyouneek.deathterminal`
- `LSApplicationCategoryType` `public.app-category.developer-tools`
- `NSHighResolutionCapable`
- `LSMinimumSystemVersion` 11.0
- `CFBundleURLTypes` for `deathterminal://` (invite links are `deathterminal://join/<code>`)
- display name `YouNeeK Death Terminal`

The icon is `packaging/macos/DeathTerminal.icns`, built by
`python3 packaging/macos/render-icon.py` from `site/logo.png` only, at the
standard iconset sizes (16 through 1024, including the `@2x` files) and the
matching icns OSTypes (`icp4`–`icp6`, `ic07`–`ic10`, `ic11`–`ic14`). The
logo file is 256×256, so 512 and 1024 are upscaled. `make-app.sh` runs
`iconutil` when it exists and otherwise copies the committed `.icns`. It
does not use `packaging/icons/`.

`install.sh` has a separate nightly bundle (its own plist, version string
`0.1.0`, no URL scheme, icons from the downloaded `deathterminal-*.png`
set). This change does not touch that script.

### Menu bar

There is no application menu. `src/platform/cocoa_backend.zig` says there is
no `NSApplicationDelegate`. Nothing in that file creates an `NSMenu` or
calls `setMainMenu` / `orderFrontStandardAboutPanel`. `disarmMenu` only
clears key equivalents when AppKit already has a main menu. Cmd+Q posts a
close and Cmd+H calls `hide:`; those are key handlers, not menu items.
About (with the version), Hide, Quit, and Window are absent. Adding them
means a menu target and a delegate that still lets `disarmMenu` keep
terminal chords, which is application code rather than a bundle tweak.

Opening a `deathterminal://` link is also not delivered into the process.
The plist registers the scheme. The CLI accepts the same link via `--join`.
There is no Apple Event handler.

### What still needs a Mac

- Finder, Dock, and Get Info show the green skull, and Get Info shows the
  staged version. Check 512/1024 in the Dock; they are upscaled from 256.
- The `.dmg` opens and the app launches, including the cross-compiled
  Linux-built image (`genisoimage` + `libdmg-hfsplus`), which is not a
  native `hdiutil` image.
- `deathterminal://join/…` is registered, and clicking one does not open a
  shared pane until an Apple Event handler exists.
- The menu bar has no About, Hide, Quit, or Window menu. Cmd+Q and Cmd+H
  still quit and hide.
- Ad-hoc `codesign` (only when `codesign` is on `PATH`) is not enough for
  Gatekeeper. Notarization is the existing release job, below.
- MoltenVK is in `Contents/Frameworks` only when `MOLTENVK_DIR` was set.

## Signing and notarization

This does not change `packaging/macos/sign-release.sh`,
`packaging/macos/entitlements.plist`, or the release workflow. No
certificate belongs in the repo. The tag workflow stays a draft release
when someone later pushes a `v*` tag; that is existing behavior, not
something to do for these manifests.

macOS signing runs on `macos-latest` in the `macos-sign` job, which calls
`packaging/macos/sign-release.sh`. All six repository secrets are required.
If one is empty, the job uploads the unsigned `.zip`, `.dmg`, and `.tar.gz`
and still succeeds.

| Secret | What it is |
|---|---|
| `CSC_LINK` | Base64 of the Developer ID Application `.p12`, with the private key. No `data:` prefix. |
| `CSC_KEY_PASSWORD` | Password set when that `.p12` was exported. |
| `CODESIGN_IDENTITY` | Exact string from `security find-identity -v -p codesigning`, like `Developer ID Application: Jane Example (AB12CDE3F4)`. |
| `APPLE_ID` | Apple ID email of a team member who can notarize. |
| `APPLE_APP_PASSWORD` | App-specific password for that Apple ID, not the Apple ID password. |
| `APPLE_TEAM_ID` | 10-character Team ID. |

Create the certificate on a Mac:

1. Enroll in the Apple Developer Program and create a **Developer ID Application** certificate. Not "Apple Development", not "Apple Distribution", and not "Developer ID Installer".
2. Export the certificate and its private key as a `.p12`. That export password is `CSC_KEY_PASSWORD`.
3. `base64 -i Certificates.p12` is `CSC_LINK`. Copy the identity name into `CODESIGN_IDENTITY`. Team ID from the developer account is `APPLE_TEAM_ID`.
4. Generate an app-specific password at appleid.apple.com for `APPLE_APP_PASSWORD`.

When every secret is set, the job:

1. Imports the `.p12` into a temporary keychain and deletes the keychain and the `.p12` before it exits.
2. Compiles `packaging/macos/gui-launcher.c` over `Contents/MacOS/deathterminal-gui` when that file is still a shell script. Notarization rejects a non-Mach-O main executable. The stub execs `deathterminal --gui`.
3. Signs bundled `*.dylib` files, then the other Mach-O binaries, then `YouNeeK Death Terminal.app`, inside out. Each signature uses `CODESIGN_IDENTITY`, `--options runtime`, and a secure timestamp. The app and executables get `packaging/macos/entitlements.plist` (`disable-library-validation`, `allow-jit`, `allow-unsigned-executable-memory`). `--deep` is not used. The app is not sandboxed.
4. Builds a new `.dmg` with `hdiutil` and submits it with `xcrun notarytool submit --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait`.
5. Staples the `.dmg` and the `.app`, then zips the stapled app. The staged `.tar.gz` is copied unchanged.

A notarization rejection fails the job. The submission id is in the log; `xcrun notarytool log <id>` with the same Apple credentials prints the reason. Do not weaken that job into uploading an unsigned app when the secrets were set.

Windows (`deathterminal.exe` and the NSIS setup) and Linux (`.deb`, `.rpm`, AppImage) are unsigned. Windows Authenticode, once a certificate exists outside the repo:

```sh
signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 /f cert.pfx /p "$WIN_CSC_KEY_PASSWORD" deathterminal.exe
signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 /f cert.pfx /p "$WIN_CSC_KEY_PASSWORD" deathterminal-*-setup.exe
```

Sign the exe before `makensis`, then sign the installer. Linux signatures (`dpkg-sig`, `appimagetool --sign`) are still not configured.

## Linux AppImage, deb, and rpm

`zig build release -Dpackages=true` still builds all three on this tree.
The targets themselves were not modified. On a local `zig 0.13.0` build
they came out as `deathterminal_0.1.0-1_amd64.deb`,
`deathterminal-0.1.0-1.x86_64.rpm`, and
`deathterminal-0.1.0-x86_64.AppImage`. `--version` from the archive, the
extracted `.deb`, and the AppImage (`--appimage-extract-and-run`) printed
`YouNeeK Death Terminal v0.1.0`.

The `.deb` depends on `libc6 (>= 2.31)`. The binary's highest glibc symbol
on that build was `GLIBC_2.34` (`dlopen`, `pthread_create`,
`__libc_start_main`). Ubuntu 22.04 (the release workflow's runner, glibc
2.35) satisfies that. A glibc older than 2.34 would not run the binary
even though the dependency says 2.31. That dependency line was already in
`packaging/linux/nfpm.yaml` and was left as-is.
