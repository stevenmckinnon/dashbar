# Dashbar

A native macOS menu bar dashboard for agent usage, local dev servers, and system stats.

- **Agents**: live Claude Code sessions (`~/.claude/sessions`), working/idle status, plus other agent processes it spots (Codex, Cursor, Gemini, Aider, Ollama…). Click a session to open its folder.
- **Claude Code usage**: today's tokens (in / out / cache read / cache write), a 14-day chart, and top projects and models, read incrementally from `~/.claude/projects/**/*.jsonl`.
- **Codex usage**: the same, plus 5h/weekly rate-limit gauges, from `~/.codex/sessions`. Shown once Codex has session logs.
- **Local servers**: listening TCP ports with their project name, command and uptime. Hover a row to open it in the browser or stop the process.
  Servers up over an hour that use almost no CPU are marked "barely used", and servers started from a Claude Code
  session say so (the session shows what it runs).
- **System tab**: CPU (user/system split, load average), memory (app/wired/compressed, swap, and macOS memory
  pressure), network up/down, GPU utilisation, disk, battery with time remaining, and the busiest apps right
  now with their icons. Recent samples show as small bar charts.
- **Tabs**: Overview · Agents · Servers · System · Clean-up (⌘1–⌘5). Overview tiles jump to their tab.
- **Menu bar stats** (optional, in Settings): CPU, memory, download speed and, with the Labs setting on, what's left of
  your Claude 5-hour or weekly limit, beside the icon.
- **Plan limits**: Codex's 5-hour and weekly limits from its own logs. Claude's are behind an experimental,
  off-by-default setting that reads Claude Code's sign-in from the Keychain (macOS asks first) and calls the
  same undocumented endpoint as Claude Code's `/usage`. It never refreshes or stores the sign-in. Each limit
  shows a tick for an even pace and a projection of when it would run out at the current rate.

The menu bar shows the number of working Claude sessions beside the icon, and the icon's bar fills while any are working.

## Settings

Open from the gear menu or ⌘, : which panel sections show, refresh interval, which editor and
terminal the quick actions open, notifications, launch at login, and the folders clean-up scans
(defaults to whichever of `~/Development`, `~/Developer`, `~/Projects`, `~/Code`, `~/src` exist).

If Claude Code or Codex change their log format, Dashbar shows a warning rather than silently
reporting zero.

## Performance

- Scan progress is saved to `~/Library/Application Support/Dashbar/`, so a relaunch reads only new
  transcript lines (about 30 ms instead of about 5 s for ~1 GB of logs).
- Agent log folders are watched with FSEvents rather than polled. With the panel closed, Dashbar only
  reacts to those changes plus a once-a-minute safety refresh.
- Ports, working folders, memory and command lines come from libproc, so nothing spawns `lsof` or `ps`.
- `Dashbar --bench` prints timings for each collector.

## Icon

`Resources/AppIcon.svg` is the source. `build.sh` renders it with WebKit (`scripts/render-svg.swift`,
which keeps the SVG's glow and shadow filters that macOS's own SVG renderer drops) and packages
`Resources/AppIcon.icns` whenever the SVG changes. The menu bar glyph is drawn in code from the same
proportions (`Sources/Dashbar/Brand.swift`) as a template image; its bar fills up while agents are working.
`Dashbar --snapshot glyphs.png --glyphs` previews it on light and dark menu bars.

## Build

```bash
./build.sh --run        # build build/Dashbar.app and launch it
./build.sh --install    # copy to /Applications (needed for "Launch at login")
.build/release/Dashbar --snapshot out.png --dark   # render the panel to a PNG
```

```bash
swift test              # parser, grouping and clean-up tests against throwaway log folders
.build/release/Dashbar --snapshot settings.png --settings   # render the Settings window
```

Needs macOS 14+ and Xcode / Swift 6.

## Releasing

`scripts/release.sh <version>` builds a universal (Apple silicon and Intel) app signed with a Developer ID
certificate and the hardened runtime, wraps it in a DMG, notarises it with Apple and staples the ticket.
`scripts/release.sh <version> --dry-run` does everything except notarise, with any signing identity.

One-time setup needs a paid Apple Developer membership: create a "Developer ID Application" certificate in
Xcode, then store notary credentials with `xcrun notarytool store-credentials dashbar-notary` (the script's
header has the full command). The result is `build/Dashbar-<version>.dmg`, ready to attach to a GitHub release.

## Privacy

Everything stays on your Mac. Dashbar reads local agent logs, lists listening ports and measures cache
folders. The only network request is the optional Claude plan-limits setting, which sends Claude Code's own
sign-in to Anthropic's usage endpoint, the same call Claude Code makes.

## Licence

MIT. See `LICENSE`. Not affiliated with Anthropic or OpenAI.
