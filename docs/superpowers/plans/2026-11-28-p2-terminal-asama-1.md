# P2 Terminal — Stage 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A light terminal app at `/Otopark/terminal/` that runs in the P2's Chrome 56 and does stage 1: Kurulum, PIN, Devral, Giriş with camera plate reading, and the entry fiş printed on paper.

**Architecture:** A second Vite build (`vite.terminal.config.ts`, Preact, `@vitejs/plugin-legacy` for Chrome 56) next to the main app. It talks to Supabase through a small fetch client (no supabase-js) with the same RPCs, tables and Edge Functions. Pure logic is reused from `src/lib` and `src/features/*` (all `import type`-only modules), never rewritten.

**Tech Stack:** Preact 10 + hooks, Vite 8, `@vitejs/plugin-legacy`, `acorn` (old-browser check, dev only), Node checks in `tests/*.check.mjs`.

**Spec:** `docs/superpowers/specs/2026-11-28-p2-terminal-design.md` (approved 28.11).

**Scope (my call):** this plan is **stage 1 only**. The spec says each stage is used on the P2 before the next starts, so stages 2–4 get their own plans after the owner has used stage 1 on the P2. They are written with what stage 1 taught us.

## Global Constraints
- Target: Chrome **56.0.2924.87**, 360 px wide, 1 GB RAM. No ES modules at runtime, no CSS grid, no flex `gap`, no `inset`, `aspect-ratio`, `:is(`, `oklch`, `color-mix`, `@layer`.
- JS ≤ **100 KB gzip** (all terminal JS files), CSS ≤ **15 KB gzip**. The old-browser check fails above that.
- Same server: only existing RPCs, tables and Edge Functions. No migration, no new grant.
- The server prices every fee; the terminal only shows it. Money is integer kuruş, formatted with `src/lib/money.ts`.
- Times shown in Istanbul (UTC+3) via `src/lib/dates.ts`.
- Tap targets ≥ 44 px, base text 16 px, light theme only, flat colours (tokens copied from `src/styles/index.css` light values), no shadows, blur or animations.
- All product text is Turkish, in the plain style of the 28.11 Çözülmemiş wording: short sentences, "siz" form, the button named + "basın".
- Tests first (CLAUDE.md): each check is written and seen failing before its code.
- No service worker in the terminal. The main app's worker must not serve `/Otopark/terminal/`.
- Never commit or push without the owner's go. The owner runs migrations; this plan has none.

## Review Focus
1. **The main app's service worker on a phone that already has the app** must not answer `/Otopark/terminal/` with the main app's `index.html` (`navigateFallback`). Pinned in Task 1 (`navigateFallbackDenylist` + check).
2. **An expired session mid-shift** (the Personel left the P2 idle for over an hour): the next call must refresh once and go on, not show an error. Pinned in Task 2 (401 → refresh → retry test).
3. **A slow or dead Wi-Fi at the gate:** a call that hangs must give "Bağlantı yavaş — tekrar deneyin." after 15 s and never open a second ticket on a double tap. Pinned in Task 2 (timeout test) and Task 5 (button disabled while busy, test on `girisAc` single flight).
4. **A plate photo that the model misreads or can't read:** the field is only prefilled, never saved by itself. The OCR failing must still allow typing the plate and opening the ticket. Pinned in Task 5.
5. **Printing a fiş when the number was saved but the print screen was cancelled:** the next tap gives the next number ("TEKRAR BASIM (2)"), as in the app. Pinned in Task 6 (`fis_basildi` before print, number shown on the paper).

---

