# AI command suggestions

YouNeeK Death Terminal suggests how to finish the command you are typing and can
explain why the last command failed. It talks to any **OpenAI-compatible
chat/completions endpoint** over plain HTTP/JSON with SSE streaming. The
default is a local [Ollama](https://ollama.com) at
`http://localhost:11434/v1` with the small `qwen2.5-coder:0.5b` model, so
nothing leaves your machine unless you point it somewhere else.

> **Why HTTP and not gRPC.** The original README planned a gRPC AI
> service. That plan is dropped: the OpenAI-style HTTP/JSON API is what
> Ollama, llama.cpp's server, vLLM, LM Studio, OpenAI, Groq, OpenRouter and
> friends all speak, it needs no code generation or extra C dependency
> (only Zig's `std.http` and `std.json`), and it streams fine over SSE.
> There is no gRPC code in the tree.

## Using it

| Key | What it does |
| --- | --- |
| *(type, then pause ~300 ms)* | A dim **ghost text** completion appears after the cursor |
| `Tab` | Accept the ghost text (`config.ai.accept_key` changes the key) |
| `Esc` | Dismiss it |
| `Alt+]` / `Alt+[` | Next / previous alternative (the `(1/3)` counter shows when there are several) |
| `Ctrl+Shift+A` | **Explain / fix the last error**: an overlay at the top with the cause and a corrected command (`Esc` closes it) |

- Nothing is ever inserted without your accept. Ghost text is drawn by the
  renderer only; the shell never sees it.
- When no suggestion is showing, `Tab`, `Esc` and `Alt+]` go to the shell
  exactly as before (so shell completion still works).
- Typing the next characters of a suggestion keeps the rest of it; typing
  something else drops it and asks again after the pause.
- Suggestions are shown only at a prompt on the normal screen (never in
  vim, less, htop ... on the alternate screen) and only when the cursor is
  at the end of the line.
- `select_all` moved from `Ctrl+Shift+A` to `Ctrl+Shift+Alt+A`.

### Offline

If the endpoint is unreachable, times out or returns an error, nothing pops
up: a small **`AI offline`** badge appears in the bottom-right (or
top-right) corner, and suggestion requests back off (5 s, doubling up to
60 s) so a missing server costs nothing. An explicit `Ctrl+Shift+A` always
tries and, if it fails, says so in the overlay. The badge goes away after
the next successful request or when the config is reloaded with a new
endpoint/model.

## Setup

Ollama (default):

```sh
ollama serve &               # if it is not already running as a service
ollama pull qwen2.5-coder:0.5b
```

Anything else OpenAI-compatible, in `config.lua`:

```lua
config.ai.endpoint = "https://api.openai.com/v1"
config.ai.model = "gpt-4o-mini"
config.ai.api_key_env = "OPENAI_API_KEY"   -- the NAME of the variable
```

Grok 4.7 (the model Grok Bot uses) on the xAI API. `api.x.ai` and
`us.api.x.ai` are sent to `/v1/responses`, not `/chat/completions`:

```lua
config.ai.endpoint = "https://api.x.ai/v1"  -- or "https://us.api.x.ai/v1"
config.ai.model = "grok-4.7"
config.ai.api_key_env = "XAI_API_KEY"
config.ai.reasoning = "low"                 -- low | medium | high | xhigh
config.ai.timeout_ms = 20000
```

`reasoning` defaults to `low` on those hosts (empty in the config means
that) and is ignored everywhere else. grok-4.7 cannot turn reasoning off;
`high` is the server default and is too slow for ghost text. Live search
is forced off, and the response is not stored. Reasoning text is dropped;
only the visible answer becomes ghost text or the explain overlay.
`ai.max_tokens` is sent as `max_output_tokens`, which caps that visible
answer; reasoning tokens are not counted against it. xAI hosts wait at
least 15 seconds even when `timeout_ms` is lower, because the model
thinks before the first token. A higher `timeout_ms` (up to 600000) is
used as-is.

The API key is read from that environment variable when a request is made.
It is never stored in the config; a value that looks like a key (e.g.
`sk-...`) in `api_key_env` is rejected with an error. The key is sent only as
`Authorization: Bearer ...` to the configured endpoint, and redirects are
not followed.

All options (see also [CONFIG.md](CONFIG.md)):

| Option | Default | Meaning |
| --- | --- | --- |
| `ai.enabled` | `true` | Master switch (`--no-ai` overrides) |
| `ai.endpoint` | `http://localhost:11434/v1` | Base URL (http or https). `{endpoint}/chat/completions`, or `{endpoint}/responses` on api.x.ai and us.api.x.ai |
| `ai.model` | `qwen2.5-coder:0.5b` | Model name sent to the server (`grok-4.7` on xAI) |
| `ai.reasoning` | `""` | `""` = `low` on api.x.ai, ignored elsewhere; or `low`, `medium`, `high`, `xhigh` |
| `ai.api_key_env` | `""` | Name of the env var holding the key (`""` = no auth; `XAI_API_KEY` for Grok) |
| `ai.timeout_ms` | `5000` | Give up after this long (200–600000). x.ai waits at least 15s |
| `ai.debounce_ms` | `300` | Typing pause before asking |
| `ai.max_tokens` | `64` | Visible tokens per suggestion. On xAI this is `max_output_tokens` |
| `ai.explain_max_tokens` | `400` | Tokens per explain answer |
| `ai.history` | `5` | Previous commands (with exit codes) sent as context |
| `ai.output_lines` | `20` | Lines of recent output sent as context |
| `ai.accept_key` | `"tab"` | Chord that accepts the ghost text |
| `shell.integration` | `true` | Load the OSC 133 shell integration (restart) |

## What is sent

Every request contains, after redaction:

- the command line typed so far,
- the working directory (from OSC 7),
- the last `ai.history` commands and their exit codes,
- the tail of the last command's output (`ai.output_lines` lines), or the
  screen above the prompt when the shell sends no marks,
- the shell name and OS.

**Redaction** (`src/ai/redact.zig`, with its own test suite) runs on all of
it before it leaves the process and replaces with `[REDACTED]`:

- provider tokens: OpenAI `sk-...`, GitHub `ghp_/gho_/ghu_/ghs_/ghr_/github_pat_`,
  GitLab `glpat-`, AWS `AKIA/ASIA...`, Slack `xox?-`, Google `AIza...`,
  Hugging Face `hf_`, npm `npm_`, JWTs,
- PEM private key blocks,
- `Authorization: Bearer/Basic/token ...` credentials,
- `password=`, `token: ...`, `"api_key": "..."` style assignments and
  env-looking `UPPER_SNAKE=value` assignments (except harmless ones such as
  `PATH`, `HOME`, `EDITOR`),
- `--password x`, `sshpass -p x`, `mysql -pSECRET`, `scheme://user:pass@host`,
- long random-looking strings (≥32 characters mixing cases and digits).

Ordinary commands (git SHAs, `docker -p 8080:80`, `mkdir -p`, paths) are
left alone; the tests list the cases.

## Shell integration (OSC 133)

To know exactly what you typed, where each command's output starts and how
it exited, the shell marks its prompt with OSC 133 (`A` prompt start, `B`
input start, `C` command start, `D;<exit>` finished) and reports the
directory with OSC 7. YouNeeK Death Terminal ships snippets for bash, zsh and fish
in [`shell-integration/`](../shell-integration) and **injects them
automatically** (`shell.integration = true`):

- **bash**: started as `bash --rcfile <runtime dir>/bashrc`, which sources
  your `~/.bashrc` and then the snippet. Skipped when `shell.args` is set
  (e.g. `{ "-l" }`), so custom invocations are left alone.
- **zsh**: `ZDOTDIR` points at a directory whose `.zshenv` restores your
  `ZDOTDIR`, sources your `.zshenv`, then installs `precmd`/`preexec` hooks;
  your `.zshrc` etc. load normally afterwards.
- **fish**: `--init-command "source .../fish.fish"`. fish 4 already emits
  the command marks and OSC 7, so only the prompt marks are added there.

The runtime directory is `$XDG_RUNTIME_DIR/deathterminal` or
`/tmp/deathterminal-<uid>` (mode 0700; refused if someone else owns it).
To source a snippet yourself instead (e.g. with `shell.integration = false`
or over ssh; sourcing it twice is harmless):

```sh
deathterminal --print-shell-integration bash > ~/.config/deathterminal/bash.sh
echo '[ "$TERM_PROGRAM" = DeathTerminal ] && . ~/.config/deathterminal/bash.sh' >> ~/.bashrc
```

Without the marks (other shells, a remote host without the snippet)
suggestions still work: the input is guessed from the cursor row (the text
after the first `$ `, `# `, `% `, `> `, `❯ ` prompt ending) and the recent
screen is used as context. Explain then describes the visible output.

## How it works

- `src/ai/openai.zig`: blocking client (`stream: true`, SSE parser,
  plain-JSON fallback). `api.x.ai` / `us.api.x.ai` use the Responses API;
  every other host uses chat/completions. Cancellable from another thread
  by shutting the socket down, per-request receive timeout.
- `src/ai/engine.zig`: one background worker thread. The UI submits a job;
  a new keystroke cancels the running request. Streamed text comes back
  through a mutex-guarded buffer and a wake pipe in the event loop's
  `poll`, so the UI thread never waits on the network.
- `src/ai/context.zig`: prompt building (with redaction) and reply parsing
  (strips numbering, bullets, `$ ` and backticks; keeps only lines that
  extend what you typed; no control characters).
- `src/app/ai_controller.zig`: debounce, ghost text, explain overlay,
  status badge.
- `src/terminal/shell_integration.zig`: OSC 133 tracking (input, command
  history with exit codes and output tails).
- Tests run against `src/ai/mock_server.zig`, a scripted local HTTP server
  (streaming, plain JSON, HTTP errors, refused connections, hangs/timeouts,
  cancellation, auth header).

## Limits

- Small local models give rough suggestions; a bigger model
  (`qwen2.5-coder:1.5b`/`7b`, or a hosted one) is noticeably better.
- `ai.timeout_ms` covers the whole request, including name resolution and
  `connect()` (`src/net/dial.zig`), so an unroutable endpoint gives up on
  time and shows "AI offline". Requests to `api.x.ai` and `us.api.x.ai`
  wait at least 15s so grok-4.7 can finish its reasoning trace.
- In an SSH window (`--ssh`) the context says the session is remote
  ("over SSH to user@host") and leaves out the local OS and shell; the
  usual redaction applies. Without OSC 133 on the remote shell, the prompt
  is found heuristically (see [SSH.md](SSH.md#ai)).
- Ghost text is single-line and drawn up to the end of the cursor row.
- Each request opens a fresh connection (no keep-alive).
