# Contributing to Dashbar

Thanks for helping. Dashbar is a native macOS menu bar app (SwiftUI, SwiftPM, macOS 14+) under the MIT licence.
Open an [issue](https://github.com/stevenmckinnon/dashbar/issues) before a large change so we can agree on it first.

## Layout

- `Sources/Dashbar/`: the app. `DashboardView.swift` is the panel, `Store.swift` the state, `Collectors.swift`, `Usage.swift`, `PlanLimits.swift`, `SystemStats.swift` and `Proc.swift` read data, `Demo.swift` invents data for screenshots, `AppView.swift` and `AppWindow.swift` are the Dashbar window.
- `Tests/DashbarTests/`: Swift Testing suites that run against throwaway log folders (`Fixtures.swift`).
- `site/`: the product site, a Vite and React app deployed to GitHub Pages by `.github/workflows/pages.yml`. Its pictures come from `docs/images`, rendered with `Dashbar --snapshot … --demo`.
- `release-notes/`: one `X.Y.Z.md` per release.

## Run the tests

```bash
swift test
```

Run them before every commit. Tests use fixtures and never read the real `~/.claude` or `~/.codex`.
For the site: `cd site && npm install && npm run build` must pass before you commit site changes (`npm run dev` for hot reload).

## Local build and the release build

```bash
./build.sh --run        # build build/"Dashbar Local.app" and launch it
./build.sh --install    # copy to /Applications as "Dashbar Local" (needed for "Launch at login"), beside any installed release
.build/release/Dashbar --snapshot out.png --dark   # render the panel to a PNG
.build/release/Dashbar --snapshot settings.png --settings integrations   # render one Settings tab (general, notifications, menuBar, folders, accounts, integrations, about)
```

`build.sh` makes a local build unless `DASHBAR_HARDENED=1`, which only `scripts/release.sh` sets. A local build is a
separate app so it can sit beside an installed release: `Dashbar Local.app`, bundle id `fun.dashbar.app.local`, its own
settings and cache folder, no Sparkle feed, and a version from `git describe`. It is marked as local in the UI.

Quit the copy you are testing with `pkill -x "Dashbar Local"` before opening a new build. Never `pkill -x Dashbar`:
that quits the installed release. Offline snapshots cannot draw native AppKit controls (they show as yellow "no entry"
placeholders); use `--hosted` for those. Look at a render or the running app before saying a UI change works.

## Performance notes

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

## Rules for changes

**Privacy and safety.** Dashbar's promise is that it sends nothing.
- No analytics, accounts or new network calls. The only allowed requests are Sparkle update checks to GitHub and the opt-in, experimental Claude plan-limits request to `api.anthropic.com`.
- Claude plan limits come first from Claude Code's status line (`StatusLineBridge.swift`). Dashbar edits Claude Code's settings only when the user presses Add (or Remove), only the `statusLine` key, after a backup, and refuses invalid JSON. The bridge script saves only `rate_limits` and a timestamp, always runs the user's previous status line unchanged, and sends nothing. Tests and development never touch the real `~/.claude`: the installer takes the settings path as a parameter.
- Answering permission prompts (`PermissionBridge.swift`) is the only feature that acts on an agent. It is opt-in, never answers by itself (the script prints a decision only for an answer Dashbar writes when the user clicks), falls back to the terminal prompt on a timeout or any error, allows once only (never `updatedPermissions`), and keeps its queue user-only. Test the script only in temp folders.
- Never read, print, log or store Claude Code's token. Dashbar reads its Keychain entry with `/usr/bin/security`, as Claude Code does, keeps it in memory, makes one read-only request, and never refreshes or saves the sign-in.
- Clean-up only moves rebuildable folders (`node_modules`, `.next`, build output, DerivedData) to the Trash after confirmation. Never delete permanently.
- Do not scan outside the user's chosen folders and the project's own folder for icons.

**Code.**
- Swift 6 toolchain in Swift 5 language mode. No new dependencies without a clear reason; Sparkle is the only one.
- Collectors read incrementally and cache. Do not spawn `lsof` or `ps`; use libproc. Keep the panel cheap when it is closed.
- When Claude Code or Codex change their log format, show a warning. Never silently report zero.
- Add or update a test for any parser, grouping or summary change.

**Design.** Colour carries meaning: green is a working agent, amber is something needing attention soon, orange is Claude, teal is Codex, red is a problem. No decorative tints, gradients or coloured icon tiles. Demo and screenshot data is invented (`Demo.swift`): never put a real project name, path or token in anything published. The site is content first (no gradients, glows or shadows at rest, one typeface), makes no claims it cannot back up (no user counts, quotes or prices), and its demos mirror the app: when a visual in the app changes, update `site/src/demos/` and re-render `docs/images/`.

## Releasing (maintainer)

`scripts/release.sh <version>` builds a universal (Apple silicon and Intel) app signed with a Developer ID
certificate and the hardened runtime, wraps it in a DMG, notarises it with Apple and staples the ticket.
`scripts/release.sh <version> --dry-run` does everything except notarise, with any signing identity.
After notarising it signs the DMG for Sparkle and adds an entry to `appcast.xml`, the update feed the app reads;
commit that file once the GitHub release exists. The signing key lives in the login Keychain
(`Resources/sparkle-public-key.txt` is its public half), so back it up with Sparkle's `generate_keys -x`.

One-time setup needs a paid Apple Developer membership: create a "Developer ID Application" certificate in
Xcode, then store notary credentials with `xcrun notarytool store-credentials dashbar-notary` (the script's
header has the full command). The result is `build/Dashbar-<version>.dmg`, ready to attach to a GitHub release.

