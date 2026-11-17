import { defineConfig } from "vite";
import { mkdirSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import react from "@vitejs/plugin-react";
import { FAQ } from "./src/faq.js";
import { SITE, REPO, HERO, FEATURES, plain, worksWithText } from "./src/content.js";
import { POLICY, policyHtml } from "./src/policy.js";
import * as agent from "./agent-files.js";

const esc = (t) => t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const isHome = (ctx) => ctx.path === "/index.html" || ctx.path === "/";
// Shown until React mounts, then replaced; visually hidden meanwhile, so readers without JavaScript and crawlers get it.
const hideFallback =
  `  <script>document.documentElement.className="js"</script>\n` +
  `  <style>.js .seo-fallback{position:absolute;width:1px;height:1px;overflow:hidden;clip-path:inset(50%);white-space:nowrap}</style>\n</head>`;

// Writes the FAQ into index.html as structured data, from the same list the page renders.
const faqSchema = {
  name: "faq-schema",
  transformIndexHtml(html, ctx) {
    if (!isHome(ctx)) return html;
    const data = {
      "@context": "https://schema.org",
      "@type": "FAQPage",
      mainEntity: FAQ.map(({ q, a }) => ({ "@type": "Question", name: q, acceptedAnswer: { "@type": "Answer", text: a } })),
    };
    return html.replace("</head>", `  <script type="application/ld+json">${JSON.stringify(data)}</script>\n</head>`);
  },
};

// SoftwareApplication structured data, plus the page's main text inside #root for crawlers and readers
// without JavaScript. React replaces #root's contents when it mounts, so the page looks and works as
// before. While scripts are enabled the text is visually hidden (not display:none) until then.
const seo = {
  name: "seo",
  transformIndexHtml(html, ctx) {
    if (!isHome(ctx)) return html;
    const version = agent.releases()[0]?.version ?? null;
    const app = {
      "@context": "https://schema.org",
      "@type": "SoftwareApplication",
      name: "Dashbar",
      description: plain(HERO.lede),
      url: SITE,
      operatingSystem: "macOS 14+",
      applicationCategory: "DeveloperApplication",
      offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
      downloadUrl: agent.downloadUrl(version),
      ...(version ? { softwareVersion: version } : {}),
      license: `${REPO}/blob/main/LICENSE`,
      codeRepository: REPO,
      sameAs: [REPO],
      image: `${SITE}icon.png`,
      screenshot: [`${SITE}overview-light.png`, `${SITE}agents-light.png`, `${SITE}window-light.png`],
      author: { "@type": "Person", name: "Steve McKinnon", url: "https://steve.mn" },
      featureList: FEATURES.map((f) => f.name),
    };
    const fallback = [
      `<div class="seo-fallback">`,
      `<h1>${esc(HERO.headline)}</h1>`,
      `<p>${esc(plain(HERO.lede))}</p>`,
      `<p>${esc(worksWithText())}</p>`,
      `<h2>What it shows</h2>`,
      ...FEATURES.map((f) => `<h3>${esc(f.name)}</h3><p>${esc(plain(f.text))}</p>`),
      `<h2>Questions</h2>`,
      ...FAQ.map(({ q, a }) => `<h3>${esc(q)}</h3><p>${esc(a)}</p>`),
      `<p><a href="${REPO}/releases/latest">Download</a> · <a href="${REPO}">Source on GitHub</a></p>`,
      // KittyLaunch's checker reads the page without running it, so the footer's badge is here too.
      `<p><a href="https://kittylaunch.com/p/dashbar?utm_source=badge" target="_blank" rel="noopener"><img src="/badges/kittylaunch-light.svg" width="120" height="120" alt="Dashbar, Verified by KittyLaunch" data-kittylaunch-badge="1" /></a></p>`,
      `<p>For AI agents: this page is also at <a href="/index.md">/index.md</a> as Markdown, and <a href="/llms.txt">/llms.txt</a> lists the useful links.</p>`,
      `</div>`,
    ].join("\n");
    return html
      .replace(
        "</head>",
        `  <script type="application/ld+json">${JSON.stringify(app)}</script>\n` +
          `  <script>document.documentElement.className="js"</script>\n` +
          `  <style>.js .seo-fallback{position:absolute;width:1px;height:1px;overflow:hidden;clip-path:inset(50%);white-space:nowrap}</style>\n</head>`,
      )
      .replace('<div id="root"></div>', () => `<div id="root">\n${fallback}\n</div>`);
  },
};

// The privacy policy, a second page (privacy.html, from src/policy.js). Its text goes into the HTML as well, like the
// homepage's. Cloudflare serves privacy.html at /privacy; a copy at privacy/index.html makes /privacy/ work too.
const privacyPage = {
  name: "privacy-page",
  transformIndexHtml(html, ctx) {
    if (ctx.path !== "/privacy.html") return html;
    return html
      .replaceAll("{{policy-description}}", esc(POLICY.description).replace(/"/g, "&quot;"))
      .replace("</head>", hideFallback)
      .replace('<div id="root"></div>', () => `<div id="root">\n<div class="seo-fallback">\n${policyHtml()}\n</div>\n</div>`);
  },
  writeBundle(options, bundle) {
    const page = bundle["privacy.html"];
    if (!page) throw new Error("privacy-page: privacy.html missing from the build");
    mkdirSync(`${options.dir}/privacy`, { recursive: true });
    writeFileSync(`${options.dir}/privacy/index.html`, page.source);
  },
};

// The files for agents and crawlers (see agent-files.js), written next to index.html. robots.txt is static, in
// docs/images. index.md is linked from index.html, and site/worker serves it to agents that ask for text/markdown.
const agentFiles = {
  name: "agent-files",
  apply: "build",
  generateBundle() {
    const all = agent.releases();
    const skill = agent.skillMd();
    const files = {
      "index.md": agent.indexMd(all),
      "llms.txt": agent.llmsTxt(all),
      "llms-full.txt": agent.llmsFullTxt(all),
      "sitemap.xml": agent.sitemap(),
      [agent.SKILL_PATH]: skill,
      ".well-known/agent-skills/index.json": agent.skillsIndex(skill),
      ".well-known/ai-catalog.json": agent.aiCatalog(),
    };
    for (const [fileName, source] of Object.entries(files)) this.emitFile({ type: "asset", fileName, source });
  },
};

// The site's visit counter (Cloudflare Web Analytics, no cookies) sits in index.html so built pages carry it
// as written. The dev server drops it, so working on the site never counts as a visit.
const noAnalyticsInDev = {
  name: "no-analytics-in-dev",
  apply: "serve",
  transformIndexHtml: (html) =>
    html.replace(/\s*<!-- Cloudflare Web Analytics -->[\s\S]*?<!-- End Cloudflare Web Analytics -->/, ""),
};

// Pictures live in docs/images (the README uses them too); Vite copies them to the site root.
export default defineConfig({
  base: "/",
  plugins: [react(), faqSchema, seo, privacyPage, agentFiles, noAnalyticsInDev],
  publicDir: "../docs/images",
  // "What's new" reads release-notes/ and appcast.xml from the repository root.
  server: { fs: { allow: [".."] } },
  build: {
    rollupOptions: {
      input: {
        main: fileURLToPath(new URL("index.html", import.meta.url)),
        privacy: fileURLToPath(new URL("privacy.html", import.meta.url)),
        notFound: fileURLToPath(new URL("404.html", import.meta.url)),
      },
    },
  },
});