## File Structure
- `package.json`: add `preact`, `@vitejs/plugin-legacy`, `acorn` (dev). Scripts: `build` builds both apps; new `build:terminal`; `typecheck` covers `tsconfig.terminal.json`.
- `vite.config.ts`: workbox `navigateFallbackDenylist: [/^\/Otopark\/terminal\//]`.
- `vite.terminal.config.ts`: root `terminal/`, base `/Otopark/terminal/`, outDir `dist/terminal`, `emptyOutDir: true` (only its own folder), legacy plugin.
- `tsconfig.terminal.json`: `jsx: react-jsx`, `jsxImportSource: preact`, includes `terminal/src` and the reused `src` modules.
- `terminal/index.html`, `terminal/src/main.tsx` (mount + hash router), `terminal/src/stil.css`.
- `terminal/src/sunucu.ts`: the fetch client (Task 2).
- `terminal/src/yol.ts`: hash route parsing (Task 3).
- `terminal/src/oturumIslem.ts`: Kurulum, Personel list, PIN sign-in (Task 4).
- `terminal/src/foto.ts`: canvas shrink (Task 5). `src/lib/fotoBoyut.ts`: `hedefBoyut` (Task 5).
- `src/lib/fotoYolu.ts`: `fotoYolu` moved out of `image.ts` and re-exported there, so the terminal doesn't pull in `browser-image-compression` (Task 5).
- `terminal/src/girisIslem.ts`: photo, OCR and `bilet_ac` (Task 5).
- `terminal/src/fisIslem.ts`: fiş options, number, print lines (Task 6).
- `terminal/src/ekranlar/Kurulum.tsx`, `Pin.tsx`, `Gise.tsx`, `Giris.tsx`, `Fis.tsx`, plus `terminal/src/parcalar.tsx` (Button, Field, Hata).
- `tests/terminalDerleme.check.mjs`, `terminalSunucu.check.mjs`, `terminalYol.check.mjs`, `terminalOturum.check.mjs`, `terminalGiris.check.mjs`, `terminalFis.check.mjs`.
- `.github/workflows/deploy.yml`: unchanged if `npm run build` builds both (check `path: dist` still covers `dist/terminal`).

---

### Task 1: Terminal build and the old-browser check

**Files:**
- Create: `vite.terminal.config.ts`, `tsconfig.terminal.json`, `terminal/index.html`, `terminal/src/main.tsx`, `terminal/src/stil.css`, `tests/terminalDerleme.check.mjs`
- Modify: `package.json`, `vite.config.ts` (workbox block)

**Interfaces:**
- Produces: `npm run build:terminal` → `dist/terminal/index.html` + classic scripts; `npm run build` → both apps.

- [ ] **Step 1: Write the failing check** `tests/terminalDerleme.check.mjs`:
  - reads `dist/terminal/index.html`; asserts no `type="module"` script is required to start (every `<script>` that boots the app is `nomodule` or classic);
  - parses every `dist/terminal/**/*.js` with `acorn.parse(src, { ecmaVersion: 2017, sourceType: 'script' })`; any throw = FAIL naming the file;
  - scans `dist/terminal/**/*.css` for `display:grid`, `gap:`, `inset:`, `aspect-ratio`, `:is(`, `oklch(`, `color-mix(`, `@layer`; any hit = FAIL;
  - gzip sizes (`node:zlib` `gzipSync`): JS total ≤ 102400 bytes, CSS total ≤ 15360;
  - reads `vite.config.ts` and asserts it contains `navigateFallbackDenylist` with `/Otopark\/terminal\/`;
  - prints `N geçti, M kaldı` and exits 1 on failure, like the other checks.
- [ ] **Step 2: Run it, expect FAIL** (`node tests/terminalDerleme.check.mjs` → missing `dist/terminal/index.html`).
- [ ] **Step 3: Implement.** `npm install preact@10 @vitejs/plugin-legacy acorn -D` (preact as a dependency, the other two dev). First confirm the plugin-legacy major supports Vite 8 (`npm view @vitejs/plugin-legacy peerDependencies`). If it doesn't, use the spec's fallback: `build.target: 'chrome56'`, `rollupOptions.output.format: 'iife'`, one entry, and a `terminal/src/polyfill.ts` covering `Promise.prototype.finally`, `String.prototype.padStart/padEnd`, `Object.fromEntries`, `Array.prototype.flat`. Legacy plugin settings: `targets: ['chrome >= 56']`, `renderModernChunks: false`. `main.tsx` renders `<p>Terminal</p>` into `#uygulama`. `stil.css` has the token block (light values) and base styles. Add `navigateFallbackDenylist` in `vite.config.ts`. Scripts: `"build": "tsc --noEmit && tsc --noEmit -p tsconfig.terminal.json && vite build && vite build -c vite.terminal.config.ts"`, `"build:terminal": "vite build -c vite.terminal.config.ts"`, and `typecheck` runs both tsconfigs.
- [ ] **Step 4: Run** `npm run build` then `node tests/terminalDerleme.check.mjs` → all pass. Confirm `dist/index.html` (main app) still exists.

