// Files for agents and crawlers, written at build time from the same sources as the page: content.js, faq.js,
// release-notes/ and appcast.xml. vite.config.js emits them into dist. A rename that breaks a lookup here fails
// the build instead of publishing a stale or empty file.
import { readFileSync, readdirSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { FAQ } from "./src/faq.js";
import { SITE, REPO, BREW, HERO, FEATURES_INTRO, FEATURES, WINDOW, WIDGETS, PACE, PRIVACY, INSTALL, FOOTER, plain, worksWithText, listOf } from "./src/content.js";

const root = new URL("../", import.meta.url);
const byVersion = (a, b) => b.version.localeCompare(a.version, undefined, { numeric: true });

/** Released versions, newest first: those with an entry in appcast.xml, as on the page. */
export function releases() {
  let xml = "";
  try { xml = readFileSync(new URL("appcast.xml", root), "utf8"); } catch { return []; }
  const notes = new Map();
  try {
    for (const f of readdirSync(new URL("release-notes/", root))) {
      if (f.endsWith(".md")) notes.set(f.slice(0, -3), readFileSync(new URL(`release-notes/${f}`, root), "utf8").trim());
    }
  } catch { /* no notes folder */ }
  const out = [];
  for (const [, item] of xml.matchAll(/<item>([\s\S]*?)<\/item>/g)) {
    const version = item.match(/<sparkle:shortVersionString>([^<]+)</)?.[1]?.trim();
    const date = new Date(item.match(/<pubDate>([^<]+)</)?.[1] ?? "");
    if (version && !Number.isNaN(date.getTime())) out.push({ version, date, notes: notes.get(version) ?? "" });
  }
  return out.sort(byVersion);
}

export const downloadUrl = (version) =>
  version ? `${REPO}/releases/download/v${version}/Dashbar-${version}.dmg` : `${REPO}/releases/latest`;

const day = (date) => date.toISOString().slice(0, 10);
const answer = (q) => {
  const hit = FAQ.find((f) => f.q === q);
  if (!hit) throw new Error(`agent-files.js: no FAQ entry "${q}"; update the lookup`);
  return hit.a;
};

const faqById = (id) => {
  const hit = FAQ.find((f) => f.id === id);
  if (!hit) throw new Error(`agent-files.js: no FAQ entry with id "${id}"; update HERO.worksWith.faq`);
  return hit;
};

/** The day of the last commit touching these paths (relative to the repository root), for the sitemap's lastmod.
 * Needs the full history: site.yml checks out with fetch-depth 0, or every page would get the one commit's date. */
export function lastCommitDay(paths) {
  try {
    return execFileSync("git", ["log", "-1", "--format=%cs", "--", ...paths], { encoding: "utf8", cwd: new URL("..", import.meta.url) }).trim() || null;
  } catch { return null; }
}

const releaseSection = (list) =>
  list.map(({ version, date, notes }) => `### ${version} (${day(date)})\n\n${notes}`).join("\n\n");

/** The homepage as Markdown, section by section, in the page's order. */
export function indexMd(all) {
  const version = all[0]?.version;
  return [
    `# Dashbar`,
    `> ${plain(HERO.lede)}`,
    `${worksWithText()}. What each one gets is under “${faqById(HERO.worksWith.faq).q}” in Questions.`,
    `${version ? `Version ${version}. ` : ""}${HERO.note}`,
    [
      `- [Download for macOS](${downloadUrl(version)})`,
      `- Homebrew: \`${BREW}\``,
      `- [Source on GitHub](${REPO})`,
    ].join("\n"),
    `## What it shows`,
    FEATURES_INTRO,
    ...FEATURES.map((f) => `### ${f.name}\n\n${f.text}`),
    `## ${WINDOW.heading}`,
    `${WINDOW.before} ${WINDOW.shortcut} (Control-Option-D)${WINDOW.after}`,
    `### ${WIDGETS.heading}`,
    WIDGETS.text,
    `## ${PACE.heading}`,
    `${PACE.lead} ${PACE.note}`,
    `## ${PRIVACY.heading}`,
    `### Reads`,
    PRIVACY.reads.map((r) => `- ${r}`).join("\n"),
    `### Sends`,
    PRIVACY.sendsIntro,
    PRIVACY.sends.map((r) => `- ${r}`).join("\n"),
    `The code is [on GitHub](${REPO}) if you want to check.`,
    PRIVACY.siteNote,
    `[${PRIVACY.policyLink}](${SITE}privacy).`,
    ...(all.length ? [`## What’s new`, releaseSection(all.slice(0, 3)), `[All releases on GitHub](${REPO}/releases)`] : []),
    `## Questions`,
    ...FAQ.map(({ q, a }) => `### ${q}\n\n${a}`),
    `## Install`,
    INSTALL.lede,
    `### Download\n\n${INSTALL.download} [Download for macOS](${downloadUrl(version)}).`,
    `### Homebrew\n\n${INSTALL.brew}\n\n\`\`\`sh\n${BREW}\n\`\`\``,
    `---`,
    `${FOOTER.about} Made by [Steve McKinnon](https://steve.mn). Free and open source under the [MIT licence](${REPO}/blob/main/LICENSE). ${FOOTER.independence} Contact: hello@usedashbar.com`,
  ].join("\n\n") + "\n";
}

/** Everything in index.md, plus the notes for every release. */
export function llmsFullTxt(all) {
  const page = indexMd(all);
  if (!all.length) return page;
  return `${page}\n## Every release\n\n${releaseSection(all)}\n`;
}

const SKILL_PATH = ".well-known/agent-skills/install-dashbar/SKILL.md";

/** An agent skill for installing Dashbar, so an agent asked to set it up gets the real steps. */
export function skillMd() {
  return [
    [
      `---`,
      `name: install-dashbar`,
      `description: Install, update or uninstall Dashbar, the free, open-source macOS menu bar app that shows Claude Code and Codex sessions, plan limits and idle dev servers. Use when someone asks to install or set up Dashbar on their Mac.`,
      `---`,
    ].join("\n"),
    `# Install Dashbar`,
    `${plain(HERO.lede)} It is a universal app for Apple silicon and Intel Macs on macOS 14 or later, notarised by Apple and MIT licensed.`,
    `## Install`,
    `With Homebrew:`,
    `\`\`\`sh\n${BREW}\n\`\`\``,
    `Or download the DMG from ${REPO}/releases/latest. ${INSTALL.download}`,
    `## After installing`,
    `Open Dashbar from Applications. Its icon appears in the menu bar; click it to open the panel. Dashbar adds itself to Claude Code’s status line, or turns on answering permission prompts, only when the person presses Add in Dashbar’s Settings, under Integrations. It backs up Claude Code’s settings first, so leave that step to them rather than editing \`~/.claude/settings.json\` by hand.`,
    `## Update`,
    answer("How do I update it?"),
    `## Uninstall`,
    answer("How do I uninstall it?"),
    `## More`,
    [
      `- What it does, what it reads and sends, and the FAQ: ${SITE}index.md`,
      `- Source and README: ${REPO}`,
    ].join("\n"),
  ].join("\n\n") + "\n";
}

const sha256 = (text) => createHash("sha256").update(text, "utf8").digest("hex");

/** The Agent Skills discovery index (v0.2.0), with the digest of the exact bytes published. */
export function skillsIndex(skill) {
  return JSON.stringify({
    $schema: "https://schemas.agentskills.io/discovery/0.2.0/schema.json",
    skills: [{
      name: "install-dashbar",
      type: "skill-md",
      description: "Install, update or uninstall Dashbar, the macOS menu bar app for Claude Code and Codex.",
      url: `/${SKILL_PATH}`,
      digest: `sha256:${sha256(skill)}`,
    }],
  }, null, 2) + "\n";
}

/** The ARD capability manifest (ai-catalog.json). Its one entry is the skill above: Dashbar has no API or MCP server. */
export function aiCatalog() {
  return JSON.stringify({
    specVersion: "1.0",
    host: { displayName: "Dashbar", documentationUrl: `${SITE}llms.txt`, logoUrl: `${SITE}icon.png` },
    entries: [{
      identifier: "urn:air:usedashbar.com:skill:install-dashbar",
      displayName: "Install Dashbar",
      type: "application/agent-skills+md",
      url: `${SITE}${SKILL_PATH}`,
      description: "Install, update or uninstall Dashbar, the macOS menu bar app for Claude Code and Codex.",
      representativeQueries: [
        "install Dashbar on my Mac",
        "menu bar app to see Claude Code and Codex sessions",
        "show my Claude Code plan limits in the macOS menu bar",
        "uninstall Dashbar",
      ],
    }],
  }, null, 2) + "\n";
}

/** llms.txt (llmstxt.org): what Dashbar is and where the useful pages are. */
export function llmsTxt(all) {
  const version = all[0]?.version;
  return [
    `# Dashbar`,
    `> ${plain(HERO.lede)}`,
    `Dashbar is a native menu bar app for macOS 14 or later, on Apple silicon and Intel. It reads what ${listOf(HERO.worksWith.tools)} record about their sessions on the Mac, the listening ports and processes, and the folders you choose. It is free and open source under the MIT licence. The app has no account and no analytics.${version ? ` The current version is ${version}.` : ""}`,
    `## Docs`,
    [
      `- [Homepage as Markdown](${SITE}index.md): features, what it reads and sends, what’s new, the FAQ and how to install`,
      `- [Full text](${SITE}llms-full.txt): the homepage plus the notes for every release`,
      `- [README](${REPO}/blob/main/README.md): features, settings, privacy and building from source`,
      `- [FAQ](${SITE}#faq): supported agents, Claude plan limits, widgets, privacy, updating and uninstalling`,
      `- [Privacy](${SITE}#privacy): every file it reads and the only two requests it can make`,
      `- [Privacy policy](${SITE}privacy): what the app and this website do with data, and who to contact`,
    ].join("\n"),
    `## Install`,
    [
      `- [Download the DMG${version ? ` (${version})` : ""}](${downloadUrl(version)}): open it and drag Dashbar to Applications`,
      `- [Homebrew cask](https://github.com/stevenmckinnon/homebrew-tap): \`${BREW}\``,
      `- [Install skill for agents](${SITE}${SKILL_PATH}): install, update and uninstall steps`,
    ].join("\n"),
    `## Project`,
    [
      `- [Source on GitHub](${REPO})`,
      `- [Releases](${REPO}/releases)`,
      `- [MIT licence](${REPO}/blob/main/LICENSE)`,
      `- [Issues](${REPO}/issues): bug reports and requests for more agents`,
    ].join("\n"),
    `## Optional`,
    `- [Contact](mailto:hello@usedashbar.com): hello@usedashbar.com`,
  ].join("\n\n") + "\n";
}

/** sitemap.xml. index.md is left out so search engines don't index it as a copy of the page; llms.txt and
 * the <link rel="alternate"> in index.html point agents to it. */
export function sitemap() {
  // Each page with what its content is made from, so lastmod moves only when that page changes.
  const page = ["site/index.html", "site/src", "release-notes", "appcast.xml"];
  const urls = [
    ["", page],
    ["privacy", ["site/privacy.html", "site/src/policy.js"]],
    ["llms.txt", ["site/agent-files.js", "site/src/content.js", "site/src/faq.js", "release-notes", "appcast.xml"]],
    ["llms-full.txt", ["site/agent-files.js", "site/src/content.js", "site/src/faq.js", "release-notes", "appcast.xml"]],
  ];
  return [
    `<?xml version="1.0" encoding="UTF-8"?>`,
    `<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">`,
    ...urls.map(([u, paths]) => {
      const day = lastCommitDay(paths);
      return `  <url><loc>${SITE}${u}</loc>${day ? `<lastmod>${day}</lastmod>` : ""}</url>`;
    }),
    `</urlset>`,
  ].join("\n") + "\n";
}

export { SKILL_PATH };
