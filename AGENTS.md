# Dashbar: notes for agents

Dashbar is a native macOS menu bar app (SwiftUI, SwiftPM, macOS 14+) that shows Claude Code and Codex
sessions, token usage, plan limits, local dev servers, system stats and a clean-up of rebuildable caches.
It is open source (MIT) at `stevenmckinnon/dashbar`. The product site lives in `site/` and is deployed to
Cloudflare at https://usedashbar.com/ as Workers static assets (`site/wrangler.jsonc`, deployed by `.github/workflows/site.yml`). The domain is on Cloudflare; Always Use HTTPS and a Redirect Rule (www to the apex) are set in its dashboard. Read `README.md` for what
the app does; this file is how to work on it.

## Layout

| Path | What it is |
|---|---|
| `Sources/Dashbar/` | The app. The panel UI is split by area: `DashboardView.swift` (root, tab bar, header and bottom bar), `DesignTokens.swift` (`UI` colours and sizes), `Tiles.swift`, `Components.swift` (cards, chips, buttons and other shared building blocks), and one file per tab: `PanelOverview.swift` (Now card, widgets), `PanelPlanStrip.swift` (Overview's plan limits strip and clean-up line), `OverviewRules.swift` (what Overview shows and when, tested), `PanelWorkspaces.swift` (workspace rows, session lines, quick actions), `WorkspaceDetail.swift` (usage tiles, sparkbars, process list), `PanelAgents.swift` (the Usage tab: one card per tool with its plan limits and tokens; its enum case is still `.agents`), `UsageRules.swift` (the order of those cards and when one folds, tested), `PanelServers.swift`, `PanelCleanup.swift`, `PanelSystem.swift`. `Store.swift` the state, `Collectors.swift`, `Usage.swift`, `PlanLimits.swift`, `SystemStats.swift` and `Proc.swift` read data, `Demo.swift` invents data for screenshots, `Snapshot.swift` renders PNGs, `Updater.swift` wraps Sparkle. `AppView.swift` and `AppWindow.swift` are the Dashbar window (sidebar and pages), `WorkspaceUsage.swift` what each workspace's processes use. `HostLinks.swift` the links that open a session's own conversation in T3 Code or the Claude app (see Rules), `Accounts.swift` the extra Claude Code and Codex accounts, `StatusLineBridge.swift` and `PermissionBridge.swift` the opt-in Claude Code settings edits, `History.swift` and `HistoryView.swift` the History page, `Onboarding.swift` the first run, `Pricing.swift` the cost estimate, `TodayShare.swift` today's share of a weekly limit (from plan history, tested; its alert is `TodayShareAlerts` in `LimitAlerts.swift`), `Island.swift` (state and placement, tested), `IslandView.swift` and `IslandWindow.swift` the island at the notch. `OpenCode.swift` reads OpenCode's database (sessions, usage, live state, `UI.neutralTool`), `OpenCodeBridge.swift` is its opt-in plugin and Settings row, `DemoOpenCode.swift` its demo data. `CodexSessions.swift` Codex's live sessions (`DemoCodex.swift` their demo data), `CopilotCLI.swift` reads GitHub Copilot's session folders (the CLI's, and its VS Code agent's and Copilot app's, which share them) (live state, usage from shutdown records), `CopilotBridge.swift` is its opt-in hook and Settings section, `DemoCopilot.swift` its demo data. `ToolVisibility.swift` is the "Show in Dashbar" switch per tool (hidden set, applying it to readings, `ToolPresence`, the toggle row). `GlobalShortcut.swift` holds `HotKeys` (every Carbon hot key, one handler dispatching by id) and the window's fixed ⌃⌥D; `JumpToAgent.swift` the jump shortcut: `JumpTarget` (which session, tested), `KeyCombo` (recording and showing a combination, tested) and `JumpShortcut` (saved as `jumpShortcut`, registered, its problems in words); `ShortcutRecorder.swift` the recorder row in Settings → General. `Diagnostics.swift` is Settings → About → Copy Diagnostics: a value of booleans, counts, dates, versions and Dashbar's own warnings, its Markdown (tested in `DiagnosticsTests`, which checks no path, email, name or session gets in), and the About section; add a line only after checking it can carry no project or folder name, session, account label, token, hostname or user name. |
| `Sources/DashbarStatus/`, `Sources/dashbar-cli/` | The `dashbar` command-line tool (Foundation only). `DashbarStatus` holds the status file's schema (`StatusSnapshot`), its writer, and the tool's reading and printing (tested); `dashbar-cli` is its `main.swift`. The app's side is `Sources/Dashbar/CLIStatus.swift`, which rebuilds the file from the store when a value it uses changes (at most every 3 s, written only when the content differs), and `CommandLineToolSettings.swift`, the Integrations row. `build.sh` copies the tool to `Contents/Helpers/dashbar` and signs it before the app; the cask's `binary` stanza links it. Add a field to the file only after checking it carries no prompt, title, session id or sign-in, and list it in `CLIStatusTests.allowedKeys` |
| `Sources/DashbarWidgetUI/`, `Sources/DashbarWidgets/` | The desktop widgets (spike). `DashbarWidgetUI` holds the views and what they show (`WidgetModel`, tested), shared with the app for `--snapshot --widget`; `DashbarWidgets` is the WidgetKit extension's `@main`. `build.sh` bundles it as `Contents/PlugIns/DashbarWidgets.appex` (bundle id `<app id>.widgets`, sandboxed) and signs it before the app. The app's side is `Sources/Dashbar/WidgetBridge.swift`: on each `CLIStatus` rebuild it saves `StatusSnapshot.forWidget()` (limits, agent counts, the tools switched off and today's totals per tool only: no sessions, workspaces, folders or servers) to `Widget/status.json` in the App Group container `<team>.<app id>`, and reloads the widgets at most once a minute. Ad-hoc builds have no team, so no group and no widget data. See "Widgets" below |
| `Tests/DashbarTests/` | Swift Testing suites that run against throwaway log folders (`Fixtures.swift`) |
| `build.sh` | Builds the app into `build/`, signs it, embeds Sparkle. A local build is `Dashbar Local.app`; `scripts/release.sh` (via `DASHBAR_HARDENED=1`) makes the real `Dashbar.app`. Flags: `--run`, `--install` |
| `scripts/release.sh` | Signed, notarised, stapled DMG plus the Sparkle `appcast.xml` entry |
| `scripts/make-dmg.sh`, `packaging/dmg/` | The styled installer window (arrow, caption, icon positions), built with `dmgbuild` (`pip3 install dmgbuild`). `make-background.sh` redraws `background.png`; it is 1x only because macOS 27's Finder mis-sized every Retina variant |
| `packaging/homebrew/dashbar.rb` | The cask. The live copy is in the separate `stevenmckinnon/homebrew-tap` repo |
| `site/` | Vite and React product site. `src/demos/` holds the Stageshow demos, `src/stageshow/` the vendored kit (MIT, see its `NOTICE.md`), `src/faq.js` the FAQ (also written into `index.html` as structured data at build time), `src/content.js` the rest of the page's words, `src/policy.js` the privacy policy (`/privacy`) and `src/docs.js` the docs page (`/docs`: the `dashbar` command and what each integration changes; keep it in step with the README and the app, and it is also written into `docs.html`, `/docs.md` and `/llms-full.txt`). `agent-files.js` turns those, `release-notes/` and `appcast.xml` into `/index.md`, `/llms.txt`, `/llms-full.txt`, `sitemap.xml`, the install skill and the `dashbar-status` skill under `/.well-known/agent-skills/` and `/.well-known/ai-catalog.json` at build time, so edit the copy in `content.js` or `faq.js`, never in those outputs |
| `video/` | The 30-second launch film (Remotion; dev-only, its own `package.json`). `storyboard.json` is the plan, `src/scenes/` one file per scene, `scripts/shots.sh` renders the app pictures from a local build (4x, invented demo data). `npm run render` writes `out/dashbar-launch.mp4`; the site serves a web encode as `docs/images/launch.mp4` |
| `skills/` | Agent skills, found by `npx skills add stevenmckinnon/dashbar` (skills.sh lists them as people install them). `dashbar-status/SKILL.md` tells an agent when to run `dashbar status --json` and what to do with it; every field it names must exist in `StatusSnapshot`. The site serves the same file under `/.well-known/agent-skills/`, so edit it here |
| `release-notes/` | One `X.Y.Z.md` per release (bullets of user-facing changes). Feeds Sparkle's update dialog, the GitHub release and the site's "What's new" (`site/src/releases.js`, which only shows versions that are in `appcast.xml`) |
| `docs/images/` | README pictures, the site's `og.png` and `robots.txt` (Content Signals: search, AI input and AI training all allowed); the site serves this folder as its public root. `og.png` is built from `scripts/og/og.html` by `scripts/render-og.sh` (headless Chrome); rerun it after re-rendering `overview-dark.png` |
| `appcast.xml` | The update feed. Served from `raw.githubusercontent.com/.../main/appcast.xml` |
| `scripts/stats.py`, `.github/workflows/stats.yml` | Daily copy of GitHub's release download counts (and repo traffic, with a `TRAFFIC_TOKEN` secret) to CSVs on the `stats` branch. Reads only what GitHub already keeps; the app is not involved |

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
DASHBAR_TAB=agents Dashbar --snapshot out.png --demo --dark   # render a tab with invented data (agents is the Usage tab)
DASHBAR_DEMO_WAITING=1 Dashbar --snapshot out.png --demo     # the same, with one agent waiting for permission
DASHBAR_DEMO_PERMISSION=1 Dashbar --snapshot out.png --demo  # the same, with the prompt answerable in Dashbar
DASHBAR_DEMO_RATE_LIMITED=1 Dashbar --snapshot out.png --demo  # the Claude plan limits rate-limited wait (=stale: kept limits)
DASHBAR_DEMO_QUIET=1 Dashbar --snapshot out.png --demo     # a quiet moment: all agents idle, no servers, limits at 0%
DASHBAR_DEMO_QUIET=long Dashbar --snapshot out.png --demo  # the same, with every agent idle 30m or more (no Now card)
DASHBAR_DEMO_IDLE=1 DASHBAR_TAB=agents Dashbar --snapshot out.png --demo --hosted  # Codex unused today: its Usage card folds to one line
DASHBAR_DEMO_SHARE=over DASHBAR_TAB=agents Dashbar --snapshot out.png --demo --hosted  # Claude's Weekly past today's share (also on the History page)
DASHBAR_DEMO_LOOSE_SERVER=1 Dashbar --snapshot out.png --demo  # adds a dev server outside every workspace (Overview's Servers card)
DASHBAR_DEMO_NO_LIMITS=1 Dashbar --snapshot out.png --demo # no plan limits from any tool (no strip on Overview)
DASHBAR_DEMO_CODEX=1 Dashbar --snapshot out.png --demo     # adds a working and an idle Codex session
DASHBAR_DEMO_OPENCODE=1 Dashbar --snapshot out.png --demo  # adds a working OpenCode session and its Usage card (=waiting: it needs you); also shows its Integrations row
DASHBAR_DEMO_COPILOT=1 Dashbar --snapshot out.png --demo   # adds a working GitHub Copilot session and its Usage card (=waiting: asking permission); also shows its Integrations section
DASHBAR_DEMO_HIDDEN=copilot,codex Dashbar --snapshot out.png --demo  # those tools switched off (codex, google, opencode, copilot), in memory only
DASHBAR_DEMO_TOUCH=1 Dashbar --snapshot out.png --demo     # as on a Mac with a touch display (see Touch Macs), in memory only; also works with --settings notifications
DASHBAR_DEMO_TOUCH=1 Dashbar --snapshot out.png --demo --settings notifications -islandEnabled NO  # the touch note under the island toggle (-key value is an argument default: never saved)
Dashbar --snapshot out.png --demo --widget small|medium|codex|antigravity|opencode|copilot|usage [--dark]   # one widget (small is Claude's limits, medium the overview, usage tokens today), transparent around it; docs/images/widget-*.png (the README's, and the reference for the site's HTML widgets) use DASHBAR_SNAPSHOT_SCALE=4 DASHBAR_DEMO_GOOGLE=1, from a copy outside build/ with PlugIns removed (see Widgets). (DASHBAR_WIDGET_STATE=nodata|notrunning,
                                                    # =hidden|unused for a tool's own widget with it switched off or never used,
                                                    # DASHBAR_DEMO_HIDDEN=google,copilot for the medium ones, DASHBAR_WIDGET_LOCAL=1 for the Local marker,
                                                    # DASHBAR_DEMO_OPENCODE=1 / DASHBAR_DEMO_COPILOT=1 for those tools' data,
                                                    # DASHBAR_WIDGET_TOOLS=1 for fewer rows, DASHBAR_DEMO_GOOGLE=weekly for two Antigravity groups)
Dashbar --snapshot out.png --demo --menubar all     # the menu bar item: idle|working|needsyou|done|time|all, on light (--dark) bars
Dashbar --snapshot x --demo --menubar working --onscreen   # that state in a real status item for 8s (prints its frame)
DASHBAR_APP_PAGE=storefront-web Dashbar --snapshot out.png --demo --app  # the Dashbar window (a tab name or a workspace)
DASHBAR_APP_PAGE=history DASHBAR_APP_HEIGHT=1400 Dashbar --snapshot out.png --demo --app  # the History page, in a taller window
DASHBAR_DEMO_ACCOUNTS=2 Dashbar --snapshot out.png --demo   # two Claude Code accounts, labelled
DASHBAR_DEMO_STATUSLINE=1 Dashbar --snapshot out.png --demo # Claude plan limits read from the status line
DASHBAR_DEMO_WORST=1 DASHBAR_DEMO_PERMISSION=1 Dashbar --snapshot out.png --demo --hosted  # worst case: 10 sessions, a server on 12 ports, a long command, 4 prompts
DASHBAR_ISLAND_HEIGHT=1000 DASHBAR_DEMO_WORST=1 DASHBAR_DEMO_PERMISSION=1 Dashbar --snapshot out.png --demo --island list  # a tall island, uncropped
DASHBAR_SNAPSHOT_SCALE=4 Dashbar --snapshot out.png --demo --dark   # offline panel (and --island) at 4x, sharp enough to scale up in video; not --hosted
Dashbar --snapshot x --demo --app --onscreen   # the window on screen for 8s (prints its number) for `screencapture -o -l`, which draws Liquid Glass and the sidebar's icons (the offline --app render garbles them: use this for published pictures)
Dashbar --snapshot out.png --demo --hosted                    # real scrolling panel, so native controls draw
Dashbar --snapshot out.png --demo --island finished --dark    # the island over a made-up menu bar and notch: collapsed,
                                                              # needsyou, finished, waiting, permission or list
DASHBAR_ISLAND_STYLE=floating Dashbar --snapshot out.png --demo --island collapsed  # as without a notch (or left, right)
Dashbar --snapshot x --demo --island permission --onscreen    # the real panel at the real notch for 8s (screencapture -R)
Dashbar --snapshot x --demo --island live --onscreen          # the real controller: an agent finishes at 1s, folds away at 6s
Dashbar --snapshot out.png --demo --onboarding [--dark]       # the first-run window, with invented folders
DASHBAR_DEMO_JUMP_SHORTCUT=1 Dashbar --snapshot out.png --demo --settings general  # the jump shortcut set to ⌃⌥J (=taken: refused, =othercopy: the other copy has it too), in memory only
Dashbar --snapshot out.png --demo --settings integrations [--dark]  # one Settings tab: general, notifications, menuBar, folders, accounts, integrations, about (DASHBAR_SETTINGS_HEIGHT=1200 to see a whole long tab)
DASHBAR_DEMO_ACCOUNTS=2 DASHBAR_DEMO_PERMISSION=1 Dashbar --snapshot out.png --demo --settings integrations  # two accounts, the hook in one
DASHBAR_DEMO_ACCOUNTS=missing Dashbar --snapshot out.png --demo --settings accounts  # a Work account whose folder is missing (warned, not read or counted)
Dashbar --bench                                               # collector timings
Dashbar --snapshot out.json --demo --cli                      # the dashbar command's status file, from demo data
DASHBAR_STATUS_FILE=out.json "build/Dashbar Local.app/Contents/Helpers/dashbar" line   # the tool on that file (skips the running check)
```

Offline snapshots cannot draw native AppKit controls (segmented pickers, the search field): they show as
yellow "no entry" placeholders. Crop them out or use `--hosted`. A snapshot run also writes `panelTab` into
the real app's preferences, so reset it afterwards (`defaults write fun.dashbar.app panelTab overview`).

## Touch Macs

The MacBook Pro with the PROLED XDR display has a touch screen and a Dynamic Island instead of the notch. macOS has
no API for the island, so `TouchDisplay.present` (`TouchDisplay.swift`) asks whether any screen's
`NSScreen.touchCapabilities` (macOS 27) contains `.multiTouch`, or `DASHBAR_DEMO_TOUCH=1` is set. Nobody here has that
hardware: the touch paths are checked only with the demo flag.

- The island: a new install turns it on (`Onboarding.decideAtLaunch`), except on a touch Mac, where `islandEnabled` is
  left unset (it reads as off) so Dashbar's island never sits on Apple's. A saved value is never changed, in either
  direction (`IslandSettings.enabledAtLaunch`, tested). Settings → Notifications says why under the toggle while it's off.
- The panel and the window set `\.touchFriendly` at their root. On, rows whose actions wait for a hover (Servers,
  Clean-up) always show them, and `IconButton`, `ConfirmButton`, the prompt's Allow/Deny, the gear menu and the filter's
  clear button get a 30-point hit area through `.touchTarget()`, with the drawn glyph unchanged. Off, every view must
  stay pixel-identical: compare offline renders against a build of the previous commit when touching this.

## Widgets

- The kinds (`WidgetStatus.Kind`), each a static configuration: a configurable widget needs App Intents, whose metadata
  step only Xcode runs, so a choice of tool is a widget of its own instead. Small: `fun.dashbar.widget.limits` "Claude plan
  limits", `.codex` "Codex plan limits", `.antigravity` "Antigravity plan limits" (its two tightest, named by quota group),
  `.opencode` "OpenCode usage" (tokens today, estimated cost, top model), `.copilot` "GitHub Copilot usage" (tokens and
  premium requests today, no cost). Medium: `.overview` "Plan limits and agents", `.usage` "Tokens today" (each tool that
  shows and has tokens today, with the estimated cost where the Usage tab shows one). Every kind lists in the gallery for
  everyone (chronod caches descriptors per version, so hiding one by what the user has would go stale); a widget for a
  tool that's switched off, never used or idle today says so in words (`WidgetModel.message`), never a blank or a zero.
  A new kind goes in `Kind.all` too, or the app never reloads it.
- A tool switched off in Show in Dashbar is in none of the widget data: `CLIStatus.snapshot` leaves it out and names it in
  `hidden`, and `forWidget()` drops it again (tested in `WidgetToolTests`).
- A local build's extension has `DashbarLocalBuild` in its Info.plist (build.sh), so its widgets carry a "Local" pill and
  their gallery descriptions end "From the local build." Offline renders leave it out unless `DASHBAR_WIDGET_LOCAL=1`.
- Not now: a large widget listing workspaces. The widget data deliberately holds no project names, folders or sessions:
  a desktop widget is visible to anyone near the screen. Keep it that way unless that decision is revisited.
- The extension's executable must be linked with `-e _NSExtensionMain` (Package.swift, `DashbarWidgets` linkerSettings),
  as Xcode does for app extensions. Without it the `@main` WidgetBundle's own `main` runs, ExtensionFoundation traps in
  `_EXRunningExtension._shared` on every launch, and chronod logs "query failed - will try lazy reload later": the
  gallery shows nothing. Running the binary by hand always traps (nothing launched it), so that proves nothing.
- Crash reports: `~/Library/Logs/DiagnosticReports/DashbarWidgets-*.ips`.
- chronod (which loads and refreshes widgets) logs through the unified log. Use `/usr/bin/log`, since zsh has a `log`
  builtin: `/usr/bin/log show --last 5m --info --style compact --predicate 'process == "chronod" AND eventMessage CONTAINS "dashbar"'`.
  "Updating descriptors" and "query returned 7 widget descriptors" are good; "purging instead because we shouldn't cache it"
  appears for builds that aren't notarised.
- `pluginkit -mAvvv -p com.apple.widgetkit-extension | grep -i dashbar -A3` shows which copy is registered. A rebuild in
  `build/` can take the registration from the installed copy: `lsregister -u "build/Dashbar Local.app"` gives it back.
  Running the `build/` copy (a `--snapshot` render does) registers it again, and chronod then fails every reload with
  `bundleStubNotSupported … Bundle version did not match` and backs off for an hour. Unregister the `build/` copy,
  `lsregister -f "/Applications/Dashbar Local.app"`, then restart the app and `pkill -x DashbarWidgets`.
- The gallery and placed widgets keep the old code and descriptors until the version changes or the extension restarts:
  commit (a local build's CFBundleVersion is the commit count) or `pkill -x DashbarWidgets`, then reopen the gallery.
- The site's widgets are not pictures: they are built in HTML and CSS in `site/src/demos/Widgets.tsx` (`widgets.css`),
  mirroring `DashbarWidgetUI`'s views at their real point sizes, with the same demo numbers. When the widget views change
  (layout, type, spacing, colours or the demo data), update both, then render the site's widgets at exactly 164 × 164
  and 344 × 164 pt beside a fresh `--snapshot --demo --widget` render, light and dark, and fix what differs.
- Never touch the App Group container from a shell: macOS protects it (Operation not permitted). Render widgets with
  `--snapshot --demo --widget`, and check the app's writes with the tests.

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
- Never add analytics, accounts or network calls to the app. The only allowed requests are Sparkle update checks to
  GitHub and the opt-in, experimental Claude plan limits request to `api.anthropic.com`.
- The website (`site/`) is served by Cloudflare and counts visits with Cloudflare Web Analytics, which uses no cookies. Its snippet is in
  `site/index.html` (the dev server drops it). Add nothing else: no other trackers, no cookies. If that changes,
  update the line about it in the site's Privacy section, so the site never claims more than is true.
- Claude plan limits come first from Claude Code's status line (`StatusLineBridge.swift`). Dashbar edits
  Claude Code's settings only when the user presses Add (or Remove), only the `statusLine` key, after a backup,
  re-reading the file just before writing, and refuses invalid JSON. The bridge script saves only `rate_limits`
  and a timestamp (never prompts, paths, session ids or tokens), must always run the user's previous status line
  unchanged, and sends nothing. Never touch the real `~/.claude` in tests or while developing: the installer
  takes the settings path as a parameter, so use temp folders.
- Answering permission prompts (`PermissionBridge.swift`, `PermissionPrompt.swift`) is the first feature that acts
  on agents. Its rules: strictly opt-in (the hook is added only when the user presses Add to Claude Code, with the
  same settings-editing care as the status line, and Remove takes out only Dashbar's handler); never auto-approve
  (the script prints a decision only for an answer file Dashbar writes when the user clicks); fail to the terminal
  prompt (timeout, Dashbar not running, a missing folder or any error print nothing and exit 0); Allow is once
  only, never `updatedPermissions` or `updatedInput`; leave `AskUserQuestion` and `ExitPlanMode` to Claude Code;
  keep the queue folder 0700, files 0600, ids 128 random bits; never copy file contents or edits into a request.
  Test the script only in temp folders with sample stdin; never wire it into the real Claude Code while developing.
  (A live check, when asked for, goes in a throwaway project's `.claude/settings.local.json` with `DASHBAR_PERMISSION_DIR`
  pointing at a temp queue, run as `claude --setting-sources project,local`. Claude Code shows its own prompt at once
  beside the hook, and an answer there does not stop the hook.)
- Never read, print, log or store Claude Code's token. Dashbar only reads its Keychain entry, with
  `/usr/bin/security` as Claude Code does (the entry trusts that tool, so macOS doesn't ask; reading it directly
  asked again after every renewal, since Claude Code rewrites the entry), keeps it in memory, makes one read-only request, and never refreshes or saves the sign-in. The reading it shares between
  copies (`~/Library/Caches/Dashbar/claude-plan.json`) holds usage percentages, reset times and the plan name only.
- Google's tools (`Google.swift`, `GeminiCLI.swift`, `AntigravityApp.swift`, `AntigravityBridge.swift`): never read
  `~/.gemini/oauth_creds.json` or any sign-in, and never keep message text. The Antigravity CLI bridge saves an allow-list
  of fields (quota, plan tier, and per session: folder, model, token totals, cost, state, confirmation pending), never the
  email, conversation title or transcript path in its input; add a field only by naming it in the script. It edits only
  `statusLine` in `~/.gemini/antigravity-cli/settings.json`, on Add, after a backup, reusing `StatusLineBridge`'s editing,
  and tests run it in temp folders only. The Antigravity app's `conversation_summaries.db` is opened read-only and only
  its status columns are selected (never `title`, `preview`, `raw_summary` or the `conversations_fts` tables); a schema
  without those columns shows a warning. Antigravity plan history is always saved under a hex group key
  (`AntigravityLimits.historyKey`), never in `plan-history.json`, which older copies must still be able to read.
  Everything Google stays hidden for someone who doesn't use these tools. Colour: indigo (`UI.google`) is Google's agents.
- Codex's live sessions (`CodexSessions.swift`): live means a `codex` process holds the rollout file open (listed with
  libproc; never open or lock Codex's `thread-writer-locks`, which could make Codex refuse its own write). From the first
  line only `id`, `cwd`, `originator`, `source` and `parent_thread_id`; from the rest only the type and time of
  `task_started`, `task_complete` and `turn_aborted`. Never message text. The terminal UI's background daemon
  (`--managed-daemon`) keeps a quit session's file open (seen on 0.163.0), so its session shows only while a turn runs or
  a `codex` terminal is open in its folder. Approvals and questions aren't logged: waiting needs a hook, not built.
  Checked 27 Nov 2026 with Codex 0.163.0, a temp `CODEX_HOME` and a local stand-in model server; never test against the
  real `~/.codex`.
- OpenCode (`OpenCode.swift`, `OpenCodeBridge.swift`; write the name "OpenCode" in anything people read, as opencode.ai/brand asks, and `opencode` only for the command, paths, the status file's tool id and identifiers): its database (`~/.local/share/opencode/opencode.db`, `$XDG_DATA_HOME`
  if set) is opened read-only (`mode=ro`, else `immutable`), only if it exists, and never created. From session tables
  (`session`, `session_v2`) select only `id`, `directory`, `parent_id`, `fork_session_id` and `time_*` columns; from message
  tables (`message`, `session_message`) only `session_id`, `type`, `time_*` and, through `json_extract` on `data`, the role,
  model, token counts, cost and times. Never `title`, `slug`, `summary_*`, `metadata`, `permission`, message text or content,
  or the `part`/`session_part` tables. `OpenCodeColumnGuardTests` checks every statement: add a field only by adding it
  there on purpose. A store with both layouts reads a session from `session_v2` only. An unknown schema shows a warning.
  The plugin (`dashbar.js` in `~/.config/opencode/plugins/`) is added only on Add and Remove deletes only a file starting
  with its marker (a `dashbar.js` someone else wrote is left alone). It writes exactly `session_id`, `directory`, `state`
  (working, idle, needsYou) and `written_at` per session to `~/Library/Caches/Dashbar/opencode-sessions/` (folder 0700,
  files 0600); never prompt text, tool input, titles or what a permission asks; never answers a permission; every call
  inside `try`, so it can't break OpenCode. Its state machine runs in tests in JavaScriptCore, on sample events carrying
  private text; the installer runs in temp folders only. Colour: neutral grey (`UI.neutralTool`), no new hue. No plan
  limits, so no strip. Everything OpenCode stays hidden without its database or process.
- GitHub Copilot, CLI and VS Code agent (`CopilotCLI.swift`, `CopilotBridge.swift`; "GitHub Copilot" on cards, "GitHub
  Copilot (CLI and VS Code agent)" as the Integrations heading, "Copilot" in compact session lines, `copilot` for the status
  file's tool id and identifiers). Copilot's agent in VS Code (`copilot-runtime`, `client_name: vscode-agent-host`) and the
  Copilot app (`github/autopilot`) write the same session folders and are shown too; a session is live while the pid in its
  `inuse.<pid>.lock` is alive, whatever it's called (folder and time are the fallback for a `copilot` with no lock), and a
  folder with only lock files is ignored. Copilot's hooks run in VS Code as well (seen on a real session). Its folder is `$COPILOT_HOME` else `~/.copilot`.
  From `session-state/<id>/` Dashbar reads only: folder names, file dates and sizes, `inuse.<pid>.lock` names, the top-level
  `cwd:` and `client_name:` lines of `workspace.yaml` (never `summary` or `name`), each event's `type` in the last 64 KB of
  `events.jsonl` (for working, waiting or idle), from `session.usage_record` lines only `data.usage.model`, `inputTokens`,
  `outputTokens`, `cacheReadTokens` and `cacheWriteTokens` (usage while a session runs), and from `session.shutdown` lines
  only `modelMetrics` (requests and token counts per model), `totalPremiumRequests` and `currentModel`, both found by a
  byte match before any parsing. A shutdown's totals replace that session's records since its previous shutdown (never
  both). Sessions filed under `~/.copilot/chats/` (VS Code with no folder) aren't workspaces, as OpenCode's folderless
  sessions aren't; their usage counts under "Copilot chat". Never message
  text, prompts, tool arguments or results, `codeChanges` file paths or any sign-in. Shutdown totals are cumulative across
  resumes, so only their growth is booked; a format warning shows only when every recent usage line failed. A folder with no `events.jsonl` is a session where nothing was
  typed (Copilot writes the log once a prompt is sent; checked on a real Mac), an empty scaffold or one being set up: it
  counts as no usage, not unknown, and never warns. No cost (plan-billed) and no plan limits:
  premium-request quotas need GitHub's API, and Dashbar adds no network calls. The hook is `dashbar.json` in
  `~/.copilot/hooks/` (Dashbar's own file, never anyone else's): added only on Add; Remove deletes it only if every
  command in it is Dashbar's, and a foreign or invalid `dashbar.json` is left alone. It uses only `sessionStart`,
  `userPromptSubmitted`, `postToolUse`, `notification` (`permission_prompt`, `elicitation_dialog`), `agentStop` and
  `sessionEnd` (never `preToolUse` or `permissionRequest`, where a hook's output or failure decides something). Its script
  writes exactly `sessionId`, `cwd`, `state` (working, idle, needsYou, ended) and `timestamp` to
  `~/Library/Caches/Dashbar/copilot-sessions/` (folder 0700, files 0600), never reads `prompt`, `initialPrompt`, `toolArgs`,
  `toolResult`, `transcriptPath` or a notification's `message`, prints nothing and always exits 0. Tests run it only in temp
  folders with sample stdin carrying private text, and run the reader on fixture folders; never the real `~/.copilot`.
  When checking a real session, read event `type` names only (a script printing names and counts), never anything else.
  Colour: neutral grey (`UI.neutralTool`; `UI.copilotHistory`, a lighter grey, where it stacks beside OpenCode).
- "Show in Dashbar" (`ToolVisibility.swift`): every tool but Claude Code has a switch, first in its Integrations section
  (Google's three tools share one). Off is saved as `hiddenTools` in UserDefaults (never from a `--demo` run, which uses
  `DASHBAR_DEMO_HIDDEN` in memory). Off means its collectors are not called (`Worker.otherSessions`, `scanUsage`), its paths
  aren't watched, and `LiveResult.hiding` / `UsageResult.hiding` / `Store.applyVisibility` drop anything it had, so it is
  gone from workspaces, Usage, History (Codex's and Antigravity's plan cards too), limits and alerts, notifications, the
  island, the menu bar, widgets and the status file. Plugins, hooks and status lines stay installed. Codex hidden also
  drops its Overview limits strip row and "other AI tools" chip.
- The jump shortcut (`JumpToAgent.swift`) only brings an app forward, through `HostApp.open` as a session click does. It
  never answers a permission prompt or types into a session. No shortcut by default; each copy registers only its own
  saved one. Two processes can register the same Carbon hot key without an error (seen on macOS 27), so a clash with
  the other copy is found by reading that copy's preferences, and one with another app can't be detected at all.
- Orca (`OrcaJump` in `Features.swift`) is the only app whose command Dashbar runs: on a click that goes back to a session
  in Orca, it runs the `orca` inside the Orca.app found above that session (never one from PATH) as exactly
  `worktree activate --worktree path:<root> --json`, with only `PATH` and `HOME` in its environment, reads nothing back,
  and stops it after 5 seconds; Orca is brought forward as before either way. Never on a timer or a notification arriving,
  never any other subcommand, and never to send input to a session. A session in an Orca terminal pane runs under its
  `Orca Agents.app` daemon, which `HostApp.resolvingDaemon` turns back into Orca.app.
- T3 Code and the Claude app (`HostLinks.swift`): on the same click, and only then, off the main thread, Dashbar finds the
  link to that Claude Code session's conversation. T3: the one line of `~/.t3/userdata/environment-id`, and from
  `statev2.sqlite` (opened `mode=ro`, never created) only `thread_id`, matched on the provider thread's
  `nativeThreadRef.nativeId` (`orchestration_v2_projection_provider_threads`) or, for threads T3 imported from its older
  store, the resume cursor's `resume` (`provider_session_runtime`), giving `t3code://threads/<environment>/<thread>`. Claude: the `local_*.json` file names under
  `~/Library/Application Support/Claude/claude-code-sessions/` (two folders deep) and a byte match for
  `"cliSessionId":"<id>"` or `"lastAssistantCliSessionId":"<id>"`, never parsing or keeping the rest (it holds prompt
  suggestions), giving `claude://code/continue?session=<local id>`. Nothing is cached or kept. Neither link is documented:
  a miss only leaves the app as it came forward. Tests (`HostLinksTests`) use fixtures with private stand-ins, never the
  real folders.
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
- Colour carries meaning. Green means a working agent, amber means something needs your attention soon (an agent
  waiting for you, a limit on course to run out; `UI.attention`), orange is Claude, teal is Codex, red is a problem
  (an error, a limit used up). Indigo is Google's agents (Gemini CLI, Antigravity), `UI.google`. OpenCode, GitHub Copilot CLI and any later tool are neutral grey (`UI.neutralTool`).
  Do not add decorative tints, gradients or coloured icon tiles. Workspace tiles show the project's own icon
  or a neutral monogram.
- Demo and screenshot data is invented (`Demo.swift`). Never put a real project name, path or token in
  anything that gets published.
- The site is content first: no gradients, glows, shadows at rest, mono labels or eyebrows. One typeface
  (Instrument Sans). Respect `prefers-reduced-motion`. Every demo plays once and has a Replay pill.
- Do not invent facts on the site: no user counts, quotes, star counts or prices. FAQ answers must state
  what the app really does today.
- The site's only code is `site/worker/index.js`, and it runs only for `/` (`run_worker_first`): agents that ask for `text/markdown` get `/index.md`, and both answers carry a `Link` header (Markdown copy, `llms.txt`, sitemap). Keep everything else static, so traffic spikes never use Worker requests (the free plan allows 100,000 a day). Headers for static files go in `docs/images/_headers`. Agents also find the Markdown copy through `llms.txt` and the `<link rel="alternate">` in `index.html`.
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
7. Pushing to `main` redeploys the site (`.github/workflows/site.yml`, to Cloudflare). Check the run and the live page.

The Sparkle signing key lives only in the login Keychain (public half in `Resources/sparkle-public-key.txt`).
It was backed up to a password manager. Never commit, paste or print it; losing it means installed copies
can never accept an update.

## Working style

- Do not commit, push, tag, release or change repository settings unless asked. Do not leave scratch files
  (mocks, temp renders) in the repo.
- Report what was and was not verified. If you did not look at something, say so.
