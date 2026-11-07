import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { FAQ } from "./src/faq.js";

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

// Pictures live in docs/images (the README uses them too); Vite copies them to the site root.
export default defineConfig({
  base: "./",
  plugins: [react(), faqSchema],
  publicDir: "../docs/images",
});
