import { defineConfig } from 'vite'
import legacy from '@vitejs/plugin-legacy'

// The P2 terminal (spec 2026-11-28): a second, light app for the gate
// handheld, whose Chrome is stuck at 56. plugin-legacy with modern chunks off
// emits only classic SystemJS scripts (`nomodule`), lowered to Chrome 56 with
// the core-js polyfills it needs. Checked by tests/terminalDerleme.check.mjs.
export default defineConfig({
  root: 'terminal',
  base: '/Otopark/terminal/',
  // The repo's .env* files live at the root, next to the main app's config.
  envDir: '..',
  // Vite 8 transforms with Oxc (esbuild options are deprecated).
  oxc: { jsx: { runtime: 'automatic', importSource: 'preact' } },
  build: {
    outDir: '../dist/terminal',
    emptyOutDir: true,
  },
  plugins: [
    legacy({
      targets: ['chrome >= 56'],
      renderModernChunks: false,
    }),
  ],
})
