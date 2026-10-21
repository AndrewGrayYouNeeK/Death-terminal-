# Muscle memory

Muscle memory watches commands you already run and offers to save a repeated sequence as a shortcut. It stays on this machine: no network calls, no model.

Shell integration (OSC 133) records each finished command with its working directory and exit code. Those records are appended to a local history file. When the same 2–5 commands run in order, in the same project, at least three times, YouNeeK Death Terminal asks:

> You run these together a lot. Make it a shortcut?

The same sentence is a toast. A notice at the top of the window lists the commands and waits for an answer, because a toast cannot take a key.

## Saving

| Key | What it does |
| --- | --- |
| `y` or Enter | Ask for a name, then save the shortcut for this project |
| `n` or Esc | Dismiss this sequence and do not ask again |
| Ctrl+Shift+P | The same offer is in the command palette: save it for this project, or for every directory |

At the name prompt, Enter saves and Esc cancels. A name is 1–32 characters: it starts with a letter, digit, or `_`, and the rest may also use `-` and `.`. Prefix the name with `*` to save it for every directory instead of this project.

Example: `*ship` is a global shortcut named `ship`.

## Running

Type the name at the prompt and press Enter, or pick **ship** (the shortcut's name) in the command palette (Ctrl+Shift+P).

- When the shell has sent OSC 133, each command is sent on its own. The first one is prefixed with Ctrl+U so the name you typed is cleared. A non-zero exit stops the rest and a toast names the command and the exit code. An unknown exit code is not a failure.
- When the shell has not sent OSC 133, the sequence is one line joined with ` && `, so the shell stops on the first failure.
- A shortcut does not start while another command is still running.
- Typing during a running shortcut (for example answering `git commit`) is left alone. A second Enter is swallowed only while the line still shows the shortcut name.

## Projects and global shortcuts

A project is the nearest parent directory that contains `.git` (a directory or a file). If the working directory is not inside a repository, the key is the directory itself. A path that does not exist is used as written and is not walked upward.

A project shortcut wins over a global one with the same name. Global shortcuts are ones you save yourself (palette, or a `*` name). Sequences are not mined across projects.

The palette lists every shortcut. Each one can be run, renamed, or deleted. Rename uses the same name prompt. Delete removes it from the file immediately.

Opening the palette reloads `shortcuts.lua` when the file changed on disk, unless a shortcut is currently running or a prompt is up. Ctrl+Shift+R (reload config) reloads it as well.

## Files

| File | Role |
| --- | --- |
| `$XDG_CONFIG_HOME/death-terminal/shortcuts.lua` | Saved shortcuts. Default `~/.config/death-terminal/shortcuts.lua`. On Windows, `%APPDATA%\death-terminal\shortcuts.lua` |
| `$XDG_STATE_HOME/death-terminal/muscle-history` | Command history used for mining. Default `~/.local/state/death-terminal/muscle-history`. On Windows, `%LOCALAPPDATA%\death-terminal\muscle-history` |
| `$XDG_STATE_HOME/death-terminal/muscle-dismissed` | Sequences you dismissed |

Files are created mode `0600` and replaced by writing a temporary file and renaming it.

`shortcuts.lua` is ordinary Lua that returns a table. It is loaded in a sandbox with no `io`, `os`, or `debug`:

```lua
return {
  global = {
    { name = "ship", commands = { "git status", "git diff" } },
  },
  projects = {
    ["/home/me/app"] = {
      { name = "check", commands = { "zig build", "zig build test" } },
    },
  },
}
```

`global` runs in every directory. `projects` is keyed by git root, or by the working directory when there is no repository. You can edit the file by hand. A command that looks like it contains a secret is skipped on load and rejected when saving.

## Secrets

Commands are checked with the same redaction the AI engine uses (`src/ai/redact.zig`). If redaction changes the text, the command is not stored: not in the history file, and not in a shortcut. A shortcut that contains such a command is dropped on load. The redacted text is not kept either.

## Config

```lua
config.muscle_memory.enabled = true  -- default
config.muscle_memory.min_repeats = 3 -- 2–50; how many repeats before the offer
config.muscle_memory.max_len = 5     -- 2–8; longest sequence, in commands
```

`enabled = false` stops recording, offers, and running shortcuts. Counts are non-overlapping: `echo a` four times in a row is two pairs, not three. A longer sequence hides a shorter one in the same project when it occurs at least as often. Only the last 256 commands in a project are mined. Offers already shown this session, or dismissed earlier, are not shown again. An existing shortcut with the same commands is not offered again.

The directory recorded for a command is the one the shell reports after the command finishes, which is the directory `cd` landed in.