### Task 2: The fetch client

**Files:**
- Create: `terminal/src/sunucu.ts`, `tests/terminalSunucu.check.mjs`

**Interfaces:**
- Consumes: `rpcErrorText` from `src/lib/errors.ts`.
- Produces:
```ts
export interface Oturum { access_token: string; refresh_token: string; expires_at: number /* unix s */; user_id: string }
export interface SunucuAyar { url: string; anahtar: string; fetch: typeof fetch; depo: Storage | null; simdi: () => number /* ms */; zamanAsimiMs?: number /* default 15000 */ }
export interface Sunucu {
  rpc<T>(ad: string, args: Record<string, unknown>): Promise<T>
  sec<T>(tablo: string, sorgu: string): Promise<T[]>          // GET /rest/v1/<tablo>?<sorgu>
  fn<T>(ad: string, govde: unknown): Promise<T>               // POST /functions/v1/<ad>
  yukle(kova: string, yol: string, veri: Blob, tur: string): Promise<void>
  imzaliUrl(kova: string, yol: string, saniye: number): Promise<string>
  dogrula(tokenHash: string): Promise<Oturum>                 // POST /auth/v1/verify {type:'email', token_hash}
  sifreyleGir(eposta: string, sifre: string): Promise<Oturum> // POST /auth/v1/token?grant_type=password
  cikis(): Promise<void>
  oturum(): Oturum | null
}
export function sunucuKur(a: SunucuAyar): Sunucu
export const ZAMAN_ASIMI_METNI = 'Bağlantı yavaş — tekrar deneyin.'
export const OTURUM_ANAHTARI = 'op.terminal.oturum'
```

- [ ] **Step 1: Write the failing check** with a fake `fetch` that records requests and returns scripted responses:
  - `rpc('bilet_ac', {p_plaka:'34ABC123'})` sends `POST {url}/rest/v1/rpc/bilet_ac`, headers `apikey: anahtar`, `Authorization: Bearer <access_token>` (or the anahtar when signed out), JSON body equal to the args;
  - a 400 with `{message:'Bu plaka için zaten açık bir bilet var.'}` rejects with an Error whose message is that sentence; `{code:'PGRST202'}` gives `'Bu özellik sunucuda henüz etkin değil.'`;
  - `fn('terminal-giris', …)` 400 with `{hata:'PIN yanlış. 4 deneme hakkınız kaldı.'}` rejects with that sentence;
  - `dogrula('th')` posts `{type:'email', token_hash:'th'}` to `/auth/v1/verify`, stores the session in the fake depo under `op.terminal.oturum`, and `oturum().user_id` = the response's `user.id`;
  - with `expires_at` 30 s away, the next `rpc` first calls `/auth/v1/token?grant_type=refresh_token`, then the RPC with the new token;
  - an RPC answering 401 once: refresh, retry once, resolve; a second 401 rejects with `'Oturum sona erdi. PIN ile tekrar girin.'` and clears the session;
  - a fetch that never resolves rejects after `zamanAsimiMs` (set 50 in the test) with `ZAMAN_ASIMI_METNI`;
  - `cikis()` calls `/auth/v1/logout` and removes `op.terminal.oturum` but NOT `op.terminal`.
- [ ] **Step 2: Run, expect FAIL** (module missing).
- [ ] **Step 3: Implement `sunucuKur`.** The error path goes through `rpcErrorText(body, fallback)`; Edge Function bodies map `{hata}` to the message first. Timeout is `Promise.race` with a timer (no `AbortController`). `imzaliUrl` returns `url + '/storage/v1' + signedURL`.
- [ ] **Step 4: Run** `node tests/terminalSunucu.check.mjs` → all pass; `npm run typecheck` passes.

### Task 3: Hash routes and the app shell

**Files:**
- Create: `terminal/src/yol.ts`, `tests/terminalYol.check.mjs`, `terminal/src/parcalar.tsx`
- Modify: `terminal/src/main.tsx`

