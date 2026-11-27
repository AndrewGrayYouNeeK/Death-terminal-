# Death Terminal for iPhone

A companion SSH client for YouNeeK Death Terminal. It has the same dark look and
skull-green accents as the desktop app.

- **Hosts**: save, edit, delete, and group servers, with search. Tap a host to
  connect.
- **Terminal**: a full xterm-256color terminal (SwiftTerm) with resize, the
  Esc/Ctrl/Tab/arrow key bar, links, copy and paste, and more than one session
  at a time.
- **Keychain**: passwords, private keys, and key passphrases are stored in the
  iOS Keychain (`AfterFirstUnlockThisDeviceOnly`). You can generate an ed25519
  key on the phone and copy its public key, or import an OpenSSH key by pasting
  it or picking it from Files.
- **Known hosts**: the first time you connect to a server, you're asked to
  confirm its SHA256 fingerprint, which uses the same format as `ssh-keygen -l`.
  If a key ever changes, you get a red warning. Trusted keys are listed in the
  Known Hosts tab, and you can delete them there.
- **Snippets**: save commands and tap one to send it to the open terminal, with
  or without Enter.
- **SFTP**: browse folders, download files (with a share sheet, and the files
  also show up in Files → On My iPhone → Death Terminal → Downloads), upload
  from Files, and delete with a swipe.
- **Port forwarding**: local forwards like `ssh -L`, set up for each host.
  `localhost:<local>` on the phone goes to `<remote host>:<remote port>` as the
  server sees it.

Limits:
- iOS suspends apps in the background, so sessions and forwards only stay up
  while the app is open (or for a short time after you switch away).
- RSA keys use the older `ssh-rsa` (SHA-1) signature, which OpenSSH 8.8 and
  later turn off by default. Use ed25519 keys, which you can generate in the
  app.
- ECDSA private keys can't be imported yet. Remote (`-R`) and dynamic (`-D`)
  forwarding aren't built yet.

Sign-in: the whole UI is wrapped in `AuthGate` (`DeathTerminal/App/AuthGate.swift`).
For now it lets everyone straight through. The required email/password account
screen goes in there.

## Layout

```
ios/
  project.yml              XcodeGen spec (generates DeathTerminal.xcodeproj)
  DeathTerminal/
    App/                   App entry, AuthGate, Theme
    Models/                Hosts, keys, snippets, forwards, known hosts
    Services/              Keychain + JSON stores
    SSH/                   Citadel session, PTY, SFTP, port forwarding, host-key check
    Views/                 SwiftUI screens
    Assets.xcassets/       AppIcon (the green skull), Logo, AccentColor
  smoke/                   Linux/macOS test of the SSH core against a real sshd
```

Dependencies (Swift Package Manager, pinned in `project.yml`):
[Citadel](https://github.com/orlandos-nl/Citadel) 0.12.1 for SSH and SFTP (it's
built on SwiftNIO SSH), and [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
1.18.0 for the terminal.

## Build

You need Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
cd ios
xcodegen generate          # creates DeathTerminal.xcodeproj (not committed)
open DeathTerminal.xcodeproj
```

Pick an iPhone simulator and press Run. Xcode fetches the Swift packages the
first time you build.

Command-line simulator build (the same one CI runs):

```sh
xcodebuild -project DeathTerminal.xcodeproj -scheme DeathTerminal \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO build
```

Run `xcodegen generate` again any time you add or remove files or change
`project.yml`.

## Run on your iPhone

1. In Xcode, open Settings → Accounts and sign in with your Apple Developer
   account.
2. Select the **DeathTerminal** target, open **Signing & Capabilities**, and
   check that Team is **Andrew Gray (4NJ8T765L2)** and the bundle ID is
   `com.github.andrewgrayyouneek.deathterminal.ios`. Automatic signing creates
   the App ID and the development profile for you.
3. Plug in your iPhone (with Developer Mode on under Settings → Privacy &
   Security), choose it as the run destination, and press Run.

## TestFlight

1. In [App Store Connect](https://appstoreconnect.apple.com), go to Apps → + →
   New App. Choose iOS, name it *Death Terminal* (or whatever name is free),
   and pick the bundle ID `com.github.andrewgrayyouneek.deathterminal.ios`. If
   it isn't listed, build to a device once with automatic signing or add it
   under Certificates, IDs & Profiles → Identifiers. Use any SKU.
2. In Xcode, set the run destination to **Any iOS Device (arm64)**, then choose
   **Product → Archive**.
3. In the Organizer, choose **Distribute App → App Store Connect → Upload**.
   Leave automatic signing on.
4. Each new upload needs a higher build number. Raise
   `CURRENT_PROJECT_VERSION` in `project.yml` (and `MARKETING_VERSION` when you
   ship a new version), then run `xcodegen generate` again.
5. When processing finishes (usually 5–30 minutes), open the TestFlight tab in
   App Store Connect and answer the export-compliance question. The app uses
   standard encryption (SSH). Then add yourself or a group as testers and
   install from the TestFlight app.

Command-line alternative (uses your App Store Connect API key, which you keep
outside this repo):

```sh
xcodebuild -project DeathTerminal.xcodeproj -scheme DeathTerminal \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/DeathTerminal.xcarchive -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath build/DeathTerminal.xcarchive \
  -exportPath build/export -exportOptionsPlist ExportOptions.plist \
  -allowProvisioningUpdates \
  -authenticationKeyPath ~/path/to/AuthKey_XXXX.p8 \
  -authenticationKeyID XXXX -authenticationKeyIssuerID <issuer-id>
```

with an `ExportOptions.plist` that sets `method` to `app-store-connect`,
`teamID` to `4NJ8T765L2`, and `destination` to `upload`. Never commit the
`.p8` key.

## Tests

`smoke/run.sh` builds the app's real SSH sources on Linux or macOS. Only the
Keychain and Combine are stubbed. It starts a throwaway `sshd` on
127.0.0.1:2222 and checks:

- ed25519 login (an imported key and one generated in the app), and RSA login
  with a passphrase
- the PTY shell, with output and resize (`stty size`)
- the known-hosts prompt for a new key, no prompt once the key is trusted, and
  a changed-key warning
- SFTP list, upload, download (compared byte for byte), and delete
- a local port forward, tested with an HTTP request through the tunnel

```sh
ios/smoke/run.sh     # needs swift 5.10+, sshd, python3
```

CI (`.github/workflows/ios.yml`) runs this smoke test on Ubuntu, plus an
unsigned iOS Simulator build on macOS, whenever something under `ios/`
changes.
