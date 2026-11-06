# Dashbar

A native macOS menu bar dashboard for agent usage, local dev servers, and system stats.

- **Agents**: live Claude Code sessions (`~/.claude/sessions`), working/idle status, plus other agent processes it spots (Codex, Cursor, Gemini, Aider, Ollama…). Click a session to open its folder.
- **Claude Code usage**: today's tokens (in / out / cache read / cache write), a 14-day chart, and top projects and models, read incrementally from `~/.claude/projects/**/*.jsonl`.
- **Codex usage**: the same, plus 5h/weekly rate-limit gauges, from `~/.codex/sessions`. Shown once Codex has session logs.
- **Local servers**: listening TCP ports with their project name and command. Hover a row to open it in the browser or stop the process.
- **System**: CPU with sparkline, memory, disk, battery, uptime.

The menu bar icon turns into ✨N while N Claude sessions are working.

## Build

```bash
./build.sh --run        # build build/Dashbar.app and launch it
./build.sh --install    # copy to /Applications (needed for "Launch at login")
.build/release/Dashbar --snapshot out.png --dark   # render the panel to a PNG
```

Needs macOS 14+ and Xcode / Swift 6.
