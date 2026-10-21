# Code signing

The tag release stays a draft. Windows and Linux artifacts are unsigned.
macOS artifacts are signed only when every secret in this document is set
on the repository. Until then the macOS job copies the cross-compiled
`.zip`, `.dmg`, and `.tar.gz` through and the workflow still succeeds.

Nothing in this repository is a certificate, a `.p12`, or an Apple
password. Do not commit any of those.

## macOS

`packaging/macos/make-app.sh` runs `codesign --force --deep --sign -` only
when `codesign` is on `PATH`. That is an ad-hoc signature so a local Apple
silicon Mac can launch the bundle. It does not satisfy Gatekeeper.

The release workflow's `macos-sign` job runs on `macos-latest` after the
Linux cross build. It downloads the `aarch64-macos` and `x86_64-macos`
artifacts and runs `packaging/macos/sign-release.sh`.

When every secret below is set, that script:

1. Decodes `CSC_LINK` (base64 of a Developer ID Application `.p12`) and
   imports it into a temporary keychain with `CSC_KEY_PASSWORD`. The
   keychain and the `.p12` are deleted before the job exits.
2. Replaces `Contents/MacOS/deathterminal-gui` when it is still the shell
   wrapper. Notarization rejects a non-Mach-O main executable, so the job
   compiles `packaging/macos/gui-launcher.c` over that script. The stub
   execs `deathterminal --gui`.
3. Signs bundled `*.dylib` files, then the other Mach-O binaries, then
   `DeathTerminal.app`, inside out. Each signature uses `CODESIGN_IDENTITY`,
   `--options runtime`, and a secure timestamp. The app and executables
   get `packaging/macos/entitlements.plist`. `--deep` is not used.
4. Builds a new `.dmg` with `hdiutil` (`packaging/macos/make-dmg.sh`).
   `ditto` copies the signed app so the signature is preserved.
5. Submits that `.dmg` with
   `xcrun notarytool submit --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait`.
6. Staples the `.dmg` and the `.app` (`xcrun stapler staple`) and zips the
   stapled app. The `.tar.gz` staged tree is not a bundle; it is copied
   unchanged.

The release assets are the files from this job, not the Linux-built
`.zip` / `.dmg`. If any secret is missing, those Linux-built files are
the ones uploaded, and the job logs the missing names (never the values).

### Secrets

Add them as **repository** secrets (Settings → Secrets and variables →
Actions → Repository secrets). Environment secrets are not read by this
workflow.

| Secret | What it is |
|---|---|
| `CSC_LINK` | Base64 of the Developer ID Application `.p12`. No `data:` prefix and no filename. |
| `CSC_KEY_PASSWORD` | Password set when the `.p12` was exported. |
| `CODESIGN_IDENTITY` | Exact identity string, for example `Developer ID Application: Jane Example (AB12CDE3F4)`. |
| `APPLE_ID` | Apple ID email of a team member who can notarize. |
| `APPLE_APP_PASSWORD` | App-specific password for that Apple ID. |
| `APPLE_TEAM_ID` | 10-character Team ID. |

All six are required. If one is empty, nothing is signed.

### Create the certificate

1. Enroll in the Apple Developer Program. The account needs a **Developer ID Application** certificate. That is not "Apple Development", not "Apple Distribution", and not "Developer ID Installer" (Installer is for `.pkg` files).
2. On a Mac, open Keychain Access (or Xcode → Settings → Accounts → Manage Certificates) and create **Developer ID Application**. The private key must be in the login keychain.
3. In Keychain Access, select the certificate **and** its private key under My Certificates. File → Export Items → Personal Information Exchange (`.p12`). Set an export password. That password is `CSC_KEY_PASSWORD`. Exporting the certificate without the private key will not sign.
4. Confirm the identity name:

   ```sh
   security find-identity -v -p codesigning
   ```

   Copy the quoted name into `CODESIGN_IDENTITY`. It looks like `Developer ID Application: Jane Example (AB12CDE3F4)`.
5. Base64-encode the `.p12` and put that string in `CSC_LINK`:

   ```sh
   base64 -i Certificates.p12 | pbcopy
   ```

6. Team ID: [developer.apple.com/account](https://developer.apple.com/account) → Membership details → Team ID. That is `APPLE_TEAM_ID`. The same 10 characters appear in parentheses in `CODESIGN_IDENTITY`.
7. App-specific password: sign in at [appleid.apple.com](https://appleid.apple.com) → Sign-In and Security → App-Specific Passwords → generate one (for example `deathterminal-notary`). Put it in `APPLE_APP_PASSWORD`. This is not the Apple ID password. `APPLE_ID` is the email address of that account.

Push a `v*` tag after the secrets exist. The workflow does not publish the release; it leaves the GitHub release as a draft.

To see the skip path before the secrets exist, the same tag workflow is enough: the macOS job logs `Apple signing secrets are absent (...)` and uploads the unsigned artifacts.

### Entitlements

`packaging/macos/entitlements.plist` is applied to the app and to the Mach-O executables:

- `com.apple.security.cs.disable-library-validation` — the app `dlopen`s MoltenVK. The release does not bundle it unless `MOLTENVK_DIR` was set for the cross build, and the Homebrew cask depends on the `molten-vk` formula (`/opt/homebrew/lib`). Hardened runtime would block that library without this entitlement. Dylibs that are inside the bundle are still signed with the same identity.
- `com.apple.security.cs.allow-jit` and `com.apple.security.cs.allow-unsigned-executable-memory` — MoltenVK / Metal and the Zig runtime allocate executable memory. Without these, a hardened process is killed on first use.

The app is not sandboxed. Sandbox entitlements are not required for Developer ID notarization.

### MoltenVK

If `MOLTENVK_DIR` was set when the artifact was built, `libMoltenVK.dylib` (and `libvulkan.1.dylib` when present) are in `Contents/Frameworks` and are signed in the same pass as the other bundled dylibs. A missing dylib is not an error: the loader then uses Homebrew or the software renderer.

### If notarization is rejected

`xcrun notarytool submit --wait` fails the job when Apple rejects the upload. The log has the submission id. A common follow-up:

```sh
xcrun notarytool log <submission-id> --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD"
```

The cross-compiled `.app` has no Apple SDK, and it has not been run on a Mac. The first acceptance may need a fix in the bundle (bundle id `com.github.andrewgrayyouneek.deathterminal`, minimum system 11.0). Do not weaken the job into uploading an unsigned file when the secrets were set: a signing or notarization failure fails the release on purpose.

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
