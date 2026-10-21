# Time Travel

Time Travel remembers what each command did to its working directory, and can put that directory back.

It runs in the GUI. Headless mode does not take snapshots. A remote SSH pane is skipped: the path on this machine is not the directory the remote command changed.

## What gets saved

When the shell emits OSC 133 C (command start), the terminal snapshots the current directory before it parses the rest of that output. The directory comes from OSC 7 (`file://…`). Until a prompt has reported one, the command is recorded as `cwd unknown` and nothing is walked.

The snapshot stays inside that directory:

- Symlinks are stored as the link text. They are not opened, and a link that points outside the tree does not pull those bytes in.
- Paths are relative. A manifest entry that is absolute or contains `..` is rejected, and the rewind stops.
- A root `.gitignore` is applied (last rule wins, `!` puts a path back, `*` and `?` do not cross `/`).
- `config.time_travel.excludes` is the same kind of list. The defaults skip `node_modules`, `.git/objects`, `zig-cache`, `.zig-cache`, `zig-out`, `target`, `__pycache__`, `.venv`, `venv` and `dist`. `.git` itself is saved; remove `.git/objects` from the list to save git objects too. An empty list keeps every file the `.gitignore` does not reject.
- Excluded directories are not walked and are not deleted on rewind.
- The walk stops at about 50 000 files or 40 levels. A tree bigger than `max_dir_mb` (default 200) is not stored.

Files are content-addressed under the data directory (`$XDG_DATA_HOME/death-terminal/time-travel`, or `%LOCALAPPDATA%\death-terminal\time-travel` on Windows). Identical bytes are stored once. Placement tries APFS `clonefile` on macOS, a `FICLONE` reflink on Linux, then a byte copy. The snapshot tree may hardlink those stored blobs. A rewind never hardlinks into the live tree, so a later edit cannot change the snapshot.

## After the command

OSC 133 D records the exit code and a diff: added, removed and modified paths (a file counts as modified when its bytes or mode change; a symlink when its target changes). Unreadable paths are marked and are not deleted or overwritten on rewind.

`config.time_travel.ai_summary` (default on, and only when `config.ai.enabled` is on) asks the existing AI endpoint for one line describing the diff. The prompt is redacted the same way as other AI requests. A summary is not started while a suggestion is on screen. It shows up on that command's row when it arrives.

`retention` (default 50) is how many commands each pane keeps. The store drops snapshots nothing on screen still points at, including the undo snapshot.

## The overlay

| Keys | Action |
|---|---|
| Ctrl+Alt+T | Open or close Time Travel. On macOS, Cmd+Option+T |
| Up / Down | Scrub the session, oldest at the top |
| Enter | Ask before rewinding to just before the selected command |
| y / Enter | Rewind |
| n / Esc | Cancel the confirm, or close the overlay |
| u | Undo the last rewind |

Ctrl+Shift+T and Cmd+T stay **New Tab**. On macOS, Command without Option is matched as Ctrl+Shift, so Cmd+Shift+T cannot be a different action. Cmd+Option+T is Time Travel.

Rewind is refused while a command is still running, when that command had no snapshot, or when the folder is now larger than `max_dir_mb` (the rewind has to be undoable). It only writes into the directory the snapshot was taken from.

The rewind itself is one undo: `u` puts back the tree from just before the rewind.
