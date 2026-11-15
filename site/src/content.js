// The page's words, in one place. App.jsx renders them, and at build time vite.config.js writes the same
// text into index.html (for readers without JavaScript), /index.md, /llms.txt and the agent skill, so none of
// them can drift from the page. The FAQ lives in faq.js and release notes in release-notes/, for the same reason.
// Text may use **bold** and `code`; App.jsx renders both, and they are already Markdown.

export const SITE = "https://usedashbar.com/";
export const REPO = "https://github.com/stevenmckinnon/dashbar";
export const BREW = "brew install --cask stevenmckinnon/tap/dashbar";

export const HERO = {
  headline: "Your agents, in the menu bar",
  lede: "Dashbar shows which **Claude Code** and **Codex** sessions are working, how much of your plan is left, and which dev servers are idling. Free and open source.",
  note: "Needs macOS 14 or later. Notarised by Apple. MIT licence.",
};

// The launch film: video/ builds it, docs/images/launch.mp4 is the web encode.
export const TOUR = {
  heading: "See it in 30 seconds",
  lede: "A permission prompt answered from the notch, your plan limits with pace, idle dev servers, caches you can rebuild and the Dashbar window.",
  caption: "No sound. Every screen is the real app, showing made-up projects.",
};

export const FEATURES_INTRO = "Everything an agent-heavy day throws at your Mac, in one small panel.";

export const FEATURES = [
  { name: "Agents, and when they need you",
    text: "Each Claude Code session by project: working, idle or waiting for you, for how long, and how full its context window is. Click one to go back to the app it runs in. Turn on permission prompts in Settings and a request shows up under its session with Allow once and Deny. The terminal still asks too, and Dashbar never answers by itself." },
  { name: "Plan limits, with pace",
    text: "Your 5-hour and weekly limits, with a mark for where an even pace would be and a projection of when you would run out at the current rate. Each tool has its own card, and the one closest to running out comes first. Codex’s limits come from its own logs. Claude’s come from Claude Code’s status line: add Dashbar to it in Settings and your usage updates after each Claude Code reply, with no network request." },
  { name: "Usage and estimated cost",
    text: "Tokens for Claude Code and Codex today, or over the last 7 or 14 days, by hour or by day, and what they would cost at public API list prices. One choice at the top sets the span for every card, and in the Dashbar window each card also lists its projects and models. The cost is a guide, not your bill, and Settings can hide it. History, in the Dashbar window, keeps 30 days of usage and how full each plan window got." },
  { name: "Idle servers",
    text: "Dev servers grouped under the project that owns them. One that has been up for over an hour and is barely using the CPU is marked, and so is one an agent started." },
  { name: "System",
    text: "CPU, memory, GPU, network and battery, and the busiest apps right now. None of it is new; it is just in the same place as everything else." },
  { name: "Clean-up",
    text: "Finds `node_modules`, `.next`, build folders and Xcode’s DerivedData, shows what you would get back, and moves them to the Trash only after you confirm." },
];

// The shortcut sits between `before` and `after`, so the page can show it as a key.
export const WINDOW = {
  heading: "Or a whole window",
  before: "Press",
  shortcut: "⌃⌥D",
  after: ", or the arrow at the top of the panel, and Dashbar opens as a window. Its pages and every running workspace sit in a sidebar. A workspace’s page adds up what it is using right now, its dev servers, its agents and everything they started, and shows the processes behind the numbers. You can stop a server, quit a process or move the workspace’s caches to the Trash from there. History shows 30 days of usage and estimated cost, and how full each plan window got.",
  caption: "The menu bar panel stays the quick glance. Clicking a workspace there opens its page here.",
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
    "The listening ports on your Mac and the processes behind them, through the system’s own process API",
    "The folders you choose, to size the caches in clean-up",
    "If you add Dashbar to Claude Code’s status line: the plan usage Claude Code passes it after each reply. Dashbar changes only that one setting, keeps a backup, and puts your previous status line back when you remove it.",
    "If you turn on answering permission prompts: what Claude Code is about to ask you (the command, file or address), through a hook Dashbar adds to Claude Code’s settings. File contents and edits are left out, and nothing leaves your Mac.",
  ],
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

export const FOOTER = {
  about: "A menu bar app for Claude Code and Codex.",
  trademarks: "Dashbar is not affiliated with Anthropic or OpenAI. Claude and Codex are their trademarks.",
};

/** The text without Markdown marks, for meta tags and structured data. */
export const plain = (text) => text.replace(/\*\*([^*]+)\*\*/g, "$1").replace(/`([^`]+)`/g, "$1");
