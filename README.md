DeathTerminal 💀

A brutalist, GPU-accelerated terminal with AI-native command workflows

Fast. Minimal. Unapologetically powerful.

⚡ Why DeathTerminal?

Most terminals are either:

fast but dumb (like Alacritty), or
smart but heavy (like Warp)

DeathTerminal aims for both:

low-level performance
AI-native workflows
zero visual fluff
🚀 Demo
$ docker run -
# → AI suggests:
docker run -it --rm ubuntu:latest /bin/bash
$ ssh prod
# → Auto-expands with config + port forwarding

Context-aware, not just history-based.

🔥 Core Features
🤖 AI-Native Autocomplete
Context-aware command suggestions (not just history)
gRPC-based engine (local or remote models)
Works with shell state, not just text
⚡ GPU Rendering (Vulkan)
Powered by Vulkan
Smooth under extreme output (logs, builds, streaming data)
Designed for future effects + massive scrollback
🔐 Built-in SSH + Tunneling
Persistent SSH profiles
Port forwarding made first-class
Cross-platform (no config hacks)
🔧 Lua Scripting Engine
Powered by Lua
Full control over config, hooks, and automation
Plugin system (planned)
🎯 Brutalist Design
No animations
No distractions
Maximum contrast, maximum signal
🧠 Philosophy

DeathTerminal is built on a few principles:

Speed is non-negotiable
The terminal is a programming environment, not just a shell
AI should assist, not interrupt
Every feature must justify its complexity
🏗 Tech Stack
Layer	Tech
Core	Zig
Rendering	Vulkan
AI Backend	gRPC
Scripting	Lua
⚡ Quick Start
Option 1 — Build from source
git clone https://github.com/AndrewGrayYouNeeK/Death-terminal-.git
cd Death-terminal-

zig build run
Requirements
Zig 0.13+
Vulkan SDK
Lua 5.4
🧪 Current Status

🚧 Actively in development

Done
Project structure
Build system
Core module layout
In Progress
PTY + terminal emulation
Input handling
Next Up
Vulkan renderer
AI integration
🧩 Architecture (Simplified)
PTY ↔ Terminal Core ↔ Renderer (Vulkan)
           ↓
        AI Engine (gRPC)
           ↓
        Lua Scripting
Terminal correctness comes first
Rendering is fully decoupled
AI is optional and async
🧠 AI Design (More Detail)

Unlike traditional autocomplete:

Not just command history
Understands:
previous commands
working directory
partial input

Supports:

local models (offline)
remote inference servers
🔐 Security
No credential logging
SSH handled via standard crypto libraries
AI context is sanitized before sending
🛣 Roadmap
Phase 1 — Terminal Core
PTY + process handling
ANSI/VT100 parser
Phase 2 — Rendering
Vulkan text pipeline
Glyph atlas + batching
Phase 3 — AI
Suggestion engine
Context pipeline
Phase 4 — SSH
Connection manager
Port forwarding UX
Phase 5 — Scripting
Lua API
Plugin system
🤝 Contributing

Looking for contributors interested in:

terminal emulation
low-level graphics
systems programming
AI tooling
git checkout -b feature/your-feature
❗ Non-Goals
Beginner-friendly UX
Feature bloat
Replacing your shell
🙏 Inspiration
Alacritty
Warp
Ghostty
📜 License

MIT

💀 Final Word

DeathTerminal isn’t trying to be everything.

It’s trying to be the terminal you don’t outgrow.