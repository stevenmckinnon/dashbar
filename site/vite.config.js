import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { readFileSync } from "node:fs";
import { FAQ } from "./src/faq.js";
import { HERO, FEATURES } from "./src/seo.js";

const SITE = "https://stevenmckinnon.github.io/dashbar/";
const REPO = "https://github.com/stevenmckinnon/dashbar";
const esc = (t) => t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

// The newest version in the update feed, as the Download button uses.
function latestVersion() {
  try {
    const xml = readFileSync(new URL("../appcast.xml", import.meta.url), "utf8");
    const all = [...xml.matchAll(/<sparkle:shortVersionString>([^<]+)</g)].map((m) => m[1].trim());
    return all.sort((a, b) => b.localeCompare(a, undefined, { numeric: true }))[0] ?? null;
  } catch {
    return null;
  }
}

// Writes the FAQ into index.html as structured data, from the same list the page renders.
const faqSchema = {
  name: "faq-schema",
  transformIndexHtml(html) {
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
  transformIndexHtml(html) {
    const version = latestVersion();
    const app = {
      "@context": "https://schema.org",
      "@type": "SoftwareApplication",
      name: "Dashbar",
      description: HERO.lede,
      url: SITE,
      operatingSystem: "macOS 14+",
      applicationCategory: "DeveloperApplication",
      offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
      downloadUrl: version ? `${REPO}/releases/download/v${version}/Dashbar-${version}.dmg` : `${REPO}/releases/latest`,
      ...(version ? { softwareVersion: version } : {}),
      license: `${REPO}/blob/main/LICENSE`,
      codeRepository: REPO,
    };
    const fallback = [
      `<div class="seo-fallback">`,
      `<h1>${esc(HERO.headline)}</h1>`,
      `<p>${esc(HERO.lede)}</p>`,
      `<h2>What it shows</h2>`,
      ...FEATURES.map((f) => `<h3>${esc(f.name)}</h3><p>${esc(f.text)}</p>`),
      `<h2>Questions</h2>`,
      ...FAQ.map(({ q, a }) => `<h3>${esc(q)}</h3><p>${esc(a)}</p>`),
      `<p><a href="${REPO}/releases/latest">Download</a> · <a href="${REPO}">Source on GitHub</a></p>`,
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

// Pictures live in docs/images (the README uses them too); Vite copies them to the site root.
export default defineConfig({
  base: "./",
  plugins: [react(), faqSchema, seo],
  publicDir: "../docs/images",
  // "What's new" reads release-notes/ and appcast.xml from the repository root.
  server: { fs: { allow: [".."] } },
});
