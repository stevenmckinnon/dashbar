# Dashbar

A free, open-source Mac menu bar app that shows which Claude Code and Codex agents are working, how much of your plan is left and when it runs out, and which dev servers are idling.

**[Website](https://usedashbar.com/)** · [Download](https://github.com/stevenmckinnon/dashbar/releases/latest) · [Homebrew](#install) · [What's new](https://github.com/stevenmckinnon/dashbar/releases)

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/overview-dark.png">
    <img src="docs/images/overview-light.png" alt="Dashbar's Overview tab: the working agent's workspace with its quick actions, the other workspaces, each tool's tightest plan limit and the size of rebuildable caches" width="360">
  </picture>
  &nbsp;
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/agents-dark.png">
    <img src="docs/images/agents-light.png" alt="Dashbar's Usage tab: one card per tool with its plan limits and pace, today's tokens and estimated cost, and an hourly chart" width="360">
  </picture>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/window-dark.png">
    <img src="docs/images/window-light.png" alt="The Dashbar window: a sidebar of pages and workspaces, and a workspace's page with its uptime, CPU, memory and energy, its dev server, its agent and the processes behind the numbers" width="740">
  </picture>
</p>

## Install

**Download:** get the latest `Dashbar-x.y.z.dmg` from [Releases](https://github.com/stevenmckinnon/dashbar/releases/latest),
open it and drag Dashbar to Applications. It's signed with a Developer ID and notarised by Apple. Universal (Apple silicon and Intel); needs macOS 14 or later.

**Homebrew:**

```bash
brew install --cask stevenmckinnon/tap/dashbar
```

Dashbar checks for updates itself (Settings → About → Check for Updates…).

## Features

- **Agents**: live Claude Code sessions (`~/.claude/sessions`), working/idle status, and "needs you" when Claude has stopped to ask for permission or an answer (it sorts first, in amber, with a count beside the menu bar icon), plus other agent apps and CLIs it spots running (T3 Code, Codex, Cursor, Aider, Ollama…). Click a session to go back to the app it runs in (its terminal, VS Code, T3 Code or the Desktop app); right-click it to open its folder in your editor or Finder.
- **Subagents**: when a session hands work to subagents (the Agent tool, in the foreground or background), the panel says so under it ("3 subagents running", opening into a list with each one's task and how long it has run), and the Dashbar window lists them under their session with type, model, tokens and status. Finished ones drop off after a minute or so. Read from each live session's `subagents` folder beside its transcript; their tokens are counted once in the usage totals, in the project each worked in, and the usage card shows the share they used.
- **Claude Code usage**: tokens for today, the last 7 days or the last 14 (in / out / cache read / cache write), an hourly or daily chart, and in the Dashbar window the top workspaces and models, read incrementally from `~/.claude/projects/**/*.jsonl`.
- **Codex usage**: the same, plus 5h/weekly rate-limit gauges, from `~/.codex/sessions`. Shown once Codex has session logs.
- **Gemini CLI and Antigravity** (shown only if you use them): Gemini CLI sessions as agents in their workspaces (a running
  `gemini` process, working while its session log is being written) and their tokens and estimated cost per model, read
  incrementally from `~/.gemini/tmp/*/chats/*.jsonl`. The Antigravity app's conversations (working, idle or waiting for you)
  from the status columns of its `~/.gemini/antigravity/conversation_summaries.db`, opened read-only; never titles, previews
  or transcripts. For the Antigravity CLI (`agy`), Settings → Integrations → Antigravity CLI → Add to Status Line points its
  [status line](https://antigravity.google/docs/cli/statusline/) at a small script that saves only the plan quota and tier
  and each session's folder, model, token totals, estimated cost and state to `~/Library/Caches/Dashbar/antigravity-*`,
  then runs your own status line as before. Dashbar then shows Antigravity's 5-hour and weekly limits per model group with
  their pace (and in History), its usage with the CLI's own cost estimate, and its sessions, "needs you" when it asks to
  confirm a tool. Never your email or conversations. Remove puts your previous status line back exactly.
- **More than one account**: if you run Claude Code with [`CLAUDE_CONFIG_DIR`](https://code.claude.com/docs/en/authentication#log-in-with-multiple-accounts) (say `~/.claude-work` beside `~/.claude`) or Codex with `CODEX_HOME`, add each folder in Settings → Accounts (Dashbar suggests `~/.claude-*` and `~/.codex-*` folders with logs, looking only at the top of your home folder). It reads every account's sessions and usage, names them by account (only once there's more than one), and shows each Claude account's plan limits from its own status line, saved to `~/Library/Caches/Dashbar/claude-statusline-<id>.json`.
- **Estimated cost**: what the period's tokens would cost at public API list prices, per model and project, worked out on your Mac from the token counts (a guide for subscribers, not a bill; models without a known price are named, never counted as $0). Settings → General can hide it.
- **History**: a page in the Dashbar window (or click a card's header on the Usage tab) with each 5-hour and weekly plan window's peak over the last 30 days (how often you hit the limit; with more than one account, one card per account), the current window against an even pace, and 30 days of tokens and estimated cost per day by agent, project and model. Plan readings are kept for 90 days in `~/Library/Application Support/Dashbar/plan-history.json` (usually tens of KB; each extra account beside it as `plan-history-<id>.json`); usage comes from the scan Dashbar already does.
- **Local servers**: listening TCP ports with their project name, command and uptime. Hover a row to open it in the browser or stop the process.
  Servers up over an hour that use almost no CPU are marked "barely used", and servers started from a Claude Code
  session say so (the session shows what it runs).
- **System tab**: CPU (user/system split, load average), memory (app/wired/compressed, swap, and macOS memory
  pressure), network up/down, GPU utilisation, disk, battery with time remaining, and the busiest apps right
  now with their icons. Recent samples show as small bar charts.
- **Dashbar window**: the arrow button in the panel header, or ⌃⌥D from anywhere, opens Dashbar as a full window: the panel's pages and every running workspace in a sidebar. A workspace's page shows its uptime, CPU, memory and energy (its servers, agents, what they started and anything else working in its folder), its dev servers and agents, and the processes behind the numbers. There's a pin to keep it on top; ⌃⌥D again closes it.
- **Island** (Settings → Notifications; on for new installs): when an agent finishes or stops for you, a black banner grows out of the MacBook notch (or just below the middle of the menu bar on other screens) with the session's title and project, then folds back into the notch after a few seconds (hover holds it open). Click it to go back to the session; with answering permission prompts on, Allow once and Deny work right there. Between moments it draws nothing, so the notch and the menus around it are untouched. Optionally it keeps a small status beside the notch (amber "needs you", else green "working") that lists your sessions on hover; that can cover the last menus of a menu-heavy app. If another app already draws at the notch, it sits just below that app's (or choose left or right of the notch), and it can stand in for the matching notifications.
- **First run**: a short welcome window says what Dashbar reads and lets you turn on notifications, open at login and Claude plan limits. macOS asks about notifications only when you turn one on. It's in the gear menu as Welcome… later.
- **Notifications** (each can be turned off in Settings): when an agent finishes a stretch of work, when it needs you, and when a plan limit runs low: at 80%, when it's on course to run out before it resets, when it's used up, and when a used-up limit resets, once per window.
- **Tabs**: Overview · Usage · Servers · System · Clean-up (⌘1–⌘5). Overview puts what needs you first: waiting permission prompts, then the workspace whose agent is waiting, working or went idle in the last 10 minutes, the other workspaces, servers outside them, a strip with each account's tightest plan limit (click it for Usage) and, from 1 GB, a line to Clean-up. Usage has one card per tool, the one closest to running out of plan first: its plan limits with their pace, the period's tokens with the estimated cost, a chart and the in / out / cache split. One Today · 7d · 14d choice at the top drives every card and is kept between launches; with two or more tools in use, a line above the cards adds them up. A tool with no usage in the period and no limits folds to one line.
- **Menu bar stats** (optional, in Settings): CPU, memory, download speed and, with Claude plan limits on, what's left
  of your Claude 5-hour or weekly limit, beside the icon.
- **Plan limits**: Codex's 5-hour and weekly limits from its own logs. Claude's come from Claude Code's
  [status line](https://code.claude.com/docs/en/statusline), which Claude Code passes your usage after each
  reply (Pro, Max and Ultra plans). Off until you choose Settings → Integrations → Add to Status Line: Dashbar then
  sets `statusLine` in `~/.claude/settings.json` (or `$CLAUDE_CONFIG_DIR`) to a small script,
  `~/Library/Application Support/Dashbar/claude-statusline-bridge.sh`, that saves only the `rate_limits` part
  and the time to `~/Library/Caches/Dashbar/claude-statusline.json`, then runs the status line you had before,
  if any, with the same input, so it looks the same. It keeps a backup of the settings file (in
  `~/Library/Application Support/Dashbar/Backups`), and Remove puts your previous status line back exactly. No
  network, no Keychain. The reading is as fresh as your last Claude Code reply, and Dashbar says how old it is.
  Each limit shows a tick for an even pace and a projection of when it would run out at the current rate.
- **The older, experimental way** (off by default, under Experimental in Integrations): read Claude Code's sign-in from the Keychain the
  way Claude Code does (with macOS's `security` tool, so macOS doesn't ask again each time Claude Code renews
  it) and call the same undocumented endpoint as Claude Code's `/usage`. It never refreshes or stores the
  sign-in. If Claude rate-limits the request, Dashbar keeps the last reading and waits before asking again;
  copies of Dashbar on the same Mac share their last reading (`~/Library/Caches/Dashbar/claude-plan.json`,
  percentages and reset times only) so only one of them asks. With both on, Dashbar shows the newer reading
  and doesn't ask while the status line's is current.
- **Answer permission prompts** (off by default, in Integrations): when Claude Code is about to ask you to allow a tool,
  Dashbar shows what it wants to do (the command, file or address) under that session, in the window and on the
  "needs permission" notification, with Allow once and Deny. Open session hands the prompt back to the terminal
  and takes you there. Choosing Add to Claude Code puts one
  [`PermissionRequest` hook](https://code.claude.com/docs/en/hooks#permissionrequest) in `~/.claude/settings.json`
  (after a backup, keeping any hooks you have) pointing at
  `~/Library/Application Support/Dashbar/claude-permission-bridge.sh`. The script leaves the request in
  `~/Library/Application Support/Dashbar/Permissions` (readable only by you, file contents and edits left out)
  and waits up to 5 minutes (adjustable) for your answer. Claude Code keeps its own prompt up in the terminal the
  whole time, so you can answer in either place, and a prompt answered in the terminal leaves Dashbar. It never
  answers by itself: if you don't answer, Dashbar isn't running, or anything goes wrong, it prints nothing and the
  terminal prompt is the one that counts. Allow
  once adds nothing to your permission rules, and Deny tells Claude you said no. Dashbar can only answer prompts
  Claude Code would show you anyway. Remove takes out only Dashbar's hook. With more than one account, Integrations lists
  each one: Add puts the hook in that account's own `settings.json`, and a prompt says which account it came from.

- **Live menu bar status**: the icon's bar sweeps while agents work (a one-second sweep every five seconds; still with
  Reduce Motion or the setting off) beside the working count, an amber hand and count when an agent needs you, and a
  green "Done · project" for five seconds when one finishes. Settings → Menu Bar picks the text beside the icon
  (nothing, the count, or the count and how long the longest-running agent has been at it).

## How it differs

- **Local only.** It reads the session logs Claude Code, Codex and Gemini CLI already write on your Mac (`~/.claude`, `~/.codex`, `~/.gemini` and any account folders you add), lists listening ports with libproc and measures folders. No browser cookies, no Full Disk Access, no account, no analytics.
- **Nothing is sent**, except Sparkle's update checks to GitHub and, if you turn it on, the experimental Claude plan-limits request to `api.anthropic.com` (the same read-only call Claude Code's `/usage` makes). The recommended way to see Claude plan limits sends nothing: only when you press Add does Dashbar change the `statusLine` setting in Claude Code's `settings.json` (after a backup), so a local script saves your usage percentages to a file on your Mac.
- **Reads, and acts only when you click.** Dashbar changes Claude Code's `settings.json` (or the Antigravity CLI's) only when you press Add (the status line, or the permission hook), after a backup, and Remove puts it back. If you turn on answering permission prompts, it answers one only when you click Allow once or Deny, never by itself and never by changing your permission rules; anything else falls back to Claude Code's own prompt.
- **One app for the whole picture.** Agents (working, idle, waiting for you), plan limits with a pace mark and a projected run-out time, dev servers grouped by project, what each workspace's processes use, system stats and a clean-up of rebuildable caches, in the panel or in a window.

## Settings

Open from the gear menu or ⌘, : which panel sections show, refresh interval, which editor and
terminal the quick actions open, notifications, the island, launch at login, and the folders clean-up scans
(defaults to whichever of `~/Development`, `~/Developer`, `~/Projects`, `~/Code`, `~/src` exist).

If Claude Code or Codex change their log format, Dashbar shows a warning rather than silently
reporting zero.

## Building from source

Needs macOS 14+ and Xcode / Swift 6.

```bash
swift test              # tests
./build.sh --run        # build "Dashbar Local.app" and launch it
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for local builds, releasing and the rules for changes. Bugs and ideas go in [issues](https://github.com/stevenmckinnon/dashbar/issues); security reports are described in [SECURITY.md](SECURITY.md). For anything else, email [hello@usedashbar.com](mailto:hello@usedashbar.com).

## Privacy

Everything stays on your Mac. Dashbar reads local agent logs, lists listening ports and measures cache
folders. Claude plan limits come from Claude Code's status line: with your consent Dashbar changes that one
setting so a local script saves your usage percentages to a file, and it sends nothing. The Antigravity CLI's
bridge works the same way and picks its fields one by one, so your email, conversation titles and transcript
paths in that status line's input are never saved. The Antigravity app's database is only ever opened read-only. The only network
requests are update checks and the optional experimental plan-limits setting, which sends Claude Code's own
sign-in to Anthropic's usage endpoint, the same call Claude Code makes.

Answering permission prompts is the one feature that acts on an agent, and only when you click Allow or Deny.
Requests and answers pass through files only your user can read, named with 128 random bits. Another program
running as you could write an answer file, but such a program could equally type into your terminal or edit
Claude Code's settings, so this opens nothing new to it. Nothing about the request leaves your Mac.

## Licence

MIT. See `LICENSE`. Not affiliated with Anthropic, OpenAI or Google.
