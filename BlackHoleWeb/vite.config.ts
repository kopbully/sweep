import { defineConfig } from "vite";

export default defineConfig({
  base: "./",
  build: {
    outDir: "../Sources/Sweep/Resources/BlackHole",
    emptyOutDir: true,
    lib: {
      entry: "src/main.ts",
      name: "SweepHoleWidget",
      formats: ["iife"],
      fileName: () => "black-hole.js",
    },
    sourcemap: false,
  },
});
