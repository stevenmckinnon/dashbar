// The page's words, in one place. App.jsx renders them, and at build time vite.config.js writes the same
// text into index.html (for readers without JavaScript), /index.md, /llms.txt and the agent skill, so none of
// them can drift from the page. The FAQ lives in faq.js and release notes in release-notes/, for the same reason.
// Text may use **bold** and `code`; App.jsx renders both, and they are already Markdown.

export const SITE = "https://usedashbar.com/";
export const REPO = "https://github.com/stevenmckinnon/dashbar";
export const BREW = "brew install --cask stevenmckinnon/tap/dashbar";

export const HERO = {
  headline: "Your agents, in the menu bar",
  lede: "See which coding agents are working, how much of your plan is left, and which dev servers are idling. Free and open source.",
  note: "Needs macOS 14 or later. Notarised by Apple.",
  // Under the install buttons. Each name links to the FAQ entry with this id (faq.js), which says what each tool gets.
  worksWith: {
    lead: "Works with",
    tools: ["Claude Code", "Codex", "Gemini CLI", "Antigravity", "OpenCode", "GitHub Copilot"],
    faq: "faq-agents",
  },
};

/** "A, B and C". */
export const listOf = (items) => (items.length < 2 ? items.join("") : `${items.slice(0, -1).join(", ")} and ${items.at(-1)}`);

/** The works-with line as plain text: "Works with Claude Code, Codex, … and OpenCode". */
export const worksWithText = () => `${HERO.worksWith.lead} ${listOf(HERO.worksWith.tools)}`;

// The launch film: video/ builds it, docs/images/launch.mp4 is the web encode.
export const TOUR = {
  heading: "See it in 30 seconds",
  lede: "A permission prompt answered from the notch, your plan limits with pace, idle dev servers, caches you can rebuild and the Dashbar window.",
  caption: "No sound. Every screen is the real app, showing made-up projects.",
};

export const FEATURES_INTRO = "Everything an agent-heavy day throws at your Mac, in one small panel.";

// Each card says what it is in a sentence or two; `more` links to the docs page with the detail.
export const FEATURES = [
  { name: "Agents, and when they need you",
    text: "Every Claude Code session by project: working, idle or waiting for you, for how long, and how full its context window is. Click one to go straight back to it. Turn on permission prompts and you can answer Allow once or Deny from Dashbar, which never answers by itself.",
    more: { href: "/docs/going-back", label: "What a click opens" } },
  { name: "Plan limits, with pace",
    text: "Your 5-hour and weekly limits, with where an even pace would be and when you would run out at the current rate. Weekly limits show today’s share, and the limit closest to running out comes first.",
    more: { href: "/docs/integrations#claude-limits", label: "Setting up Claude’s limits" } },
  { name: "Usage and estimated cost",
    text: "Tokens for Claude Code and Codex today, or over the last 7 or 14 days, and what they would cost at public API list prices: a guide, not your bill. History keeps 30 days." },
  { name: "Idle servers",
    text: "Dev servers grouped under the project that owns them. One that has been up for over an hour and is barely using the CPU is marked, and so is one an agent started." },
  { name: "System",
    text: "CPU, memory, GPU, network and battery, and the busiest apps right now. None of it is new; it is just in the same place as everything else." },
  { name: "Clean-up",
    text: "Finds `node_modules`, `.next`, build folders and Xcode’s DerivedData, shows what you would get back, and moves them to the Trash only after you confirm." },
];

// One section for Dashbar away from the menu bar: the window, then the widgets. The shortcut sits between
// `before` and `after`, so the page can show it as a key.
export const WINDOW = {
  heading: "Beyond the menu bar",
  before: "Press",
  shortcut: "⌃⌥D",
  after: ", or the arrow at the top of the panel, and Dashbar opens as a window. Each running workspace has a page: what it is using right now, its dev servers and agents, and the processes behind them. Stop a server, quit a process or move its caches to the Trash from there. History shows 30 days of usage, estimated cost and how full each plan window got.",
  caption: "The menu bar panel stays the quick glance. Clicking a workspace there opens its page here.",
};

// The widgets refresh on macOS's schedule: about every 15 minutes, sooner when Dashbar's figures change (WidgetBridge,
// SnapshotProvider). Keep "every few minutes, not live" true if that changes.
export const WIDGETS = {
  heading: "On your desktop",
  text: "Widgets keep your plan limits in sight. Small ones show one tool’s limits or tokens today. Medium ones show every tool’s limits and how many agents are working, or each tool’s tokens today. They refresh every few minutes, not live, and dim when Dashbar isn’t running.",
  altSmall: "The small Dashbar widget: Claude on Max 5x, 5-hour limit 55% used, weekly limit 38% used, each with its reset time.",
  altMedium: "The medium Dashbar widget: 2 working, and the 5-hour and weekly limits for Claude (55% and 38%), Codex (21% and 34%) and Antigravity (42% and 61%).",
};

