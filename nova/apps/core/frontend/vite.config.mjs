import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL(".", import.meta.url));

export default defineConfig({
  plugins: [react()],
  resolve: { alias: { "@": path.resolve(root, "src") } },
  server: {
    host: process.env.HOST || "127.0.0.1",
    port: Number(process.env.PORT || 3002),
    strictPort: true,
  },
  preview: { host: "127.0.0.1", port: 4174, strictPort: true },
  build: { outDir: "build", emptyOutDir: true },
});
