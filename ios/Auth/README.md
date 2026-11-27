# Death Terminal iPhone sign-in (drop-in)

Required sign-in for the iPhone app, using the **same Supabase account** as
the desktop app (project `dbtygwwaouallxdtqmmc`). No Swift packages: plain
`URLSession` + Keychain.

| File | What it is |
| --- | --- |
| `SupabaseAuth.swift` | `DTAuth`: log in, create account, reset password, refresh, sign out; session in the Keychain (`AfterFirstUnlockThisDeviceOnly`). |
| `AuthGateView.swift` | `AuthGate { ... }`: shows the black/green login screen until signed in, then your app. |

## Wiring it in (iOS 17+, SwiftUI)

1. Add both files to the app target (in Xcode: drag `ios/Auth` into the project, "Copy items if needed" off, target ticked).
2. Add the glowing green skull logo (`death-terminal-logo-full.png`) to the asset catalog as **`DTLogo`**.
3. Wrap the root view, replacing any `AuthGate` placeholder:

   ```swift
   @main
   struct DeathTerminalApp: App {
       var body: some Scene {
           WindowGroup {
               AuthGate { ContentView() }
           }
       }
   }
   ```
4. Sign out from settings: `@EnvironmentObject var auth: DTAuth` then `Task { await auth.signOut() }`.

Offline: sign-in is needed once; after that a saved session keeps working
offline and is only dropped when the server rejects it.

Not compiled in CI yet (the iPhone app target lands separately); built and
tested only by the equivalent desktop flow against the live project.
