// The docs page at /docs: the `dashbar` command and what each integration in Settings changes. DocsPage.jsx renders
// it, and at build time vite.config.js writes the same text into docs.html (for readers without JavaScript) and
// agent-files.js into /docs.md and /llms-full.txt. Every statement must be true of the app today: check README.md,
// Sources/Dashbar and Sources/DashbarStatus/CLI.swift (the command's --help) before changing one.
// Blocks: { text }, { list }, { code, lang }, { h3 }. Text may use **bold**, `code` and [links](https://…).
import { REPO } from "./content.js";
import { FAQ } from "./faq.js";
import { richHtml } from "./policy.js";

export const DOCS_URL = "https://usedashbar.com/docs";

const uninstall = FAQ.find((f) => f.id === "faq-uninstall");
if (!uninstall) throw new Error("docs.js: no FAQ entry faq-uninstall");

export const DOCS = {
  title: "Docs",
  description: "How to use Dashbar’s dashbar command in tmux, shell prompts and scripts, and what each integration in Settings changes, saves and puts back.",
  lede: "Dashbar works as soon as you open it: it reads what your agents already write on your Mac. This page covers the parts you set up yourself: the `dashbar` command for status bars and scripts, and the integrations in Settings that change another tool’s settings, what each one saves and how Remove puts things back.",
  sections: [
    {
      id: "cli",
      heading: "The dashbar command",
      blocks: [
        { text: "Dashbar comes with `dashbar`, a small command that prints what Dashbar knows, for tmux status bars, shell prompts and scripts. It reads a status file the running app keeps up to date and never reads agent logs itself, so it costs nothing, and Dashbar has to be running." },
        { h3: "Install it" },
        { text: "Homebrew links it for you. With the DMG, link it yourself, or copy the same command from Settings, under Integrations, Command-line tool:" },
        { code: "sudo mkdir -p /usr/local/bin && sudo ln -sf /Applications/Dashbar.app/Contents/Helpers/dashbar /usr/local/bin/dashbar", lang: "sh" },
        { h3: "Commands" },
        { list: [
          "`dashbar` or `dashbar status`: agents that need you, agents working and idle, every plan limit (the one closest to running out first, with its pace), today’s tokens and dev servers.",
          "`dashbar line`: one line for a status bar or prompt. Add `--ascii` where `⚠` and `·` don’t draw. An arrow (`↑`, or `(!)` with `--ascii`) after a limit means it’s on course to run out.",
          "`dashbar status --json`: the same status as JSON, with each limit’s pace worked out when you ask.",
          "`--local` reads a local build (Dashbar Local) instead of the release. Without it, the release is read if it’s running, otherwise the local build.",
          "`dashbar --help` and `dashbar --version`.",
        ] },
        { code: "$ dashbar\nNeeds you\n  billing-api  Claude · needs permission · 32s\nWorking\n  storefront-web  Claude · 4m · 3 subagents\nIdle\n  docs-site  Claude · 1h 35m\nPlan limits\n  Claude 5-hour  55% · resets in 2h 11m\n  Claude Weekly  38% · resets Thu 06:02\n  Codex Weekly   34% · resets Thu 20:26\nToday\n  Claude 152.7M tokens · Codex 9.5M tokens\nServers\n  storefront-web  :3000 node\n\n$ dashbar line\n⚠ 1 needs you · 1 working · Claude 5h 55%", lang: "console" },
        { h3: "Exit status" },
        { text: "If Dashbar isn’t running, `dashbar` prints nothing on standard output, says why on standard error and exits non-zero, so a status bar shows nothing rather than old figures." },
        { list: [
          "`0`: printed the current status.",
          "`2`: Dashbar hasn’t saved a status yet. Open Dashbar 0.7.1 or later.",
          "`3`: Dashbar isn’t running.",
          "`4`: the status file can’t be read.",
          "`64`: an unknown command or option.",
        ] },
        { h3: "In tmux" },
        { text: "In `~/.tmux.conf`. tmux reruns it every `status-interval` seconds." },
        { code: "set -g status-right '#(dashbar line --ascii)'\nset -g status-interval 10", lang: "tmux" },
        { h3: "In your zsh prompt" },
        { text: "In `~/.zshrc`:" },
        { code: "setopt prompt_subst\nRPROMPT='$(dashbar line 2>/dev/null)'", lang: "zsh" },
        { h3: "In Starship" },
        { text: "In `~/.config/starship.toml`:" },
        { code: "[custom.dashbar]\ncommand = \"dashbar line\"\nwhen = \"command -v dashbar\"\nformat = \"[$output]($style) \"", lang: "toml" },
        { h3: "In Claude Code’s status line" },
        { text: "`dashbar line` works as Claude Code’s [status line](https://code.claude.com/docs/en/statusline) command too:" },
        { code: "\"statusLine\": {\"type\": \"command\", \"command\": \"dashbar line\"}", lang: "json" },
        { text: "If Dashbar’s plan limits bridge is already in your status line, press Remove in Settings, under Integrations, set the status line to `dashbar line`, then press Add to Status Line again. The bridge runs your status line after saving the limits, so both work." },
        { h3: "For your agents" },
        { text: "Agents that can run commands can check `dashbar status --json` themselves: your plan limits before heavy or parallel work, dev servers already running before starting another, and other agents working in the same folder. The [dashbar-status skill](https://usedashbar.com/.well-known/agent-skills/dashbar-status/SKILL.md) tells them when to check and what to do with what they find. It only reads. To add it to Claude Code:" },
        { code: "mkdir -p ~/.claude/skills/dashbar-status\ncurl -fsSL https://usedashbar.com/.well-known/agent-skills/dashbar-status/SKILL.md \\\n  -o ~/.claude/skills/dashbar-status/SKILL.md", lang: "sh" },
        { text: "Other agents that read `SKILL.md` files take the same file in their own skills folder." },
        { h3: "The status file" },
        { text: "The command reads `~/Library/Caches/Dashbar/CLI/status.json`, readable only by you. It holds each session’s tool, state, workspace folder and how long it’s been in that state, plan percentages and reset times, today’s token counts and dev server ports. Never prompts, session titles, session ids, permission request details or sign-ins. Dashbar rewrites it only when something in it changes, at most every 3 seconds. Servers are as of the last time Dashbar read ports, which it does while its panel or window is open, and `dashbar` leaves out any that have stopped since." },
      ],
    },
    {
      id: "integrations",
      heading: "Integrations",
      blocks: [
        { text: "Everything here is off until you press Add in Settings, under Integrations. Each one changes a single setting or adds a single file of the other tool’s, and Remove takes out only what Dashbar added. None of them sends anything, and none answers anything for you." },
      ],
    },
    {
      id: "claude-limits",
      heading: "Claude plan limits",
      blocks: [
        { text: "Claude Code passes your 5-hour and weekly usage to its [status line](https://code.claude.com/docs/en/statusline) after each reply, on Pro, Max and Ultra plans. **Add to Status Line** points that status line at a small script that saves the usage, then runs the status line you had before, with the same input, so it looks the same." },
        { list: [
          "**Changes:** the `statusLine` key in `~/.claude/settings.json` (or `$CLAUDE_CONFIG_DIR/settings.json`), after a backup in `~/Library/Application Support/Dashbar/Backups`.",
          "**Script:** `~/Library/Application Support/Dashbar/claude-statusline-bridge.sh`.",
          "**Saves:** only the `rate_limits` part and the time, to `~/Library/Caches/Dashbar/claude-statusline.json`. Never prompts, paths, session ids or tokens.",
          "**Remove:** puts your previous status line back exactly.",
        ] },
        { text: "The reading is as fresh as your last Claude Code reply, and Dashbar says how old it is." },
        { h3: "The older, experimental way" },
        { text: "Off by default, under Experimental in Integrations. Dashbar reads Claude Code’s sign-in from the Keychain with macOS’s `security` tool, as Claude Code does, and makes the same read-only request to `api.anthropic.com` as Claude Code’s `/usage`, at most every 5 minutes. It never refreshes or stores the sign-in. With both on, Dashbar shows the newer reading and doesn’t ask while the status line’s is current. The status line way is recommended: it sends nothing." },
      ],
    },
    {
      id: "permissions",
      heading: "Answering permission prompts",
      blocks: [
        { text: "When Claude Code is about to ask you to allow a tool, Dashbar shows what it wants to do (the command, file or address) under that session, in the window, on the island and on the notification, with **Allow once** and **Deny**. **Add to Claude Code** turns it on." },
        { list: [
          "**Changes:** adds one [`PermissionRequest` hook](https://code.claude.com/docs/en/hooks#permissionrequest) to `~/.claude/settings.json`, after a backup, keeping any hooks you have.",
          "**Script:** `~/Library/Application Support/Dashbar/claude-permission-bridge.sh`. It leaves the request in `~/Library/Application Support/Dashbar/Permissions`, readable only by you, with file contents and edits left out, and waits up to 5 minutes (adjustable) for your answer.",
          "**Never answers by itself.** If you don’t answer, Dashbar isn’t running or anything goes wrong, it prints nothing and the terminal prompt is the one that counts. Claude Code keeps its own prompt up the whole time, so you can answer in either place.",
          "**Allow once** adds nothing to your permission rules. **Deny** tells Claude you said no. **Open session** hands the prompt back to the terminal.",
          "**Remove:** takes out only Dashbar’s hook.",
        ] },
        { text: "Dashbar can only answer prompts Claude Code would show you anyway. With more than one account, Integrations lists each one, and Add puts the hook in that account’s own settings." },
      ],
    },
    {
      id: "antigravity",
      heading: "Antigravity CLI",
      blocks: [
        { text: "For Antigravity’s 5-hour and weekly limits per model group, its usage and its sessions, **Add to Status Line** under Antigravity CLI points its [status line](https://antigravity.google/docs/cli/statusline/) at a small script, which then runs your own status line as before." },
        { list: [
          "**Changes:** the `statusLine` key in `~/.gemini/antigravity-cli/settings.json`, after a backup.",
          "**Saves:** the plan quota and tier, and each session’s folder, model, token totals, estimated cost and state, to `~/Library/Caches/Dashbar/antigravity-*`. Never your email, conversation titles or transcripts.",
          "**Remove:** puts your previous status line back exactly.",
        ] },
        { text: "The Antigravity app and Gemini CLI need nothing added: Dashbar reads them as they are." },
      ],
    },
    {
      id: "opencode",
      heading: "OpenCode",
      blocks: [
        { text: "Dashbar shows OpenCode’s sessions and usage from its database without any setup. To see when a session is waiting for you, **Add to OpenCode** adds a plugin." },
        { list: [
          "**Adds:** one file, `dashbar.js`, in `~/.config/opencode/plugins/`.",
          "**Saves:** only each session’s id, folder, state (working, idle or waiting for you) and time, to `~/Library/Caches/Dashbar/opencode-sessions/`. Never prompts, tool input or titles.",
          "It never answers a permission.",
          "**Remove:** deletes the file, and only if Dashbar wrote it.",
        ] },
      ],
    },
    {
      id: "copilot",
      heading: "GitHub Copilot",
      blocks: [
        { text: "Dashbar shows Copilot’s sessions, in the terminal and as VS Code’s agent, and their usage without any setup. To see a session that needs you the moment it asks, **Add to Copilot** adds a hook, using Copilot’s own hooks." },
        { list: [
          "**Adds:** one file, `dashbar.json`, in `~/.copilot/hooks/` (`$COPILOT_HOME/hooks/` if set).",
          "**Saves:** only each session’s id, folder, state and time, to `~/Library/Caches/Dashbar/copilot-sessions/`. Never prompts, tool arguments or results.",
          "It never answers a permission.",
          "**Remove:** deletes the file, and only if every command in it is Dashbar’s.",
        ] },
      ],
    },
    {
      id: "accounts",
      heading: "More than one account",
      blocks: [
        { text: "If you run Claude Code with [`CLAUDE_CONFIG_DIR`](https://code.claude.com/docs/en/authentication#log-in-with-multiple-accounts) (say `~/.claude-work` beside `~/.claude`) or Codex with `CODEX_HOME`, add each folder in Settings, under Accounts. Dashbar suggests `~/.claude-*` and `~/.codex-*` folders with logs, looking only at the top of your home folder." },
        { text: "It reads every account’s sessions and usage and names them by account once there’s more than one. Each Claude account has its own Add to Status Line in Integrations, so its plan limits come from its own status line." },
      ],
    },
    {
      id: "show",
      heading: "Hiding a tool",
      blocks: [
        { text: "Every tool other than Claude Code has a **Show in Dashbar** switch at the top of its section in Integrations (Gemini CLI and Antigravity share one). Off hides it everywhere: workspaces, Usage, History, limits, notifications, the island, the menu bar, widgets and the `dashbar` command. Dashbar stops reading its files at all. Anything you added to it stays installed, and switching it back on brings everything back." },
      ],
    },
    {
      id: "remove",
      heading: "Uninstalling cleanly",
      blocks: [
        { text: uninstall.a.replace("brew uninstall --cask dashbar", "`brew uninstall --cask dashbar`").replace("--zap", "`--zap`") },
        { text: `What Dashbar reads and keeps on your Mac, folder by folder, is in the [privacy policy](/privacy). The source is [on GitHub](${REPO}).` },
      ],
    },
  ],
};

