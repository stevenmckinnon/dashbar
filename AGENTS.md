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
| `build.sh` | Builds the app into `build/`, signs it, embeds Sparkle. A local build is `Dashbar Local.app`; `scripts/release.sh` (via `DASHBAR_HARDENED=1`) makes the real `Dashbar.app`. Flags: `--run`, `--install` |
| `scripts/release.sh` | Signed, notarised, stapled DMG plus the Sparkle `appcast.xml` entry |
| `scripts/make-dmg.sh`, `packaging/dmg/` | The styled installer window (arrow, caption, icon positions), built with `dmgbuild` (`pip3 install dmgbuild`). `make-background.sh` redraws `background.png`; it is 1x only because macOS 27's Finder mis-sized every Retina variant |
| `packaging/homebrew/dashbar.rb` | The cask. The live copy is in the separate `stevenmckinnon/homebrew-tap` repo |
| `site/` | Vite and React product site. `src/demos/` holds the Stageshow demos, `src/stageshow/` the vendored kit (MIT, see its `NOTICE.md`), `src/faq.js` the FAQ (also written into `index.html` as structured data at build time) |
| `release-notes/` | One `X.Y.Z.md` per release (bullets of user-facing changes). Feeds Sparkle's update dialog, the GitHub release and the site's "What's new" (`site/src/releases.js`, which only shows versions that are in `appcast.xml`) |
| `docs/images/` | README pictures and the site's `og.png`; the site serves this folder as its public root. `og.png` is built from `scripts/og/og.html` by `scripts/render-og.sh` (headless Chrome); rerun it after re-rendering `overview-dark.png` |
| `appcast.xml` | The update feed. Served from `raw.githubusercontent.com/.../main/appcast.xml` |

## Run it

```bash
swift build                  # debug build
swift test                   # all tests; run before any commit
./build.sh --install         # local build into /Applications/Dashbar Local.app, beside the installed release
open "/Applications/Dashbar Local.app"

cd site && npm install && npm run dev   # the site, with hot reload
cd site && npm run build                # must pass before committing site changes
```

Useful flags on the binary (run it from `build/Dashbar Local.app/Contents/MacOS/Dashbar Local`, since the bare `.build`
binary cannot find `Sparkle.framework`):

```bash
DASHBAR_TAB=agents Dashbar --snapshot out.png --demo --dark   # render a tab with invented data
DASHBAR_DEMO_WAITING=1 Dashbar --snapshot out.png --demo     # the same, with one agent waiting for permission
Dashbar --snapshot out.png --demo --hosted                    # real scrolling panel, so native controls draw
Dashbar --bench                                               # collector timings
```

Offline snapshots cannot draw native AppKit controls (segmented pickers, the search field): they show as
yellow "no entry" placeholders. Crop them out or use `--hosted`. A snapshot run also writes `panelTab` into
the real app's preferences, so reset it afterwards (`defaults write fun.dashbar.app panelTab overview`).

## Local builds and the release

`build.sh` makes a local build unless `DASHBAR_HARDENED=1` (only `scripts/release.sh` sets it). A local build is a
separate app so it can sit beside the installed release: `Dashbar Local.app`, bundle id `fun.dashbar.app.local`,
process name `Dashbar Local`, its own settings and cache folder, no Sparkle feed (it never offers to update), and a
version from `git describe` (like `0.4.0-3-gabc1234-dirty`). It is marked as local in the UI: a "Local" pill in the
panel header, a dot on the menu bar icon, a "LOCAL" band on the Dock icon, the popout title and Settings → About.
`BuildInfo.isLocal` (`Brand.swift`) drives all of it; offline snapshots never show the marker, so README and site
images stay clean.

## Verify what you ship

- After `./build.sh --install`, check the installed binary is the new build: compare its modified time and run
  `strings "/Applications/Dashbar Local.app/Contents/MacOS/Dashbar Local" | grep "<a string you just added>"`. Once an install
  silently kept the old build. Swift strings of 15 bytes or fewer are inline and will not appear in `strings`.
- Quit the running app before judging a change: `pkill -x "Dashbar Local"`, then open it again. Never `pkill -x Dashbar`:
  that quits the installed release, which may be the copy the user is relying on.
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
- Colour carries meaning. Green means a working agent, amber means an agent is waiting for you (`UI.attention`),
  orange is Claude, teal is Codex, red is a problem.
  Do not add decorative tints, gradients or coloured icon tiles. Workspace tiles show the project's own icon
  or a neutral monogram.
- Demo and screenshot data is invented (`Demo.swift`). Never put a real project name, path or token in
  anything that gets published.
- The site is content first: no gradients, glows, shadows at rest, mono labels or eyebrows. One typeface
  (Instrument Sans). Respect `prefers-reduced-motion`. Every demo plays once and has a Replay pill.
- Do not invent facts on the site: no user counts, quotes, star counts or prices. FAQ answers must state
  what the app really does today.
- Site demos mirror the app. When a visual in the app changes (tiles, header icons, card layout), update
  `site/src/demos/` to match, then re-render `docs/images/` (and `og.png` with `scripts/render-og.sh`) and re-check the demos' heights.

## Release

Only when the user asks. A release publishes publicly and cannot be quietly undone.

1. Write `release-notes/X.Y.Z.md` (Markdown, what changed for users). Sparkle shows it in the update dialog,
   the site's "What's new" and step 5's GitHub release all use it. `release.sh` refuses to run without it.
2. `swift test`, then `git push origin main` with everything committed.
3. `scripts/release.sh X.Y.Z`: builds a universal app, signs it with the Developer ID certificate, notarises
   through the `dashbar-notary` keychain profile, staples, and adds the entry to `appcast.xml`. If signing the
   DMG fails once with `errSecInternalComponent`, rerun it.
4. Put the printed SHA-256 into `packaging/homebrew/dashbar.rb` (version and sha256), commit `appcast.xml`
   and the cask, push, then `git tag vX.Y.Z && git push origin vX.Y.Z`.
5. `gh release create vX.Y.Z build/Dashbar-X.Y.Z.dmg --title "Dashbar X.Y.Z" --notes-file build/github-release-X.Y.Z.md`
   (`release.sh` builds that body from the notes file plus the install line and SHA-256).
6. Copy the cask into `stevenmckinnon/homebrew-tap` under `Casks/dashbar.rb` and push.
7. Pushing to `main` redeploys the site (`.github/workflows/pages.yml`). Check the run and the live page.

The Sparkle signing key lives only in the login Keychain (public half in `Resources/sparkle-public-key.txt`).
It was backed up to a password manager. Never commit, paste or print it; losing it means installed copies
can never accept an update.

## Working style

- Do not commit, push, tag, release or change repository settings unless asked. Do not leave scratch files
  (mocks, temp renders) in the repo.
- Report what was and was not verified. If you did not look at something, say so.
