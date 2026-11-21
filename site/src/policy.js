// The privacy policy at /privacy, in one place. PrivacyPage.jsx renders it, and at build time vite.config.js writes
// the same text into privacy.html for readers without JavaScript. What the app reads comes from the homepage's
// Privacy section (content.js), so the two can't disagree. Every statement here must be true of the app and site
// today: check Sources/Dashbar and AGENTS.md before changing one, and change `updated` with it.
// Text may use **bold**, `code` and [links](https://…).
import { REPO, PRIVACY } from "./content.js";

export const POLICY_URL = "https://usedashbar.com/privacy";

const GITHUB_PRIVACY = "https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement";

export const POLICY = {
  title: "Privacy policy",
  description: "What Dashbar, the Mac menu bar app, and its website do with your data: the app sends nothing about you, has no analytics and no account.",
  updated: "2026-11-16",
  updatedText: "16 November 2026",
  lede: "Dashbar runs on your Mac and collects nothing about you. This page sets out what the app reads and keeps on your Mac, the only two requests it can make, and what happens when you download it, visit this website or send an email.",
  sections: [
    {
      id: "who",
      heading: "Who makes Dashbar",
      blocks: [
        { text: "Dashbar is an independent, open-source project made by Steve McKinnon. In this policy, “I” means me, Steve." },
        { list: [
          "Questions about privacy, or anything else: [hello@usedashbar.com](mailto:hello@usedashbar.com)",
          `Security problems: report them privately as [SECURITY.md](${REPO}/blob/main/SECURITY.md) describes, not in a public issue`,
          "Who I am: [Steve McKinnon on LinkedIn](https://www.linkedin.com/in/stevenmckinnon92)",
        ] },
      ],
    },
    {
      id: "app",
      heading: "The app in short",
      blocks: [
        { text: "The app has no account, no analytics, no crash reporting and no ads. It doesn’t send me anything, so I have no data about you to sell, share or lose. The only third-party code inside it is [Sparkle](https://sparkle-project.org), the open-source updater many Mac apps use." },
        { text: `The code is [on GitHub](${REPO}), so you can check all of this.` },
      ],
    },
    {
      id: "reads",
      heading: "What the app reads on your Mac",
      blocks: [
        { text: "Dashbar reads these to show them to you in the menu bar. None of it leaves your Mac." },
        { list: PRIVACY.reads },
      ],
    },
    {
      id: "keeps",
      heading: "What the app keeps on your Mac",
      blocks: [
        { list: [
          "Your settings, in `~/Library/Preferences/fun.dashbar.app.plist`.",
          "Its own data, in `~/Library/Application Support/Dashbar`: scan progress, the usage and plan history behind the History page and, for features you turn on, the status line and permission scripts and backups of the settings files they changed.",
          "Caches, in `~/Library/Caches/Dashbar`: the latest plan reading (usage percentages, reset times and the plan name), what a status line you added Dashbar to passed it and, if you added Dashbar to OpenCode or GitHub Copilot, each session’s state from its plugin or hook.",
          "If you turn on answering permission prompts, requests and your answers pass through files in `~/Library/Application Support/Dashbar/Permissions` that only your user account can read.",
        ] },
        { text: "To remove everything, delete those folders and that file after you uninstall. `brew uninstall --cask --zap dashbar` removes all of them for you, along with the caches macOS keeps for the app." },
      ],
    },
    {
      id: "sends",
      heading: "What the app sends",
      blocks: [
        { text: "Nothing, with two exceptions." },
        { list: [
          `**Update checks**, from version 0.3.0. Sparkle fetches Dashbar’s update feed from GitHub (\`raw.githubusercontent.com\`) to see whether a newer version exists. The request names the app and Sparkle and their versions, like \`Dashbar/0.7.0 Sparkle/2.10.1\`. Sparkle’s optional system profile (your Mac model, macOS version and similar) is turned off, and Dashbar never asks to send it. If you install an update, it downloads from GitHub Releases. GitHub sees your IP address, as it does for any request, and its [privacy statement](${GITHUB_PRIVACY}) applies.`,
          "**Claude plan limits, the experimental way.** This is off by default. If you turn it on, Dashbar asks Anthropic’s usage endpoint (`api.anthropic.com`) for your plan limits at most every 5 minutes, with Claude Code’s own sign-in, which it reads from your Keychain. It keeps the sign-in in memory only, and never refreshes, stores or logs it. Anthropic’s [privacy policy](https://www.anthropic.com/legal/privacy) covers that request. The recommended way, through Claude Code’s status line, sends nothing.",
        ] },
        { text: "Links you click in the app, such as a dev server’s address, open in your browser." },
      ],
    },
    {
      id: "downloads",
      heading: "Downloads",
      blocks: [
        { text: `The DMG is hosted on [GitHub Releases](${REPO}/releases), and the Homebrew cask downloads the same file. GitHub’s [privacy statement](${GITHUB_PRIVACY}) covers those downloads. GitHub shows me how many times each release was downloaded and totals of the repository’s traffic, not who you are.` },
        { text: "Homebrew has its own analytics, which may record an install as Homebrew’s [analytics documentation](https://docs.brew.sh/Analytics) describes. It also explains how to turn them off." },
      ],
    },
    {
      id: "website",
      heading: "This website",
      blocks: [
        { list: [
          "usedashbar.com is a static site hosted by Cloudflare. Cloudflare may log visitors’ IP addresses for security, as [its privacy policy](https://www.cloudflare.com/privacypolicy/) explains.",
          "It counts visits with [Cloudflare Web Analytics](https://www.cloudflare.com/web-analytics/), which loads a small script from Cloudflare and uses no cookies. It shows me totals such as page views and referring sites, not individual visitors.",
          "The footer shows a badge from [BuiltByIndies](https://builtbyindies.com), a directory that lists Dashbar. Its image loads from builtbyindies.com, so your browser asks their site for it, and they see your IP address as any site does.",
          "It sets no cookies, and has no other analytics, trackers or ads.",
          "Its typeface, Instrument Sans, is served from this site, not from Google Fonts.",
        ] },
        { text: "Links to GitHub and other sites take you to services with their own privacy policies." },
      ],
    },
    {
      id: "email",
      heading: "Email",
      blocks: [
        { text: "If you email hello@usedashbar.com, Cloudflare Email Routing receives the message and forwards it to my personal inbox. I use your email only to reply to you. There is no mailing list." },
        { text: "Issues and discussions on GitHub are public, and GitHub’s terms cover them." },
      ],
    },
    {
      id: "children",
      heading: "Children",
      blocks: [
        { text: "Dashbar is a tool for software developers and isn’t aimed at children. It collects nothing from anyone, children included." },
      ],
    },
    {
      id: "rights",
      heading: "Your data and your rights",
      blocks: [
        { text: "The app collects nothing, so I hold nothing from it to show you, correct or delete. If you’ve emailed me and want that email deleted, or have any question about your data, email [hello@usedashbar.com](mailto:hello@usedashbar.com)." },
      ],
    },
    {
      id: "changes",
      heading: "Changes",
      blocks: [
        { text: `If this policy changes, the date at the top changes with it. Every earlier version is in [the site’s history on GitHub](${REPO}/commits/main/site/src/policy.js).` },
      ],
    },
  ],
};

