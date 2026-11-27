# Henad: the setup assistant

*The architecture of understanding.*

`deathterminal --henad` opens Henad, a chat assistant that helps you install, configure, and connect Death Terminal, then shows you the rest of it.

Henad works in two stages, and the first line it prints tells you which one is active.

| Stage | When | Where your questions go |
|---|---|---|
| **Offline** (stage 1) | Always available, and the default | Local Ollama on your computer (`http://localhost:11434`). Nothing leaves the machine. |
| **Online** (stage 2) | The machine is online **and** you signed in with `/signin` | The live Henad service at `https://henad.youneek.dev` (`POST /agent/chat`), under your own Henad account |

```
$ deathterminal --henad
Henad · The architecture of understanding.
Mode: OFFLINE · local Ollama (llama3.2:latest). Nothing leaves this machine.
Online Henad: not signed in. Type /signin to use your own Henad account.
```

## Stage 1: offline (local Ollama)

Offline Henad handles getting connected: config, Ollama, the model, shell integration, SSH, and network problems. It explains error messages and suggests the next command.

- It reads the same check as `deathterminal --ai-setup` and gives that to the local model as context.
- It finds your installed models from Ollama's `/api/tags`. It uses `config.ai.model` when that model is installed, and otherwise the first chat model it finds (embedding models are skipped). `--henad-model <name>` picks one.
- It only ever calls local Ollama. If `config.ai.endpoint` points at a remote server, Henad ignores it and uses `http://localhost:11434/v1`.
- If Ollama isn't running, or has no model, Henad says exactly what to do (`ollama serve`, `ollama pull qwen2.5-coder:0.5b`) and prints the built-in check. It does not crash or hang.

## Stage 2: online (your Henad account)

Once you are connected, online Henad guides you through everything else: Time Travel, Ghost Run, SSH profiles, plugins, sharing, themes, and so on.

- **Detection.** At start, on `/status`, and after `/signin`, Henad checks that the Henad service answers (a 2.5 s connect check) and that your session is valid (`GET /auth/me`). Both have to pass for online mode.
- **Fallback.** If the service stops answering or your session expires, the answer comes from offline Henad instead, with a note that it switched. `/offline` (or `--henad-offline`) keeps you offline. `/online` allows online mode again.
- **Sign-in.** `/signin` asks for the email and password of *your own* Henad account (sign up at https://henad.youneek.dev). The password is sent once to `POST /auth/login` and is not stored. On macOS and Linux it isn't shown while you type. The session token the service returns is saved to `~/.config/death-terminal/henad-session` (`%APPDATA%\death-terminal\henad-session` on Windows), with mode 0600 on macOS and Linux. `/signout` logs the session out and deletes that file.
- **No built-in credentials.** Death Terminal ships no token, API key, or owner login. `HENAD_SESSION` can supply a session token (for scripts). `HENAD_URL` or `--henad-url` points Henad at a different server (for testing).
- **What gets sent online.** Only your question, the last few turns of this conversation, and a one-line tag naming Death Terminal and your OS. Secrets are redacted before sending, using the same redaction as the AI features. The local check and your files are not sent.

## Commands it suggests

Henad puts commands in code blocks and lists them under each answer. **Nothing runs on its own.**

```
Suggested commands (nothing runs until you type /run N and confirm):
  1. rm -rf ~/.config/death-terminal   [destructive]
  2. deathterminal --ai-setup
```

- `/run N` shows the command and asks `Run it? [y/N]`.
- A destructive command (the Ghost Run list: `rm -r`, `git reset --hard`, `curl | sh`, truncating `>`, and the rest, plus `sudo`, `rm`, `shutdown`, `kill -9` and similar) is marked `[destructive]`, prints a warning, and runs only if you type `run it`. `y` or `yes` is not enough.

## Chat commands

| Command | What it does |
|---|---|
| `/run N` | Run suggested command N after confirming |
| `/status` | Re-check Ollama, the network, and your session, then show the mode |
| `/models` | List local Ollama models |
| `/signin`, `/signout` | Use your own Henad account, or forget the session |
| `/offline`, `/online` | Stay offline, or allow online mode again |
| `/doctor` | Print the built-in check |
| `/clear`, `/quit` | Forget this conversation, or leave |

`deathterminal --henad "why is the AI offline?"` asks one question and exits. It never runs commands.
