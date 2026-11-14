// Plain-text copy of the page's main content, written into index.html at build time so crawlers and
// readers without JavaScript get it (see vite.config.js). Keep it in step with the hero and ITEMS in
// App.jsx; the FAQ comes from faq.js, so it cannot drift.
export const HERO = {
  headline: "Your agents, in the menu bar",
  lede: "Dashbar shows which Claude Code and Codex sessions are working, how much of your plan is left, and which dev servers are idling. Free and open source.",
};

export const FEATURES = [
  { name: "Working agents", text: "Each Claude Code session by project: working or idle, for how long, and how full its context window is. It reads the session files and transcripts under ~/.claude, and nothing else." },
  { name: "Plan limits, with pace", text: "Your 5-hour and weekly limits, with a mark for where an even pace would be and a projection of when you would run out at the current rate. Codex’s limits come from its own logs. Claude’s come from Claude Code’s status line: add Dashbar to it in Settings and your usage updates after each Claude Code reply, with no network request." },
  { name: "Idle servers", text: "Dev servers grouped under the project that owns them. One that has been up for over an hour and is barely using the CPU is marked, and so is one an agent started." },
  { name: "System", text: "CPU, memory, GPU, network and battery, and the busiest apps right now. None of it is new; it is just in the same place as everything else." },
  { name: "Clean-up", text: "Finds node_modules, .next, build folders and Xcode’s DerivedData, shows what you would get back, and moves them to the Trash only after you confirm." },
];