/** Splits text into plain runs, **bold**, `code` and [links](url). */
export function rich(text) {
  return text.split(/(\*\*[^*]+\*\*|`[^`]+`|\[[^\]]+\]\([^)\s]+\))/).filter(Boolean).map((part, key) => {
    if (part.startsWith("**")) return { key, tag: "strong", text: part.slice(2, -2) };
    if (part.startsWith("`")) return { key, tag: "code", text: part.slice(1, -1) };
    const link = part.match(/^\[([^\]]+)\]\(([^)\s]+)\)$/);
    if (link) return { key, tag: "a", text: link[1], href: link[2] };
    return { key, tag: null, text: part };
  });
}

const esc = (t) => t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

/** The same text as HTML, for privacy.html before the page's script runs. */
export function richHtml(text) {
  return rich(text).map(({ tag, text: t, href }) =>
    tag === "a" ? `<a href="${esc(href)}">${esc(t)}</a>` : tag ? `<${tag}>${esc(t)}</${tag}>` : esc(t)).join("");
}

/** The policy's body as HTML (heading, date, sections). */
export function policyHtml() {
  return [
    `<h1>${esc(POLICY.title)}</h1>`,
    `<p class="updated">Last updated: <time datetime="${POLICY.updated}">${POLICY.updatedText}</time></p>`,
    `<p class="policy-lede">${richHtml(POLICY.lede)}</p>`,
    ...POLICY.sections.map((s) => [
      `<section id="${s.id}"><h2>${esc(s.heading)}</h2>`,
      ...s.blocks.map((b) => b.list
        ? `<ul>${b.list.map((item) => `<li>${richHtml(item)}</li>`).join("")}</ul>`
        : `<p>${richHtml(b.text)}</p>`),
      `</section>`,
    ].join("")),
  ].join("\n");
}