**Interfaces:**
- Produces:
```ts
export type Yol =
  | { ekran: 'kurulum' } | { ekran: 'pin' } | { ekran: 'gise' }
  | { ekran: 'giris' } | { ekran: 'fis'; biletId: string }
export function yolOku(hash: string): Yol | null   // '#/fis/<uuid>' → {ekran:'fis', biletId}
export function yolYaz(y: Yol): string             // inverse
export function acilisYolu(terminalVar: boolean, oturumVar: boolean, istenen: Yol | null): Yol
```
- `parcalar.tsx`: `Dugme({ metin, onBas, mesgul, ikincil })` (disabled + "Bekleyin…" while `mesgul`), `Alan({ etiket, ...input })`, `Hata({ metin })`.

- [ ] **Step 1: Failing check:** `yolOku('#/fis/abc')` → null (not a uuid); a uuid → `{ekran:'fis', biletId}`; `''` → null; `yolYaz(yolOku(x)) === x` for each route; `acilisYolu(false, *, *)` → kurulum; `acilisYolu(true, false, giris)` → pin; `acilisYolu(true, true, null)` → gise; `acilisYolu(true, true, {ekran:'pin'})` → pin (Devral).
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** `yol.ts`; `main.tsx` listens to `hashchange`, keeps one `sunucu` instance (from `import.meta.env.VITE_SUPABASE_URL` / `VITE_SUPABASE_PUBLISHABLE_KEY`), and renders the screen for `acilisYolu(…)`.
- [ ] **Step 4: Run** the check, `npm run build`, `node tests/terminalDerleme.check.mjs` → pass.

### Task 4: Kurulum, PIN and Devral

**Files:**
- Create: `terminal/src/oturumIslem.ts`, `tests/terminalOturum.check.mjs`, `terminal/src/ekranlar/Kurulum.tsx`, `terminal/src/ekranlar/Pin.tsx`, `terminal/src/ekranlar/Gise.tsx`

**Interfaces:**
- Consumes: `Sunucu` (Task 2); `terminalOku`, `terminalYaz`, `pinGecerli`, `TerminalKaydi` from `src/features/terminal/terminal.ts`.
- Produces:
```ts
export async function kurulumYap(s: Sunucu, depo: Storage, g: { eposta: string; sifre: string; ad: string }): Promise<TerminalKaydi>
export async function personelListesi(s: Sunucu, t: TerminalKaydi): Promise<{ id: string; ad_soyad: string }[]>
export async function pinIleGir(s: Sunucu, t: TerminalKaydi, profileId: string, pin: string): Promise<void>
export async function benKimim(s: Sunucu): Promise<{ id: string; ad_soyad: string; rol: string | null }>
```

- [ ] **Step 1: Failing check** with a fake `Sunucu`:
  - `kurulumYap` calls `sifreyleGir`, then `rpc('terminal_kaydet', {p_ad: ad})`, writes the record with `terminalYaz`, then `cikis()`. It calls `cikis()` even when `terminal_kaydet` throws (the Yönetici must not stay signed in on the P2), and rethrows;
  - `kurulumYap` with an empty `ad` rejects with `'Cihaza bir ad verin.'` before any call;
  - `personelListesi` calls `fn('terminal-giris', {islem:'liste', gizli})` and returns `personel`;
  - `pinIleGir` rejects `'PIN 4 rakam olmalı.'` when `pinGecerli` is false, with no call; otherwise `fn('terminal-giris', {islem:'giris', gizli, profile_id, pin})` then `dogrula(token_hash)`; a missing `token_hash` rejects `'Giriş yapılamadı.'`;
  - `benKimim` reads `sec('profiles', 'select=id,ad_soyad,rol&id=eq.<user_id>')`.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** `oturumIslem.ts`, then the screens:
  - **Kurulum:** "Bu cihazı terminal yap", fields E-posta, Şifre, Cihaz adı, button **Terminal yap**. Text: "Bir Yönetici bir kez giriş yapar. Sonra çıkış yapılır."
  - **Pin:** the name list (one big button per person), then a 4-digit keypad (3×4 buttons built with flex rows and margins, each ≥ 64 px), **Giriş**. Server lockout text is shown as is.
  - **Gise (stage 1 shell):** top bar with the name from `benKimim` and **Devral** (→ `#/pin`), one big **Giriş** button. The rest comes in stage 2.
- [ ] **Step 4: Run** the check, typecheck, the old-browser check → pass.

