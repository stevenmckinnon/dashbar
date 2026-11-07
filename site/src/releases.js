// "What's new" comes from the same files as the update dialog: release-notes/X.Y.Z.md. A version only appears
// once it has an entry in appcast.xml, which the release script writes, so notes committed ahead of a
// release stay hidden until it ships. The appcast also supplies the date.
import appcast from "../../appcast.xml?raw";

const files = import.meta.glob("../../release-notes/*.md", { query: "?raw", import: "default", eager: true });

function released() {
  const dates = new Map();
  try {
    const xml = new DOMParser().parseFromString(appcast, "application/xml");
    for (const item of xml.querySelectorAll("item")) {
      const version = item.getElementsByTagName("sparkle:shortVersionString")[0]?.textContent?.trim();
      const date = new Date(item.querySelector("pubDate")?.textContent ?? "");
      if (version && !Number.isNaN(date.getTime())) dates.set(version, date);
    }
  } catch { /* no feed, no notes */ }
  return dates;
}

const byVersion = (a, b) => b.version.localeCompare(a.version, undefined, { numeric: true });

export const RELEASE_NOTES = (() => {
  const dates = released();
  return Object.entries(files)
    .map(([path, md]) => ({ version: path.split("/").pop().replace(/\.md$/, ""), md }))
    .filter(({ version }) => dates.has(version))
    .map(({ version, md }) => ({ version, date: dates.get(version), blocks: parse(md) }))
    .sort(byVersion);
})();

/** The few Markdown features the notes use: bullet lists, paragraphs, **bold** and `code`. */
function parse(md) {
  const blocks = [];
  for (const line of md.split("\n")) {
    const text = line.trim();
    if (!text) continue;
    const bullet = text.match(/^[-*]\s+(.*)/);
    if (bullet) {
      const last = blocks[blocks.length - 1];
      if (last?.list) last.items.push(bullet[1]);
      else blocks.push({ list: true, items: [bullet[1]] });
    } else blocks.push({ text });
  }
  return blocks;
}

export function inline(text) {
  return text.split(/(\*\*[^*]+\*\*|`[^`]+`)/).filter(Boolean).map((part, i) => {
    if (part.startsWith("**")) return { key: i, tag: "strong", text: part.slice(2, -2) };
    if (part.startsWith("`")) return { key: i, tag: "code", text: part.slice(1, -1) };
    return { key: i, tag: null, text: part };
  });
}
