# P2 terminal — design

**Owner, 28.11.2026:** the gate handheld is a Sunmi P2 (T6900, 1 GB RAM,
Android 7.1.1). Its Chrome is stuck at **56.0.2924.87** and cannot be updated
(P-series devices install only from Sunmi's App Store; the Paycell lock blocks
everything else, and debug mode is irreversible, so it stays off). The app
needs Chrome 111+, so in Chrome it is a white page. Firefox 107.2.0 opens it
at about **10 s per screen** and cannot print. The owner chose **fast screens**:
a separate, light terminal app that runs in Chrome 56 and prints the fiş
there.

## Why
The Personel works the gate with the P2 in hand: open a ticket, take the
money, let the car out, print the fiş. Every second per screen is a car
waiting at the barrier. The full app stays the tool for the Yönetici and for
phones; the P2 gets only what the gate needs, made for that one device.

## Goals
- Every gate task the owner listed, usable on the P2 in Chrome 56.
- A screen switch feels instant (target < 300 ms on the P2). The first load is
  a few seconds at most on the site's Wi-Fi.
- Entry and exit fiş print from the same page (Chrome 56 `window.print()`
  prints a correct 58 mm fiş, tested 25.11, "Deneme 1").
- **The same database rules.** The terminal calls the same RPCs, tables and
  Edge Functions as the app, with the signed-in Personel's own session. No new
  rights and no migration for the terminal itself.

## Non-goals
- Yönetici work: Finans, Rapor, Onay, Tarife, Personel, Kırpma, Ayarlar,
  Çöp Kutusu. Those stay in the full app.
- The profile page (owner: skip).
- Notifications. They stay in the full app (my call; the owner didn't list
  them).
- Running on any other device or browser. The target is exactly the P2.
- Offline use. Without the network the terminal says so and does nothing.

## Anti-goals (a failure even if it works)
- A rule that exists only in the terminal. Security stays in Postgres.
- A fee computed on the device. The server prices every fee (`ucret_hesapla`,
  `bilet_ucret_onizle`); the terminal only shows it.
- Slow screens: heavy lists, big images loaded up front, animations.
- Two diverging versions of the same logic. Money, plate, fiş text, card
  wording and time come from the existing pure modules, never re-written.

## Constraints (Chrome 56)
- **JavaScript:** ES2016 plus `async`/`await` (55). Missing, and must be
  lowered or polyfilled: object spread/rest (60), `?.` and `??` (80), optional
  `catch {}` binding (66), `Promise.prototype.finally` (63),
  `String.prototype.padStart`/`padEnd` (57), `Object.fromEntries`,
  `Array.prototype.flat`, `AbortController` (66). There are no ES modules
  (`<script type="module">` is 61), so the bundle is classic scripts.
- **CSS:** custom properties and flexbox work. **No CSS grid (57), no flex
  `gap` (84)**: spacing with margins. No `aspect-ratio`, `inset`, `:is`,
  `color-mix`, `oklch`, `@layer`. That rules out Tailwind v4, which needs 111+.
- **Images:** `loading="lazy"` is 76. `IntersectionObserver` (51) works.
- **Device:** 1 GB RAM, slow CPU (the bench imitates it at 4×), 360 px wide.
  Camera photo shrink to the OCR size takes 1.2 s (tested, "Deneme 4").

## Approaches
1. **A separate light terminal app for Chrome 56 in this repo (chosen by the
   owner).** Its own entry page and old-browser build; it reuses the pure
   logic modules and the same server. Cost the owner accepted: every later
   Personel feature is built twice, once in the app and once in the terminal.
2. **The full app in Firefox, with the fiş opened in Chrome 56 by an intent
   link.** Tested and it prints ("Deneme 3"), but Firefox stays at ~10 s per
   screen. Rejected by the owner: too slow.
3. **Make the full app run on Chrome 56.** Rejected: too heavy for 1 GB, and
   the layout uses grid, flex `gap` and Tailwind v4.
4. **Another device** (an Android 10+ phone plus a 58 mm Bluetooth printer).
   Not chosen now; it stays the fallback if the P2 proves too slow.
