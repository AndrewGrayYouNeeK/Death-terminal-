# Ghost Run

Ghost Run holds Enter when the command at the prompt matches a risky pattern. The shell does not see the newline until you choose **Run**. The preview is computed locally and does not execute the command.

## What you see

The overlay lists the command, a short impact summary, and detail lines when they fit. With `config.ghost_run.ai_explain` and `config.ai.enabled`, a plain-English note is added underneath. That note is optional. The file and git estimates do not use the model.

| Key | Effect |
| --- | --- |
| `y` | Run the command |
| `n`, Esc, Ctrl+C | Cancel. The newline is dropped |
| `t` | Run after a Time Travel snapshot, when that feature is registered |
| Enter | Does nothing. A second Enter does not confirm |

`t` is hidden when no snapshot provider is registered. If a snapshot fails, the overlay stays up and the command is not run.

## Config

```lua
config.ghost_run.enabled = true      -- default
config.ghost_run.ai_explain = true   -- default; also needs config.ai.enabled
-- config.ghost_run.patterns = { "rm -r", "dd" }
```

`enabled` defaults to true. `ai_explain` defaults to true and still does nothing while AI is off.

`patterns` is optional. Until you assign it, the built-in list below is used. Assigning a list, including `{}`, **replaces** that list. An empty list matches nothing.

Each pattern is 1–200 characters, with no newline. At most 64.

## Built-in patterns

```
rm -r
rm -R
rm --recursive
git reset --hard
git clean
git push --force
git push --force-with-lease
git push -f
dd
mkfs*
chmod -R
chown -R
find -delete
find -exec
find -execdir
mv:overwrite
>
curl | sh
wget | sh
```

The first matching pattern wins.

### How a pattern matches

There is no regex. The line is split on quotes, pipes, and statement separators (`&&`, `||`, `;`, `&`). Wrappers are skipped: `sudo`, `doas`, `command`, `exec`, `nohup`, `time`, `nice`, `stdbuf`, `env`, and `NAME=value`.

The first pattern token is the command name (`mkfs*` matches `mkfs.ext4`). Later tokens are flags or positional words that must appear, in order. A short cluster such as `-rf` satisfies `-r` and `-f`. `--recursive` matches `-r` / `-R`. `--force` matches `-f`. A long option matches that option only: `--force` does not match `--force-with-lease` (that is its own pattern).

`git clean` matches unless the command is a dry run (`-n` / `--dry-run`).

`curl | sh` and `wget | sh` match when the left side is that client and the right side is a shell (`sh`, `bash`, `dash`, `ash`, `zsh`, `ksh`, `fish`, `csh`, `tcsh`).

`>` matches a truncating redirect. It does not match `>>` or a file-descriptor copy such as `>&1`.

`mv:overwrite` matches `mv` when the destination already exists. That check is a stat. On an SSH pane it is skipped, so the pattern does not match there.

`$(...)` and backticks are not executed. A command that contains them can still match, and those words are not expanded in the preview.

## What the preview measures

Nothing here runs your command, and nothing is sent through a shell.

| Pattern | Read-only estimate |
| --- | --- |
| `rm`, `chmod -R`, `chown -R` | Glob and walk the paths. Count files and bytes. Symlinks are not followed. `/` is not walked |
| `>` | Size of the file that would be truncated |
| `mv:overwrite` | Paths that already exist and would be replaced |
| `find -delete` | Names a simple `-name` / `-iname` / `-type` expression would delete. `-exec` is reported and not walked |
| `git reset --hard` | `git diff` and `git diff --cached` names, plus a short `git log` |
| `git clean` | `git clean -n` with only `-d`, `-x`, `-X`, `-e`, and safe pathspecs. `-f` is never passed |
| `git push --force` | `git log` of commits the remote has that this branch does not (`git log` only) |
| `dd`, `mkfs*` | The device or file operands named on the line. They are not opened for writing |
| `curl \| sh` | The URL, not fetched |

Walks stop after 4000 entries or about 200ms and say the preview is partial. Git commands use a fixed argument list, time out after about 1.5s, and are killed if they do not finish.

SSH panes (`--ssh` or a profile) do not walk the remote machine. The overlay says so. A local pane uses the OSC 7 directory when the host is this machine, `localhost`, or empty. Without that, counts that need a directory are skipped.

## AI note

When `ghost_run.ai_explain` and the AI engine are both on, the overlay asks the same Ollama or xAI endpoint as suggestions. The prompt says the command has not run, includes the local summary, and is passed through the same redaction as other AI requests. The reply is capped at a few lines. It is not the "explain last error" notice.

Turning `ai_explain` off leaves the local preview as it is.

## Time Travel

Ghost Run does not take snapshots itself. Another part of the terminal can register a provider:

```zig
const time_travel = @import("ghost/time_travel.zig");

time_travel.register(.{
    .ctx = ctx,
    .available = available, // fn (*anyopaque) bool
    .snapshot = snapshot,   // fn (*anyopaque, SnapshotRequest) SnapshotResult
});
```

`SnapshotRequest` is `{ cwd, command, pane }`. `snapshot` must not run `command`. It is called only after the user presses `t`. `SnapshotResult` is `ok` (with an id), `unavailable`, or `failed` (with a message). `unregister` removes the provider. With nothing registered, `t` is hidden.

## Headless

`window.headless` prints the same preview on stderr and reads one key: `y`, `n`, Esc, Ctrl+C, or `t`. Only a lone `\r`, `\n`, or `\r\n` is intercepted. A paste that already includes the command and the newline is written through, because the command is not on screen as the current input yet. Headless does not request the AI note.

## What is not intercepted

- Enter while a program is running, on the alternate screen, or when the cursor is not at the end of the input
- Modified Enter (for example Alt+Enter)
- Keypad Enter in application keypad mode (that key is not a submit)
- Bytes a plugin writes to the pane
- Startup layout commands