/** The table of contents: [id, heading]. */
export const docsToc = () => DOCS.sections.map((s) => [s.id, s.heading]);

const esc = (t) => t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

/** The page's body as HTML, for docs.html before the page's script runs. */
export function docsHtml() {
  return [
    `<h1>${esc(DOCS.title)}</h1>`,
    `<p class="policy-lede">${richHtml(DOCS.lede)}</p>`,
    ...DOCS.sections.map((s) => [
      `<section id="${s.id}"><h2>${esc(s.heading)}</h2>`,
      ...s.blocks.map((b) => b.h3 ? `<h3>${esc(b.h3)}</h3>`
        : b.code ? `<pre><code>${esc(b.code)}</code></pre>`
        : b.list ? `<ul>${b.list.map((item) => `<li>${richHtml(item)}</li>`).join("")}</ul>`
        : `<p>${richHtml(b.text)}</p>`),
      `</section>`,
    ].join("")),
  ].join("\n");
}

/** Absolute links, so the Markdown copy works outside the site. */
const absolute = (text) => text.replace(/\]\(\//g, "](https://usedashbar.com/");

/** The page as Markdown, for /docs.md and /llms-full.txt. `level` is the heading level of the title. */
export function docsMd(level = 1) {
  const h = (n) => "#".repeat(level + n - 1);
  return [
    `${h(1)} Dashbar ${DOCS.title.toLowerCase()}`,
    absolute(DOCS.lede),
    ...DOCS.sections.flatMap((s) => [
      `${h(2)} ${s.heading}`,
      ...s.blocks.map((b) => b.h3 ? `${h(3)} ${b.h3}`
        : b.code ? `\`\`\`${b.lang ?? ""}\n${b.code}\n\`\`\``
        : b.list ? b.list.map((item) => `- ${absolute(item)}`).join("\n")
        : absolute(b.text)),
    ]),
  ].join("\n\n") + "\n";
}