### Task 5: Giriş with camera plate reading

**Files:**
- Create: `src/lib/fotoYolu.ts`, `src/lib/fotoBoyut.ts`, `terminal/src/foto.ts`, `terminal/src/girisIslem.ts`, `tests/terminalGiris.check.mjs`, `terminal/src/ekranlar/Giris.tsx`
- Modify: `src/lib/image.ts` (re-export `fotoYolu` from `./fotoYolu`; behaviour unchanged)

**Interfaces:**
- Consumes: `normalizePlaka`, `plakaGecerli`, `formatPlaka` (`src/lib/plaka.ts`); `Sunucu`.
- Produces:
```ts
// src/lib/fotoBoyut.ts — same contract as tools/cihaz-testi/yazici/kamera.mjs, which Deneme 4 proved on the P2
export const OKUMA_KENAR = 1568, KANIT_KENAR = 1280
export function hedefBoyut(en: number, boy: number, sinir: number): { en: number; boy: number }
// terminal/src/foto.ts (browser only)
export function fotoHazirla(dosya: File): Promise<{ okumaBase64: string; kanit: Blob }>
// terminal/src/girisIslem.ts
export interface OkumaSonucu { plaka: string | null; log_id: string | null }
export async function plakaOku(s: Sunucu, okumaBase64: string): Promise<OkumaSonucu>
export async function girisAc(s: Sunucu, g: { plaka: string; kanit: Blob | null; okuma: OkumaSonucu | null; aracBilgi: string | null }): Promise<{ biletId: string; uyari: string | null }>
```