export const PACE = {
  heading: "When would you run out?",
  lead: "Dashbar projects your current rate forward to 100%.",
  note: "The bar is a copy of the one in the app. The mark is where an even pace would be by now.",
};

export const PRIVACY = {
  heading: "What it reads and sends",
  reads: [
    "Claude Code’s session files and transcripts: `~/.claude/sessions` and `~/.claude/projects`",
    "Codex’s session logs: `~/.codex/sessions`",
    "The same folders for any other Claude Code or Codex account you add in Settings",
    "If you use Google’s agents: Gemini CLI’s chat logs in `~/.gemini/tmp`, and only the status columns of the Antigravity app’s conversation list, opened read-only. If you add Dashbar to the Antigravity CLI’s status line, its plan quota and each session’s folder, model, token totals and state. Never titles, transcripts or your Google sign-in.",
    "If you use OpenCode: from its database, `~/.local/share/opencode/opencode.db`, opened read-only, only session ids, folders and times, and each reply’s model, token counts and cost. Never titles, prompts or replies. If you add Dashbar’s plugin to OpenCode, each session’s state (working, idle or waiting for you) and folder.",
    "If you use GitHub Copilot, in the terminal or as VS Code’s agent: from each session’s folder in `~/.copilot/session-state`, the project folder, the type of each event to tell working, idle or asking permission, and the model and token counts of each reply. Never prompts, replies, tool arguments or results. If you add Dashbar’s hook to Copilot, each session’s state and folder.",
    "When you click to go back to a session: in T3 Code, its environment id and, from its database opened read-only, only the id of that session’s thread; in the Claude app, the names of its Code session files and which one holds that session’s id. For Orca, Dashbar runs Orca’s own `orca` command to open the session’s workspace. Never titles, messages or prompts, and nothing is kept.",
    "The listening ports on your Mac and the processes behind them, through the system’s own process API",
    "The folders you choose, to size the caches in clean-up",
    "If you add Dashbar to Claude Code’s status line: the plan usage Claude Code passes it after each reply. Dashbar changes only that one setting, keeps a backup, and puts your previous status line back when you remove it.",
    "If you turn on answering permission prompts: what Claude Code is about to ask you (the command, file or address), through a hook Dashbar adds to Claude Code’s settings. File contents and edits are left out, and nothing leaves your Mac.",
  ],
  // The homepage shows this short version; /privacy and index.md list `reads` in full.
  summary: [
    "Your agents’ own session files and logs on your Mac, such as `~/.claude` and `~/.codex`, to show what each one is doing and how much it has used.",
    "For your other tools, from Gemini CLI and OpenCode to T3 Code and the Claude app, only what it needs to show what’s running and how much it used. It keeps no titles or messages from them.",
    "The listening ports and the processes behind them, and the folders you choose for clean-up.",
    "With an integration you turn on, only what that tool passes it, such as your plan usage from Claude Code’s status line.",
  ],
  fullReads: "Everything it reads, file by file",
  sendsIntro: "Nothing, with two exceptions. The app has no account and no analytics.",
  sends: [
    "If you turn on the experimental way of reading Claude plan limits: one request to `api.anthropic.com` with Claude Code’s own sign-in. Dashbar never refreshes or stores that sign-in. The status line way sends nothing.",
    "Update checks, from version 0.3.0: a small feed fetched from GitHub to see whether a newer version exists.",
  ],
  siteNote: "This website, not the app, counts visits with Cloudflare Web Analytics, which uses no cookies.",
  policyLink: "Read the full privacy policy",
};

export const INSTALL = {
  heading: "Put your agents in the menu bar",
  lede: "Free and open source. The app has no account and no analytics.",
  download: "Open the DMG and drag Dashbar to Applications. It is signed and notarised by Apple, and needs macOS 14 or later.",
  brew: "One command. `brew upgrade` keeps it current.",
};

// On a phone or tablet, in place of Download for macOS: the link goes to the visitor's own Mac by their share
// sheet or their own email. The site sends nothing and keeps no address.
export const SEND_TO_MAC = {
  button: "Send to my Mac",
  note: "AirDrop or email yourself the link for your Mac.",
  subject: "Dashbar for my Mac",
  body: "Dashbar, a menu bar app for your coding agents:",
};

export const FOOTER = {
  about: "A menu bar app for your coding agents.",
  independence: "Dashbar is an independent project, not affiliated with or endorsed by Anthropic, OpenAI, Google, Anomaly, GitHub or the makers of T3 Code and Orca.",
};

/** The text without Markdown marks, for meta tags and structured data. */
export const plain = (text) => text.replace(/\*\*([^*]+)\*\*/g, "$1").replace(/`([^`]+)`/g, "$1");
