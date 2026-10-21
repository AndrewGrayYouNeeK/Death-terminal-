# Code signing

Nothing in CI is signed. The workflows have no certificates, Apple IDs, or
notarization secrets, and this repo does not store any. The steps below are
the ones to add when those secrets exist. Until then the artifacts are
unsigned on purpose.

## macOS

`packaging/macos/make-app.sh` runs `codesign --force --deep --sign -` only
when `codesign` is on `PATH`. That is an ad-hoc signature so a local Apple
silicon Mac can launch the bundle. It does not satisfy Gatekeeper for anyone
else. Cross-compiled CI builds have no `codesign`, so the `.app` and `.dmg`
ship unsigned.

TODO, once a Developer ID Application certificate is available:

1. Import the certificate into a temporary keychain on a macOS runner
   (`CSC_LINK` / `CSC_KEY_PASSWORD`, or `CODESIGN_IDENTITY`).
2. Sign the bundle, inside out, with a secure timestamp and the hardened
   runtime: `codesign --sign "$CODESIGN_IDENTITY" --options runtime --timestamp --deep "YouNeeK Death Terminal.app"`.
3. Notarize the DMG: `xcrun notarytool submit DeathTerminal-*.dmg --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait`.
4. Staple the ticket: `xcrun stapler staple DeathTerminal-*.dmg`.

MoltenVK, if bundled via `MOLTENVK_DIR`, has to be signed in the same pass.
Do not commit the certificate or the app-specific password.

## Windows

`deathterminal.exe` has an icon and a version resource. The NSIS setup exe
(`deathterminal-<ver>-x86_64-setup.exe`) has the same icon and version
metadata. Neither is Authenticode-signed, so SmartScreen will warn.

TODO, once a code-signing certificate is available (pfx in the secret store,
not in the repo):

```
signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 /f cert.pfx /p "$WIN_CSC_KEY_PASSWORD" deathterminal.exe
signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 /f cert.pfx /p "$WIN_CSC_KEY_PASSWORD" deathterminal-*-setup.exe
```

Sign the exe before `makensis` packs it, then sign the installer. WiX
(`packaging/windows/wix/deathterminal.wxs`) is still an optional skeleton and
is not produced by CI.

## Linux

The `.deb`, `.rpm`, and AppImage are unsigned. That matches a GitHub release
asset; users check `SHA256SUMS`.

TODO, only if there is an apt repository or a signed AppImage feed:

- `dpkg-sig --sign builder` on the `.deb`, with a GPG key kept as a CI secret.
- `appimagetool --sign` with the same kind of key.

No GPG key is configured today.