- [ ] **Step 1: Failing check:**
  - `hedefBoyut(4000, 3000, 1568)` → `{en:1568, boy:1176}`; `hedefBoyut(800, 600, 1568)` → unchanged; portrait keeps the long edge at the limit;
  - `plakaOku` calls `fn('plaka-oku', {foto_base64, media_type:'image/jpeg'})`; `{hata:'x'}` rejects with `'x'`; a result gives `{plaka, log_id}` (field names as in `PlakaOkumaSonuc`, `src/lib/types.ts`);
  - `girisAc` rejects `'Plakayı kontrol edin.'` when `plakaGecerli(normalizePlaka(p))` is false, with no call;
  - with a photo: `yukle('plaka-foto', fotoYolu('giris', plaka), kanit, 'image/jpeg')` then `rpc('bilet_ac', {...})` with `p_foto` = that path, `p_kaynak:'MOBIL'`, `p_zaman:null`, `p_islem_id` a fresh uuid, and the other params exactly as `src/features/gise/api.ts:535-549` (null where the terminal has no field);
  - a failed upload still opens the ticket, `p_foto: null`, and `uyari: 'Fotoğraf yüklenemedi, kayıt fotoğrafsız açıldı.'`;
  - with `okuma.log_id`: after `bilet_ac`, `rpc('bilet_okuma_bagla', {p_bilet_id, p_okuma_id, p_kabul: plaka})`; its failure does not reject `girisAc`;
  - **single flight:** two `girisAc` calls at the same time make ONE `bilet_ac` (the second gets the first's promise).
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** Move `fotoYolu` to `src/lib/fotoYolu.ts` and re-export it from `image.ts`; run `node tests/*.check.mjs` that touch photos to confirm no change. `foto.ts` loads the file into an `Image` via `URL.createObjectURL`, draws to a canvas at `hedefBoyut(…, OKUMA_KENAR)` → `toDataURL('image/jpeg', 0.92)` (prefix stripped), and at `KANIT_KENAR` → `toBlob(…, 'image/jpeg', 0.8)`. Don't use `File.arrayBuffer` (Chrome 76). `p_islem_id` is a v4 uuid built from `crypto.getRandomValues` (`crypto.randomUUID` is Chrome 92); the check asserts the uuid format. **Giris screen:** plate field (normalised on input), a big **Fotoğraf çek** (`<input type="file" accept="image/*" capture="environment">`) showing "Hazırlanıyor…" then "Okunuyor…", the read plate prefilled and focused (never auto-saved), optional "Araç bilgisi", **Giriş aç** (disabled while busy). On success → `#/fis/<biletId>`, with `uyari` shown on the fiş screen.
- [ ] **Step 4: Run** the check, typecheck, `npm run build`, old-browser check → pass.

### Task 6: The entry fiş

**Files:**
- Create: `terminal/src/fisIslem.ts`, `tests/terminalFis.check.mjs`, `terminal/src/ekranlar/Fis.tsx`
- Modify: `terminal/src/stil.css` (print rules)

**Interfaces:**
- Consumes: `girisFisi`, `sureMetni`, `FisSatiri`, `FisAraclari` (`fisIcerik.ts`); `fisTahminSecenekleri`, `parcala` (`fisSecenek.ts`); `kademeAraliklari` (`src/features/finans/kademe.ts`); `formatTL`, `formatSaat`, `formatTam`, `ucretsizEtiket`, `formatPlaka`.
- Produces:
```ts
export const ARACLAR: FisAraclari
export async function fisVerisi(s: Sunucu, biletId: string): Promise<{ bilet: FisBileti; otopark: FisOtopark; secenekler: FisTahminSecenegi[]; fiyatlar: Map<number, number> }>
export async function girisFisiBas(s: Sunucu, v: { bilet: FisBileti; otopark: FisOtopark; tahmin: { dakika: number; kurus: number } | null }, simdi: () => string): Promise<FisSatiri[]>
```

- [ ] **Step 1: Failing check:**
  - `fisVerisi` reads the ticket (`biletler`, the `FisBileti` columns + `tarife_id`), the ticket's own tariff (`tarifeler?id=eq.<tarife_id>`), `otopark_ayarlari` (`ad`); options come from `fisTahminSecenekleri(tarife, {araliklar: kademeAraliklari, sure: sureMetni})`; prices from `rpc('fis_tahmini', {p_bilet_id, p_dakikalar})` in parts of 6 (`parcala`): 8 bands → 2 calls;
  - `girisFisiBas` calls `rpc('fis_basildi', {p_bilet_id, p_tur:'GIRIS', p_tahmin_dk})` FIRST and builds lines with the returned number: number 2 → the lines contain the reprint mark exactly as `tests/fis.check.mjs` expects for `basim: 2`;
  - a `fis_basildi` error rejects, and no lines are returned (nothing prints).
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** **Fis screen:** the `uyari` (if any), "Müşteri ne kadar kalacak?" as one button per option with its price (plus "Söylemedi"), then **Yazdır**: `girisFisiBas` → render the lines into `#fis-baski` → `window.print()` right after. Then **Gişe'ye dön**. Print CSS: `@media print { body > * { display:none } #fis-baski { display:block; width:58mm; font: 12px monospace } @page { size: 58mm auto; margin: 0 } }`, with line types as in `src/features/fis/FisBaski.tsx`.
- [ ] **Step 4: Run** the check, typecheck, `npm run build`, old-browser check → pass.

### Task 7: Bench and the P2 (stage 1 acceptance)

**Files:**
- Modify: `tools/cihaz-testi/p2_tezgahi.mjs` only if it needs a `--yol` for `/Otopark/terminal/` (it already takes `--chrome`).

- [ ] **Step 1: Ask the owner** before downloading Chromium 56 (size and source stated). On a yes, put it under `tools/cihaz-testi/chromium56/` (gitignored like `chromium/`).
- [ ] **Step 2: Bench run** against `npm run preview -- -c vite.terminal.config.ts` with `--chrome <chromium56> --cpu 4`, at 360 px. Expected: no console errors; Kurulum → PIN → Gişe → Giriş → Fiş all render; a screen switch < 300 ms; time to usable reported. The fiş preview's times equal Istanbul time with the bench's zone set to UTC (`src/lib/dates.ts` uses `Intl` with an explicit zone; Chrome 56 must honour it, else switch the terminal to the fixed UTC+3 helpers). Screenshots of each screen into `tools/cihaz-testi/ekranlar/terminal/` and looked at.
- [ ] **Step 3: Owner on the P2** (after deploy, which needs the owner's go to commit and push): open `…/Otopark/terminal/` in Chrome, Kurulum with a Yönetici, PIN as a Personel, Giriş with a photo, print an entry fiş. **Stage 1 is done only when the fiş is on paper.**
- [ ] **Step 4: Hand the owner the commit commands** (explicit paths, no attribution line), then update `handoff.md` and write the stage 2 plan.
