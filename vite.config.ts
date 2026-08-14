import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { VitePWA } from 'vite-plugin-pwa'

// GitHub Pages project site -> everything is served under /Otopark/.
// public/404.html + the restore script in index.html make deep links work.
export default defineConfig({
  base: '/Otopark/',
  plugins: [
    react(),
    tailwindcss(),
    VitePWA({
      // 'prompt', never 'autoUpdate': an operator must not have the page
      // reload out from under them while a plate is half-typed at the gate.
      registerType: 'prompt',
      includeAssets: ['icons/apple-touch-icon.png'],
      manifest: {
        name: 'Otopark Yönetimi',
        short_name: 'Otopark',
        description: 'Otopark giriş/çıkış, ücret tahsilatı ve abonman yönetimi',
        lang: 'tr',
        dir: 'ltr',
        start_url: '/Otopark/',
        scope: '/Otopark/',
        display: 'standalone',
        orientation: 'portrait',
        theme_color: '#14161A',
        background_color: '#F5F6F8',
        icons: [
          { src: 'icons/icon-192.png', sizes: '192x192', type: 'image/png' },
          { src: 'icons/icon-512.png', sizes: '512x512', type: 'image/png' },
          {
            src: 'icons/icon-512-maskable.png',
            sizes: '512x512',
            type: 'image/png',
            purpose: 'maskable',
          },
        ],
      },
      workbox: {
        // App shell precached. Supabase is deliberately NOT runtime-cached:
        // a stale fee or a stale occupancy count is worse than a spinner.
        globPatterns: ['**/*.{js,css,html,woff2,png,svg}'],
        clientsClaim: true,
        navigateFallback: '/Otopark/index.html',
        // Web Push handlers live in public/push-sw.js and ride inside the
        // generated Workbox service worker.
        importScripts: ['push-sw.js'],
      },
    }),
  ],
})