Also ruled out: Rust/WebAssembly (Wasm arrived in Chrome 57, and the P2
can't install our own APK); lowering the screen resolution from a web page.

## Decided by the owner
- **Scope:** PIN and Devral; Gişe with Giriş, İçeride, Çıkış, Tahsil,
  Çıkış Ver, Ücretsiz, Araç çıkmadı; entry and exit fiş; **Çözülmemiş
  kayıtlar ("very important")**; photos in cards, kayıtlar and tickets;
  Abonman; plate reading from the P2's own camera in Giriş.
- **Also on the P2 (owner, 28.11):** Oto yıkama, Anlaşmalı fiyat, Plaka
  düzelt, Kayıp bilet and İptal. They go into stage 2.
- **Stages,** each usable on the P2 before the next starts:
  1. PIN, Devral, Giriş with camera plate reading, the entry fiş.
  2. İçeride, Çıkış, Tahsil, Çıkış Ver, Ücretsiz, Araç çıkmadı, the exit
     fiş, photos (plus the extras below).
  3. Çözülmemiş kayıtlar with photos.
  4. Abonman.
- **Look:** made for exactly 360 px; flat colours, no shadows, blur or
  animations; few elements per screen.
- **Data:** polling instead of realtime.
- **Photos:** loaded only when on screen and shown small; full size on tap.

## The design (my calls unless marked)

### Where it lives and how it ships
- `terminal/` at the repo root: `terminal/index.html`, `terminal/src/`, its
  own `vite.terminal.config.ts`. It is served at **`/Otopark/terminal/`** on
  the same GitHub Pages site. `npm run build` builds both apps;
  `deploy.yml` uploads both.
- **Hash routes** (`#/gise`, `#/bilet/<id>`): no 404 trick needed for deep
  links, and no router library.
- **No service worker.** On the P2, the main app's worker never registers
  (its code doesn't run in Chrome 56), so it can't hijack `/terminal/`. The
  terminal registers none: a stale fee is worse than a reload.
- The Personel opens `…/Otopark/terminal/` on the P2 and adds it to the home
  screen.

### Build
- Vite with `@vitejs/plugin-legacy` (targets `chrome >= 56`, modern chunks
  off). That gives classic `nomodule` scripts, lowered syntax and the needed
  `core-js` polyfills. The builder checks that the plugin version matches our
  Vite 8 first. If it doesn't, the fallback is a single IIFE bundle (esbuild
  `target: chrome56`) plus a hand-picked polyfill file.
- **UI: Preact** (about 4 KB, runs on old browsers) with hooks. React 19 and
  TanStack Query are too heavy for this device and aren't needed for a dozen
  screens.
- **CSS:** one hand-written stylesheet, flexbox and margins only. Colour
  tokens are copied from `src/styles/index.css`, light theme only (a sunny
  gate; one theme is half the testing). Tap targets ≥ 44 px, base text 16 px.
- **Budget:** JS ≤ 100 KB gzip, CSS ≤ 15 KB. A check fails the build above it.

### Server access: a small fetch client (no supabase-js)
supabase-js leans on things Chrome 56 lacks (`AbortController`, Web Locks,
modern syntax in its dependencies) and is large. The terminal gets a
~200-line client in `terminal/src/sunucu.ts`, using the same URL and
publishable key as the app (`VITE_SUPABASE_URL`,
`VITE_SUPABASE_PUBLISHABLE_KEY`):
- `rpc(ad, args)` → `POST /rest/v1/rpc/<ad>`;
- `sec(tablo, sorgu)` → `GET /rest/v1/<tablo>?…` with the same filters the app
  uses;
- `fn(ad, govde)` → `POST /functions/v1/<ad>`;
- `imzaliUrl(kova, yol)` → `POST /storage/v1/object/sign/<kova>/<yol>`;
- auth: `verify` (`POST /auth/v1/verify`, `type: 'email'`, the `token_hash`
  from `terminal-giris`), `refresh`
  (`POST /auth/v1/token?grant_type=refresh_token`), `password` (Yönetici
  setup only), `logout`.
- The session goes in localStorage under `op.terminal.oturum`, apart from
  supabase-js's key. The token is refreshed shortly before expiry and once on
  a 401, then the call is retried once.
- Error text: the server's Turkish message when there is one, as in
  `rpcErrorText`. That logic is shared, not copied.
- Timeouts without `AbortController`: a `Promise.race` with a 15 s timer that
  shows "Bağlantı yavaş — tekrar deneyin". The request is not cancelled.

### Becoming a terminal and the PIN
- The terminal record is the same `op.terminal` {id, ad, gizli} as 084
  (`src/features/terminal/terminal.ts`, reused). The full app's "Bu cihazı
  terminal yap" can't run on the P2, so the terminal has its own **Kurulum**
  screen: a Yönetici signs in with e-mail and password, gives the device a
  name, `terminal_kaydet` stores the secret, and the Yönetici is signed out
  again. Same RPC, same rights.
- **PIN screen** (the home screen when nobody is signed in): the Personel list
  from `terminal-giris` `islem: 'liste'`, tap a name, a 4-digit keypad, then
  `terminal-giris` `islem: 'giris'` → `verify`. Lockout messages come from the
  server as today.
- **Devral:** the same flow while someone else is signed in (084's
  `vardiya_devret` path, exactly as `Devral.tsx` does it).
- Signing out leaves `op.terminal` in place, as in 084.

### Screens (360 px, one task each)
Stage 1
- **PIN / Devral** (above).
- **Gişe**: a top bar with the signed-in name, Devral, and the open count. Two
  big buttons, **Giriş** and **Çıkış**, then the İçeride list (stage 2).
- **Giriş**: plate field (normalised with `src/lib/plaka.ts`), **Fotoğraf
  çek** (`<input type="file" accept="image/*" capture="environment">` →
  shrink with `src/lib/image.ts` → `plaka-oku` → prefilled field, never
  auto-saved), vehicle type, **Giriş aç** (`bilet_ac`, same arguments as
  `Giris.tsx`). Then the fiş sheet right away.
- **Entry fiş**: "Müşteri ne kadar kalacak?" with the ticket's tariff bands
  (`fisSecenek.ts`, `fis_tahmini`), then **Yazdır**: `fis_basildi` first,
  then fill a print-only block from `fisIcerik.ts`, then `window.print()`
  (same order as `FisSayfasi.tsx`).

Stage 2
- **İçeride**: a plain list (plate, entry time, running fee from the server),
  20 rows at a time with "Daha fazla", and a search box. It polls every
  15 s while the page is visible.
- **Çıkış**: search by plate (`acik_bilet_ara`), the ticket, the fee
  (`bilet_ucret_onizle`), then **Tahsil** (`bilet_tahsil`, cash / card /
  havale), **Çıkış Ver** (`bilet_kapat`), **Ücretsiz** (reason and note,
  `bilet_ucretsiz_cikis`) and **Araç çıkmadı** (`bilet_cikis_geri_al` /
  `bilet_kamera_geri_ac`, reason required). Then the exit fiş.
- **Süre aşımı:** the decision block (`bilet_asim_onizle`,
  `bilet_asim_karar`) wherever the app shows it. Without it, an over-time
  ticket can't be collected or let out (082), so stage 2 can't work without
  it.
- **Ticket view**: plate, times, fee, payments, the photo, and the extra
  actions the owner added: **Oto yıkama** (`bilet_yikama`), **Anlaşmalı
  fiyat** (`bilet_anlasma`, `bilet_anlasma_fazla`), **Plaka düzelt**
  (`bilet_plaka_duzelt`), **Kayıp bilet** (`kayip_bilet_tahsil`) and **İptal**
  (`bilet_iptal`). Each one behaves exactly as for a Personel in the app
  (`BiletDetay.tsx`, `gise/api.ts`): same rules, same reasons asked. Only
  what the server already allows a Personel shows up.
- **Exit fiş**: same pattern as the entry fiş.

Stage 3
- **Çözülmemiş kayıtlar**: the Bekleyen list only (Personel can read only
  waiting rows), polled every 15 s. Each card's status line, what-to-do line
  and buttons come from `src/features/istisna/kart.ts` unchanged. Actions:
  `istisna_bilet_ac`, `istisna_bilet_ac_saatli`, `istisna_coz`, Çıkış (opens
  terminal Çıkış with the plate), Bilete git. A count badge on Gişe.

Stage 4
- **Abonman**: search a plate (`abonman_gecerli_mi`), the list, and the
  actions the Personel has in the app today (`abonman_tahsil` etc.). The
  builder reads `src/features/abonman/` for the exact set.

### Photos
- Loaded when the card scrolls into view (`IntersectionObserver`). The
  signed URL is fetched once per photo and kept in memory for its life
  (10 min, as in `gise/api.ts`).
- Shown about 96 px tall. A tap opens it full width with a close button.
- At most 3 photos load at the same time.

### Polling
- Only the screen on top polls; nothing polls while the page is hidden
  (`visibilitychange`). İçeride and Çözülmemiş: 15 s. Badge counts: 60 s.

## Testing
- **Tests first** (CLAUDE.md). The new pure parts get Node checks under
  `tests/terminal*.check.mjs` before their code: the fetch client's request
  building, session refresh and timeout logic, the screen selectors, and the
  print block's content.
- **Old-browser check** (like `yaziciKlasik.check.mjs`): parse the built
  terminal JS with `acorn` at `ecmaVersion: 2017`, with no `type="module"`;
  scan the built CSS for `grid`, `gap`, `inset`, `aspect-ratio`, `:is(`,
  `oklch`, `color-mix`, `@layer`. Plus the size budget.
- **Bench:** `tools/cihaz-testi/p2_tezgahi.mjs` with a **Chromium 56** build
  (download only after asking the owner), 4× CPU, 360 px, measuring time to
  usable and screen switches.
- **On the P2** at the end of each stage, by the owner. Stage 1 isn't done
  until an entry fiş prints on paper.
- Server rules don't change, so the smoke test is unchanged.

## Left to the builder
- Exact file split inside `terminal/src/`, component names, CSS class names.
- Which module-level helpers in `src/` need `import type`-only cleanup so the
  terminal build doesn't pull in React or supabase-js. Check the bundle for
  stray React imports.
- The plugin-legacy vs IIFE choice, after checking the Vite 8 plugin version.
- Wording of new Turkish texts, in the same plain style as the 28.11
  Çözülmemiş wording.
