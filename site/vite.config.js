import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Pictures live in docs/images (the README uses them too); Vite copies them to the site root.
export default defineConfig({
  base: "./",
  plugins: [react()],
  publicDir: "../docs/images",
});
