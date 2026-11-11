// The questions people ask before installing. Used by the page and, at build time, by the FAQ
// structured data in index.html, so the two can never disagree.
export const FAQ = [
  { q: "Which agents does Dashbar support?",
    a: "Claude Code and Codex get full support: it reads their session files on your Mac for working status and usage. Other tools, such as T3 Code, Cursor, Gemini CLI and Aider, show up as a chip when they are running, without usage numbers. If you want one added, open an issue on GitHub." },
  { q: "Can I keep it open in a window?",
    a: "Yes. Press Control-Option-D, or the arrow at the top of the panel, to open the Dashbar window: the panel’s pages and every running workspace in a sidebar. A workspace’s page shows its uptime, CPU, memory and energy, its dev servers and agents, and the processes behind the numbers. Like the panel, it only watches: it never starts or runs anything. A pin keeps it on top of other windows." },
  { q: "Does it work on Intel Macs?",
    a: "Yes. The app is universal, so it runs on Apple silicon and on Intel, on macOS 14 or later." },
  { q: "Does it use my tokens or send my data anywhere?",
    a: "Reading sessions, ports and folders happens on your Mac and costs nothing. There is no account and no analytics. The only requests are update checks from GitHub, and, if you turn on plan limits, one read-only request to api.anthropic.com. If that sign-in has expired, the Refresh button runs Claude Code once in the background, which uses a few tokens." },
  { q: "Why are Claude plan limits experimental?",
    a: "Claude does not save them on your Mac. Dashbar reads them from an undocumented endpoint, using the sign-in Claude Code keeps in your Keychain, so it can change or stop working. It is off by default, and turning it on is the only permission it needs: Dashbar reads the sign-in the same way Claude Code does, so macOS doesn’t ask again each time Claude Code renews it. Dashbar never refreshes or stores that sign-in. Codex’s limits come from its own logs and need no setup." },
  { q: "Can Clean-up delete something I need?",
    a: "It only looks for caches you can rebuild: node_modules, .next, build folders and Xcode’s DerivedData. It shows what you would get back and moves items to the Trash only after you confirm, so you can put them back." },
  { q: "How do I update it?",
    a: "From version 0.3.0 Dashbar checks for updates itself: open Settings, then About, then Check for Updates. With Homebrew, run brew upgrade --cask dashbar." },
  { q: "How do I uninstall it?",
    a: "Quit Dashbar and drag it to the Trash. With Homebrew, run brew uninstall --cask dashbar, and add --zap to remove its settings too." },
  { q: "Is it affiliated with Anthropic or OpenAI?",
    a: "No. Dashbar is an independent open source project." },
];
