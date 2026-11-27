# Account sign-in

YouNeeK Death Terminal asks you to create an account or log in the first
time it opens. Nothing runs until you do: every tab, split and SSH window
starts behind the sign-in screen.

## The sign-in screen

```
  [1] Log in
  [2] Create account
  [3] Forgot password
  [q] Quit
```

- **Create account**: email plus a password of 8 or more characters. If the
  project requires email confirmation you get a link by email; click it, then
  choose **Log in**.
- **Forgot password**: sends a reset link to the email.
- **Quit** closes the window.

## Commands

| Command | What it does |
| --- | --- |
| `deathterminal --login` | Sign in from any terminal (or show who is signed in). |
| `deathterminal --whoami` | Show the signed-in account. |
| `deathterminal --sign-out` | Sign out (alias `--logout`). Open tabs keep running; new ones ask you to log in. |

## Where the session is kept

- macOS: the login Keychain, item `com.github.andrewgrayyouneek.deathterminal.auth`
  (falls back to the file below if the Keychain cannot be written).
- Linux: `$XDG_CONFIG_HOME/death-terminal/session.json` (`~/.config/...`), mode 0600.
- Windows: `%APPDATA%\death-terminal\session.json`.

Only the session tokens are stored, never your password.

## Offline

You need the internet to sign in the first time. After that the saved
session keeps working offline, even once its access token has expired. When
you are back online it is refreshed; it is only dropped if the server
rejects it (you signed out, or the account was deleted).

## Backend

Supabase Auth (email and password). Only the public project URL and the
public anon key are in the app. Builds can point elsewhere:

```
zig build -Dsupabase-url=https://<ref>.supabase.co -Dsupabase-anon-key=<anon key>
```

`zig build -Dauth=false` builds without the sign-in gate (development only).
