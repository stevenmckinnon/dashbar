# Dashbar: notes for agents

Dashbar is a native macOS menu bar app (SwiftUI, SwiftPM, macOS 14+) that shows Claude Code and Codex
sessions, token usage, plan limits, local dev servers, system stats and a clean-up of rebuildable caches.
It is open source (MIT) at `stevenmckinnon/dashbar`. The product site lives in `site/` and is deployed to
GitHub Pages. Read `README.md` for what the app does; this file is how to work on it.

## Layout

| Path | What it is |
|---|---|
| `Sources/Dashbar/` | The app. `DashboardView.swift` is the whole panel UI, `Store.swift` the state, `Collectors.swift`, `Usage.swift`, `PlanLimits.swift`, `SystemStats.swift` and `Proc.swift` read data, `Demo.swift` invents data for screenshots, `Snapshot.swift` renders PNGs, `Updater.swift` wraps Sparkle |
| `Tests/DashbarTests/` | Swift Testing suites that run against throwaway log folders (`Fixtures.swift`) |
| `build.sh` | Builds `build/Dashbar.app` (signs it, embeds Sparkle). Flags: `--run`, `--install` |
| `scripts/release.sh` | Signed, notarised, stapled DMG plus the Sparkle `appcast.xml` entry |
| `packaging/homebrew/dashbar.rb` | The cask. The live copy is in the separate `stevenmckinnon/homebrew-tap` repo |
| `site/` | Vite and React product site. `src/demos/` holds the Stageshow demos, `src/stageshow/` the vendored kit (MIT, see its `NOTICE.md`), `src/faq.js` the FAQ (also written into `index.html` as structured data at build time) |
| `docs/images/` | README pictures and the site's `og.png`; the site serves this folder as its public root |
| `appcast.xml` | The update feed. Served from `raw.githubusercontent.com/.../main/appcast.xml` |

## Run it

```bash
swift build                  # debug build
swift test                   # all tests; run before any commit
./build.sh --install         # release build into /Applications (stable signing keeps Keychain and permissions)
open /Applications/Dashbar.app

cd site && npm install && npm run dev   # the site, with hot reload
cd site && npm run build                # must pass before committing site changes
```

Useful flags on the binary (run it from `build/Dashbar.app/Contents/MacOS/Dashbar`, since the bare `.build`
binary cannot find `Sparkle.framework`):

```bash
DASHBAR_TAB=agents Dashbar --snapshot out.png --demo --dark   # render a tab with invented data
Dashbar --snapshot out.png --demo --hosted                    # real scrolling panel, so native controls draw
Dashbar --bench                                               # collector timings
```

Offline snapshots cannot draw native AppKit controls (segmented pickers, the search field): they show as
yellow "no entry" placeholders. Crop them out or use `--hosted`. A snapshot run also writes `panelTab` into
the real app's preferences, so reset it afterwards (`defaults write fun.dashbar.app panelTab overview`).

## Verify what you ship

- After `./build.sh --install`, check the installed binary is the new build: compare its modified time and run
  `strings /Applications/Dashbar.app/Contents/MacOS/Dashbar | grep "<a string you just added>"`. Once an install
  silently kept the old build. Swift strings of 15 bytes or fewer are inline and will not appear in `strings`.
- Quit the running app before judging a change: `pkill -x Dashbar`, then open it again.
- UI changes: look at a render or the running app before saying it works. Tests do not cover appearance.
- Site changes: check the page in a browser at about 390, 905 and 1280 px wide, light and dark, with no
  horizontal overflow. The 12-column sections break between roughly 900 and 1180 px, so test that range.

## Rules

**Privacy and safety (the product's promise: it sends nothing)**
- Never add analytics, accounts or network calls. The only allowed requests are Sparkle update checks to
  GitHub and the opt-in Claude plan limits request to `api.anthropic.com`.
- Never read, print, log or store Claude Code's token. Dashbar only reads its Keychain entry (macOS asks
  first), makes one read-only request, and never refreshes or saves the sign-in.
- Clean-up only moves rebuildable folders (`node_modules`, `.next`, build output, DerivedData) to the Trash
  after confirmation. Never delete permanently.
- Do not scan outside the user's chosen folders and the project's own folder for icons.

**Code**
- Swift 6 toolchain in Swift 5 language mode. No new dependencies without a clear reason; Sparkle is the only one.
- Collectors read incrementally and cache (see the Performance notes in the README). Do not spawn `lsof` or
  `ps`; use libproc. Keep the panel cheap when it is closed.
- When Claude Code or Codex change their log format, show a warning. Never silently report zero.
- Add or update a test for any parser, grouping or summary change. Tests use fixtures, never the real
  `~/.claude` or `~/.codex`.

**Design (app and site)**
- Colour carries meaning. Green means a working agent, orange is Claude, teal is Codex, red is a problem.
  Do not add decorative tints, gradients or coloured icon tiles. Workspace tiles show the project's own icon
  or a neutral monogram.
- Demo and screenshot data is invented (`Demo.swift`). Never put a real project name, path or token in
  anything that gets published.
- The site is content first: no gradients, glows, shadows at rest, mono labels or eyebrows. One typeface
  (Instrument Sans). Respect `prefers-reduced-motion`. Every demo plays once and has a Replay pill.
- Do not invent facts on the site: no user counts, quotes, star counts or prices. FAQ answers must state
  what the app really does today.
- Site demos mirror the app. When a visual in the app changes (tiles, header icons, card layout), update
  `site/src/demos/` to match, then re-render `docs/images/` and re-check the demos' heights.

## Release

Only when the user asks. A release publishes publicly and cannot be quietly undone.

1. `swift test`, then `git push origin main` with everything committed.
2. `scripts/release.sh X.Y.Z`: builds a universal app, signs it with the Developer ID certificate, notarises
   through the `dashbar-notary` keychain profile, staples, and adds the entry to `appcast.xml`. If signing the
   DMG fails once with `errSecInternalComponent`, rerun it.
3. Put the printed SHA-256 into `packaging/homebrew/dashbar.rb` (version and sha256), commit `appcast.xml`
   and the cask, push, then `git tag vX.Y.Z && git push origin vX.Y.Z`.
4. `gh release create vX.Y.Z build/Dashbar-X.Y.Z.dmg --title "Dashbar X.Y.Z" --notes-file <notes>`.
5. Copy the cask into `stevenmckinnon/homebrew-tap` under `Casks/dashbar.rb` and push.
6. Pushing to `main` redeploys the site (`.github/workflows/pages.yml`). Check the run and the live page.

The Sparkle signing key lives only in the login Keychain (public half in `Resources/sparkle-public-key.txt`).
It was backed up to a password manager. Never commit, paste or print it; losing it means installed copies
can never accept an update.

## Working style

- Do not commit, push, tag, release or change repository settings unless asked. Do not leave scratch files
  (mocks, temp renders) in the repo.
- Report what was and was not verified. If you did not look at something, say so.
