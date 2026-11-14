// Plain-text copy of the page's main content, written into index.html at build time so crawlers and
// readers without JavaScript get it (see vite.config.js). Keep it in step with the hero and ITEMS in
// App.jsx; the FAQ comes from faq.js, so it cannot drift.
export const HERO = {
  headline: "Your agents, in the menu bar",
  lede: "Dashbar shows which Claude Code and Codex sessions are working, how much of your plan is left, and which dev servers are idling. Free and open source.",
};

export const FEATURES = [
  { name: "Agents, and when they need you", text: "Each Claude Code session by project: working, idle or waiting for you, for how long, and how full its context window is. Click one to go back to the app it runs in. Turn on permission prompts in Settings and a request shows up under its session with Allow once and Deny. The terminal still asks too, and Dashbar never answers by itself." },
  { name: "Plan limits, with pace", text: "Your 5-hour and weekly limits, with a mark for where an even pace would be and a projection of when you would run out at the current rate. Codex’s limits come from its own logs. Claude’s come from Claude Code’s status line: add Dashbar to it in Settings and your usage updates after each Claude Code reply, with no network request." },
  { name: "Usage and estimated cost", text: "Tokens by hour, project and model for Claude Code and Codex, and what they would cost at public API list prices. It is a guide, not your bill, and Settings can hide it. History, in the Dashbar window, keeps 30 days of usage and how full each plan window got." },
  { name: "Idle servers", text: "Dev servers grouped under the project that owns them. One that has been up for over an hour and is barely using the CPU is marked, and so is one an agent started." },
  { name: "System", text: "CPU, memory, GPU, network and battery, and the busiest apps right now. None of it is new; it is just in the same place as everything else." },
  { name: "Clean-up", text: "Finds node_modules, .next, build folders and Xcode’s DerivedData, shows what you would get back, and moves them to the Trash only after you confirm." },
];
