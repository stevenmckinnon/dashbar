// Runs only for "/" (wrangler.jsonc run_worker_first). Agents that prefer text/markdown get /index.md, the
// Markdown copy agent-files.js writes at build time; browsers get index.html. Both carry a Link header pointing
// at the Markdown copy and llms.txt.
const LINK = [
  '</index.md>; rel="alternate"; type="text/markdown"',
  '</llms.txt>; rel="describedby"; type="text/plain"',
  '</sitemap.xml>; rel="sitemap"; type="application/xml"',
].join(", ");

// The q value the Accept header gives a media type (0 if absent), honouring type/* and */*.
function quality(accept, type) {
  let best = 0;
  let bestSpecificity = -1;
  for (const part of (accept || "").split(",")) {
    const [range, ...params] = part.trim().toLowerCase().split(";");
    const r = range.trim();
    const specificity = r === type ? 2 : r === type.split("/")[0] + "/*" ? 1 : r === "*/*" ? 0 : -1;
    if (specificity < 0 || specificity < bestSpecificity) continue;
    const q = params.map((p) => p.trim()).find((p) => p.startsWith("q="));
    const value = q ? Number.parseFloat(q.slice(2)) : 1;
    if (specificity > bestSpecificity || value > best) best = Number.isFinite(value) ? value : 0;
    bestSpecificity = specificity;
  }
  return best;
}

// Only an explicit text/markdown counts: `*/*` (curl, most clients) keeps getting HTML.
export function prefersMarkdown(accept) {
  const named = (accept || "").toLowerCase().split(",").some((p) => p.trim().split(";")[0].trim() === "text/markdown");
  if (!named) return false;
  const md = quality(accept, "text/markdown");
  return md > 0 && md >= quality(accept, "text/html");
}

function withHeaders(response, extra) {
  const headers = new Headers(response.headers);
  for (const [k, v] of Object.entries(extra)) headers.set(k, v);
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/" && prefersMarkdown(request.headers.get("Accept"))) {
      const md = await env.ASSETS.fetch(new Request(new URL("/index.md", url), request));
      if (md.ok) {
        return withHeaders(md, { "Content-Type": "text/markdown; charset=utf-8", Vary: "Accept", Link: LINK });
      }
    }
    const response = await env.ASSETS.fetch(request);
    return url.pathname === "/" ? withHeaders(response, { Vary: "Accept", Link: LINK }) : response;
  },
};
