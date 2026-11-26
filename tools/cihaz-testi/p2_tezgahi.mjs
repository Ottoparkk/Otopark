// P2 test bench: runs the built app in Chrome as if it were on the Paycell
// Sunmi P2 (Android 7.1.1, 1 GB RAM, Cortex-A53 1.5 GHz, 720x1440 screen)
// and measures what a Personel would feel: how long each screen takes to be
// usable, how much memory it holds, and whether any script error appears.
//
// Zero dependencies: Node 22+ (global WebSocket) talks to Chrome over the
// DevTools protocol. Read-only: it opens screens, it never types a plate or
// taps a button, so it writes nothing to the database.
//
// What it can and cannot imitate:
//   - Chrome version: real, if you point --chrome at a Chromium 119 build
//     (the last Chrome for Android 7). With the installed Chrome it is not.
//   - CPU: DevTools CPU throttling (--cpu, default 4x). 4x is what Lighthouse
//     uses for a Moto G4, which has the same Cortex-A53 1.5 GHz class CPU.
//     It is an approximation that depends on how fast this PC is.
//   - Network: "slow 4G" (150 ms, 1.6 Mbit/s down, 750 kbit/s up).
//   - RAM: NOT limited. Chrome runs in its low-end-device mode (what Android
//     switches on for <= 1 GB phones) and the bench reports the JS heap so
//     it can be compared with a budget.
//
// Usage:  node tools/cihaz-testi/p2_tezgahi.mjs [options]   (see README.md)

import { spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { createServer } from 'node:http'
import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, extname, join, normalize, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const BURASI = dirname(fileURLToPath(import.meta.url))
const DEPO = resolve(BURASI, '..', '..')

// ---------------------------------------------------------------- options
const arg = (ad, varsayilan) => {
  const i = process.argv.indexOf(`--${ad}`)
  return i >= 0 ? process.argv[i + 1] : varsayilan
}
const bayrak = (ad) => process.argv.includes(`--${ad}`)

const SECENEK = {
  chrome: arg('chrome', 'C:/Program Files/Google/Chrome/Application/chrome.exe'),
  dist: resolve(arg('dist', join(DEPO, 'dist'))),
  // Build the app with source maps into tools/cihaz-testi/derleme first, so
  // the profile names source files instead of minified chunks.
  derle: bayrak('derle'),
  url: arg('url', null), // e.g. the deployed site; skips the local server
  cpu: Number(arg('cpu', '4')),
  elleGiris: bayrak('elle-giris'), // open a window and wait for a sign-in
  sessiz: bayrak('sessiz'), // do not open Notepad
  rapor: resolve(arg('rapor', join(BURASI, 'p2-sonuc.txt'))),
  // Folder for PNGs of every screen at 360 / 375 / 430 px, light and dark.
  ekran: arg('ekran-goruntusu', null),
}

const BASE = '/Otopark/'
const AG = { latency: 150, downloadThroughput: (1.6e6 / 8) | 0, uploadThroughput: (750e3 / 8) | 0 }

// Budgets are my estimates for a 1 GB Android 7 device, not measured on one.
const SURE_IYI = 3000
const SURE_KABUL = 6000
const HEAP_IYI = 60
const HEAP_KABUL = 100

// ---------------------------------------------------------- static server
const TUR = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.mjs': 'text/javascript',
  '.css': 'text/css', '.json': 'application/json', '.webmanifest': 'application/manifest+json',
  '.png': 'image/png', '.svg': 'image/svg+xml', '.woff2': 'font/woff2', '.ico': 'image/x-icon',
  '.txt': 'text/plain',
}

function sunucuAc(kok) {
  return new Promise((ok) => {
    const s = createServer((req, res) => {
      const yol = decodeURIComponent(new URL(req.url, 'http://x').pathname)
      if (yol === '/__tezgah/parcalar') {
        const dosyalar = readdirSync(join(kok, 'assets')).filter((d) => d.endsWith('.js'))
        res.writeHead(200, { 'content-type': 'application/json' })
        return res.end(JSON.stringify(dosyalar.map((d) => `${BASE}assets/${d}`)))
      }
      if (!yol.startsWith(BASE)) {
        res.writeHead(302, { location: BASE })
        return res.end()
      }
      let dosya = normalize(join(kok, yol.slice(BASE.length)))
      if (!dosya.startsWith(kok)) {
        res.writeHead(403)
        return res.end()
      }
      // SPA: an unknown path is a route, served the shell.
      if (!existsSync(dosya) || statSync(dosya).isDirectory()) dosya = join(kok, 'index.html')
      res.writeHead(200, { 'content-type': TUR[extname(dosya)] ?? 'application/octet-stream' })
      res.end(readFileSync(dosya))
    })
    // A fixed port: the sign-in lives in localStorage, which belongs to one
    // origin (host AND port). A random port lost it on every run.
    s.listen(Number(arg('port', '4317')), '127.0.0.1', () => ok(s))
  })
}

// --------------------------------------------------------------- chrome
const bekle = (ms) => new Promise((r) => setTimeout(r, ms))

async function chromeAc() {
  // One profile per Chrome build: a profile written by Chrome 157 must not be
  // opened by Chromium 119 (it refuses newer profiles). The profile keeps the
  // sign-in, so --elle-giris is needed once per build.
  const iz = createHash('md5').update(SECENEK.chrome).digest('hex').slice(0, 8)
  const profil = join(tmpdir(), `otopark-p2-profil-${iz}`)
  const portDosyasi = join(profil, 'DevToolsActivePort')
  if (existsSync(portDosyasi)) writeFileSync(portDosyasi, '') // stale from a crash
  const args = [
    `--user-data-dir=${profil}`,
    '--remote-debugging-port=0',
    '--no-first-run',
    '--no-default-browser-check',
    '--enable-low-end-device-mode',
    '--window-size=420,860',
    ...(SECENEK.elleGiris ? [] : ['--headless=new']),
    'about:blank',
  ]
  const surec = spawn(SECENEK.chrome, args, { stdio: 'ignore' })
  for (let i = 0; i < 100; i++) {
    await bekle(100)
    const metin = existsSync(portDosyasi) ? readFileSync(portDosyasi, 'utf8') : ''
    const port = Number(metin.split('\n')[0])
    if (port) return { surec, port, profil }
  }
  surec.kill()
  throw new Error(`Chrome açılmadı: ${SECENEK.chrome}`)
}

class Cdp {
  constructor(ws) {
    this.ws = ws
    this.no = 0
    this.bekleyen = new Map()
    this.dinleyici = new Map()
    ws.addEventListener('message', (e) => {
      const m = JSON.parse(e.data)
      if (m.id && this.bekleyen.has(m.id)) {
        const { ok, hata } = this.bekleyen.get(m.id)
        this.bekleyen.delete(m.id)
        m.error ? hata(new Error(`${m.error.message}`)) : ok(m.result)
      } else if (m.method) {
        for (const f of this.dinleyici.get(m.method) ?? []) f(m.params)
      }
    })
  }
  static async bagla(url) {
    const ws = new WebSocket(url)
    await new Promise((ok, hata) => {
      ws.addEventListener('open', ok, { once: true })
      ws.addEventListener('error', hata, { once: true })
    })
    return new Cdp(ws)
  }
  gonder(method, params = {}) {
    const id = ++this.no
    this.ws.send(JSON.stringify({ id, method, params }))
    return new Promise((ok, hata) => this.bekleyen.set(id, { ok, hata }))
  }
  on(method, f) {
    if (!this.dinleyici.has(method)) this.dinleyici.set(method, [])
    this.dinleyici.get(method).push(f)
  }
  async degerlendir(ifade) {
    const r = await this.gonder('Runtime.evaluate', {
      expression: ifade, awaitPromise: true, returnByValue: true,
    })
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description ?? 'evaluate')
    return r.result.value
  }
}

// Recorded from the first byte of every document: paint timings and long
// tasks (main-thread work over 50 ms, which is what makes taps feel stuck).
const SAYFA_OLCER = `
  window.__tezgah = { lcp: 0, uzun: 0, uzunSay: 0 };
  try {
    new PerformanceObserver((l) => { for (const e of l.getEntries()) window.__tezgah.lcp = e.startTime })
      .observe({ type: 'largest-contentful-paint', buffered: true });
    new PerformanceObserver((l) => { for (const e of l.getEntries()) {
      window.__tezgah.uzun += e.duration - 50; window.__tezgah.uzunSay++ } })
      .observe({ type: 'longtask', buffered: true });
  } catch (e) {}
`

// "Usable": the app shell rendered, no spinner showing, no request in flight
// for a while. A screen that is still fetching is not usable yet.
const HAZIR_MI = `(() => {
  const kok = document.getElementById('root');
  if (!kok || kok.children.length === 0) return false;
  if (document.querySelector('[role=status] .animate-spin')) return false;
  return true;
})()`

// ------------------------------------------------------------ measuring
async function hazirlik(cdp, ekranAdresi) {
  await cdp.gonder('Page.enable')
  await cdp.gonder('Runtime.enable')
  await cdp.gonder('Log.enable')
  await cdp.gonder('Network.enable')
  await cdp.gonder('Performance.enable')
  const surum = (await cdp.gonder('Browser.getVersion')).product // "Chrome/119.0..."
  const ana = surum.split('/')[1].split('.')[0]
  await cdp.gonder('Network.setUserAgentOverride', {
    userAgent: `Mozilla/5.0 (Linux; Android 7.1.1; P2) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${ana}.0.0.0 Mobile Safari/537.36`,
    platform: 'Android',
  })
  await cdp.gonder('Emulation.setDeviceMetricsOverride', {
    width: 360, height: 720, deviceScaleFactor: 2, mobile: true,
  })
  await cdp.gonder('Emulation.setTouchEmulationEnabled', { enabled: true, maxTouchPoints: 5 })
  await cdp.gonder('Emulation.setCPUThrottlingRate', { rate: SECENEK.cpu })
  await cdp.gonder('Network.emulateNetworkConditions', { offline: false, ...AG })
  await cdp.gonder('Page.addScriptToEvaluateOnNewDocument', { source: SAYFA_OLCER })

  const hatalar = []
  cdp.on('Runtime.exceptionThrown', (p) =>
    hatalar.push(p.exceptionDetails.exception?.description?.split('\n')[0] ?? p.exceptionDetails.text))
  cdp.on('Log.entryAdded', (p) => {
    // Network failures of the app's own Supabase calls show here too; keep
    // them, they matter on a slow line.
    if (p.entry.level === 'error') hatalar.push(`${p.entry.source}: ${p.entry.text}`.slice(0, 200))
  })

  const ag = { ucusta: new Set(), sonHareket: Date.now(), bayt: 0, istek: 0 }
  cdp.on('Network.requestWillBeSent', (p) => {
    ag.ucusta.add(p.requestId); ag.sonHareket = Date.now(); ag.istek++
  })
  const bitti = (p) => { ag.ucusta.delete(p.requestId); ag.sonHareket = Date.now() }
  cdp.on('Network.loadingFinished', (p) => { ag.bayt += p.encodedDataLength; bitti(p) })
  cdp.on('Network.loadingFailed', bitti)

  return { surum, hatalar, ag, ekranAdresi }
}

// Waits for "usable": the screen drawn without a spinner and no request in
// flight, confirmed by 500 ms of quiet. Returns ms since t0, or null.
async function sakinlesBekle(cdp, ag, t0) {
  let ekranTamamSince = null
  while (Date.now() - t0 < 60000) {
    const ok = await cdp.degerlendir(HAZIR_MI).catch(() => false)
    ekranTamamSince = ok ? (ekranTamamSince ?? Date.now()) : null
    if (ok && ag.ucusta.size === 0 && Date.now() - ag.sonHareket > 500) {
      return Math.max(ekranTamamSince, ag.sonHareket) - t0
    }
    await bekle(100)
  }
  return null
}

const PLAKA_ALANI = 'input[placeholder="34ABC123"], input[placeholder*="laka" i], input[aria-label*="laka" i]'

const metrikAl = async (cdp) =>
  Object.fromEntries((await cdp.gonder('Performance.getMetrics')).metrics.map((m) => [m.name, m.value]))

async function olc(cdp, ortam, ad, yol, { soguk = false, yaz = null } = {}) {
  const { hatalar, ag } = ortam
  const hataBasi = hatalar.length
  const metrikOnce = await metrikAl(cdp)
  await cdp.gonder('Profiler.enable')
  await cdp.gonder('Profiler.setSamplingInterval', { interval: 200 })
  await cdp.gonder('Profiler.start')
  if (soguk) {
    const origin = new URL(ortam.ekranAdresi).origin
    await cdp.gonder('Storage.clearDataForOrigin', { origin, storageTypes: 'cache_storage,service_workers' })
    await cdp.gonder('Network.clearBrowserCache')
  }
  await cdp.gonder('Network.setCacheDisabled', { cacheDisabled: soguk })
  ag.bayt = 0
  ag.istek = 0
  ag.ucusta.clear()

  const yuklendi = new Promise((ok) => cdp.on('Page.loadEventFired', ok))
  const t0 = Date.now()
  await cdp.gonder('Page.navigate', { url: new URL(yol, ortam.ekranAdresi).href })
  await Promise.race([yuklendi, bekle(60000)])

  const hazir = await sakinlesBekle(cdp, ag, t0)
  const sayfa = await cdp.degerlendir(`(() => {
    const fcp = performance.getEntriesByName('first-contentful-paint')[0];
    return { fcp: fcp ? fcp.startTime : null, lcp: __tezgah.lcp, uzun: __tezgah.uzun,
             uzunSay: __tezgah.uzunSay, adres: location.pathname };
  })()`).catch(() => ({}))

  // Typing into the plate field, one letter at a time like a person. Never
  // presses Enter: on Giriş, Enter would open a ticket.
  let yazma = null
  if (yaz && hazir != null) {
    const odak = await cdp.degerlendir(`(() => { const a = document.querySelector(${JSON.stringify(PLAKA_ALANI)});
      if (!a) return false; a.focus(); __tezgah.uzun = 0; __tezgah.uzunSay = 0; return document.activeElement === a })()`)
    if (odak) {
      const t1 = Date.now()
      for (const harf of yaz) {
        await cdp.gonder('Input.insertText', { text: harf })
        await bekle(150) // a quick typist
      }
      const sure = await sakinlesBekle(cdp, ag, t1)
      const u = await cdp.degerlendir('({ uzun: __tezgah.uzun, uzunSay: __tezgah.uzunSay })')
      // Time beyond the typist's own pauses is lag the operator feels.
      yazma = { harf: yaz.length, gecikme: sure == null ? null : Math.max(0, sure - yaz.length * 150), ...u }
    } else {
      yazma = { harf: 0 }
    }
  }

  const metrik = await metrikAl(cdp)
  const { profile } = await cdp.gonder('Profiler.stop')
  await cdp.gonder('Network.setCacheDisabled', { cacheDisabled: false })
  // The counters belong to the renderer process and keep growing across
  // pages — unless Chrome moved the page to a new process, which starts them
  // at zero again (that showed up as negative times). So: the difference, or
  // the value itself when the counter went backwards.
  const yeniSurec = (metrik.TaskDuration ?? 0) < (metrikOnce.TaskDuration ?? 0)
  const fark = (k) => ((metrik[k] ?? 0) - (yeniSurec ? 0 : (metrikOnce[k] ?? 0))) * 1000
  return {
    ad, yol, adres: sayfa.adres, hazir, fcp: sayfa.fcp, lcp: sayfa.lcp || null,
    uzun: sayfa.uzun, uzunSay: sayfa.uzunSay, yazma,
    is: { toplam: fark('TaskDuration'), kod: fark('ScriptDuration'), yerlesim: fark('LayoutDuration'), stil: fark('RecalcStyleDuration') },
    sicak: await profilOzeti(profile, ortam),
    heapMb: metrik.JSHeapUsedSize / 1048576, dugum: metrik.Nodes,
    kb: ag.bayt / 1024, istek: ag.istek,
    hatalar: hatalar.slice(hataBasi),
  }
}

// ------------------------------------------------- profile + source maps
// The bundle is minified, so a profile names functions like "Xe" in
// "primitives-DrZ4.js". With the build's .map files (vite build --sourcemap)
// each sample is traced back to the source file and line, e.g.
// "src/features/gise/Cikis.tsx:312". Without maps, the chunk name is shown.
const B64 = Object.fromEntries([...'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'].map((c, i) => [c, i]))

function vlqCoz(parca) {
  const out = []
  let deger = 0
  let kay = 0
  for (const c of parca) {
    const d = B64[c]
    deger += (d & 31) << kay
    if (d & 32) {
      kay += 5
    } else {
      out.push(deger & 1 ? -(deger >> 1) : deger >> 1)
      deger = 0
      kay = 0
    }
  }
  return out
}

function haritaYukle(dosya) {
  if (!existsSync(dosya)) return null
  const h = JSON.parse(readFileSync(dosya, 'utf8'))
  const satirlar = []
  let kaynak = 0
  let kSatir = 0
  let kSutun = 0
  let isim = 0
  for (const satir of h.mappings.split(';')) {
    const parcalar = []
    let sutun = 0
    for (const p of satir.split(',')) {
      if (!p) continue
      const v = vlqCoz(p)
      sutun += v[0]
      if (v.length >= 4) {
        kaynak += v[1]
        kSatir += v[2]
        kSutun += v[3]
        if (v.length >= 5) isim += v[4]
        parcalar.push([sutun, kaynak, kSatir, v.length >= 5 ? isim : -1])
      }
    }
    satirlar.push(parcalar)
  }
  return { satirlar, kaynaklar: h.sources, isimler: h.names ?? [] }
}

function haritadaBul(harita, satir, sutun) {
  // A position before the first mapping on its line belongs to the last
  // mapping of an earlier line.
  let p = harita.satirlar[satir]
  while (satir > 0 && (!p || p.length === 0 || p[0][0] > sutun)) {
    satir--
    p = harita.satirlar[satir]
    sutun = Infinity
  }
  if (!p || p.length === 0) return null
  let lo = 0
  let hi = p.length - 1
  let bulunan = -1
  while (lo <= hi) {
    const m = (lo + hi) >> 1
    if (p[m][0] <= sutun) {
      bulunan = m
      lo = m + 1
    } else {
      hi = m - 1
    }
  }
  if (bulunan < 0) return null
  const [, k, s, i] = p[bulunan]
  return { kaynak: harita.kaynaklar[k], satir: s + 1, isim: i >= 0 ? harita.isimler[i] : null }
}

// "../../node_modules/.pnpm/x/node_modules/react-dom/cjs/a.js" -> "react-dom"
// "../../src/features/gise/Cikis.tsx" -> "src/features/gise/Cikis.tsx"
function kaynakAdi(yol) {
  const nm = yol.lastIndexOf('node_modules/')
  if (nm >= 0) {
    const geri = yol.slice(nm + 'node_modules/'.length).split('/')
    return geri[0].startsWith('@') ? `${geri[0]}/${geri[1]}` : geri[0]
  }
  const src = yol.indexOf('src/')
  return src >= 0 ? yol.slice(src) : yol
}

async function profilOzeti(profile, ortam) {
  const haritalar = ortam.haritalar ?? (ortam.haritalar = new Map())
  const harita = (url) => {
    let yol
    try {
      yol = new URL(url).pathname
    } catch {
      return null
    }
    if (!SECENEK.distKok || !yol.startsWith(BASE)) return null
    const dosya = join(SECENEK.distKok, yol.slice(BASE.length)) + '.map'
    if (!haritalar.has(dosya)) haritalar.set(dosya, haritaYukle(dosya))
    return haritalar.get(dosya)
  }

  const dugumler = new Map(profile.nodes.map((n) => [n.id, n]))
  const oz = new Map()
  for (let i = 0; i < profile.samples.length; i++) {
    const id = profile.samples[i]
    oz.set(id, (oz.get(id) ?? 0) + (profile.timeDeltas[i] ?? 0))
  }

  const isler = new Map() // "file:line name" -> µs
  const dosyalar = new Map() // file or package -> µs
  let toplam = 0
  for (const [id, us] of oz) {
    const cf = dugumler.get(id).callFrame
    if (cf.functionName === '(idle)' || cf.functionName === '(program)') continue
    toplam += us
    let dosya
    let anahtar
    if (cf.functionName === '(garbage collector)') {
      dosya = anahtar = '(bellek temizliği / GC)'
    } else if (!cf.url) {
      dosya = '(tarayıcının kendi işi)'
      anahtar = `${dosya} ${cf.functionName || ''}`.trim()
    } else {
      const h = harita(cf.url)
      const yer = h ? haritadaBul(h, cf.lineNumber, cf.columnNumber) : null
      if (yer) {
        dosya = kaynakAdi(yer.kaynak)
        anahtar = `${dosya}:${yer.satir} ${yer.isim ?? cf.functionName ?? ''}`.trim()
      } else {
        dosya = cf.url.split('/').pop()
        anahtar = `${dosya} ${cf.functionName || '(modül açılışı / eşlenemedi)'}`
      }
    }
    isler.set(anahtar, (isler.get(anahtar) ?? 0) + us)
    dosyalar.set(dosya, (dosyalar.get(dosya) ?? 0) + us)
  }
  const sirala = (m, n) => [...m].sort((a, b) => b[1] - a[1]).slice(0, n).map(([k, us]) => ({ ad: k, ms: us / 1000 }))
  return { toplamMs: toplam / 1000, dosyalar: sirala(dosyalar, 6), isler: sirala(isler, 8) }
}

// Every chunk of the build is imported once: a syntax or start-up error in
// ANY screen (also Yönetici screens Personel never opens) shows up here, on
// the Chrome actually running, without signing in.
async function parcaKontrolu(cdp) {
  return cdp.degerlendir(`(async () => {
    const liste = await (await fetch('/__tezgah/parcalar')).json();
    const hata = [];
    for (const u of liste) { try { await import(u) } catch (e) { hata.push(u.split('/').pop() + ': ' + e) } }
    return { toplam: liste.length, hata };
  })()`)
}

// Waits until the app's service worker has cached the shell, so the "warm"
// run measures what a Personel sees on the second day, not the first.
async function onbellekBekle(cdp) {
  for (let i = 0; i < 120; i++) {
    const n = await cdp.degerlendir(`(async () => {
      if (!('serviceWorker' in navigator) || !navigator.serviceWorker.controller) {
        const r = await navigator.serviceWorker?.getRegistration(); if (!r?.active) return 0 }
      let n = 0; for (const k of await caches.keys()) n += (await (await caches.open(k)).keys()).length;
      return n })()`).catch(() => 0)
    if (n >= 40) return n
    await bekle(1000)
  }
  return 0
}

// The visual check CLAUDE.md asks for: each screen at 360 / 375 / 430 px, in
// light and dark. The theme is switched by the same `dark` class the app's own
// toggle sets (src/lib/theme.ts) — on the page only, nothing is saved. Also
// reports horizontal scroll, which must never happen at 360 px.
// Rows below the fold use content-visibility, so in a full-page picture they
// can show as blank space; the screen as an operator scrolls it is unaffected.
async function ekranlariKaydet(cdp, ad) {
  const klasor = resolve(SECENEK.ekran)
  mkdirSync(klasor, { recursive: true })
  const tr = { ç: 'c', ğ: 'g', ı: 'i', ö: 'o', ş: 's', ü: 'u', İ: 'i', Ç: 'c', Ğ: 'g', Ö: 'o', Ş: 's', Ü: 'u' }
  const temiz = ad.replace(/[çğıöşüİÇĞÖŞÜ]/g, (h) => tr[h]).replace(/[^a-z0-9]+/gi, '-').replace(/^-|-$/g, '').toLowerCase()
  const koyuBasta = await cdp.degerlendir(`document.documentElement.classList.contains('dark')`)
  const kaydirma = []
  for (const en of [360, 375, 430]) {
    await cdp.gonder('Emulation.setDeviceMetricsOverride', { width: en, height: 720, deviceScaleFactor: 2, mobile: true })
    for (const koyu of [false, true]) {
      await cdp.degerlendir(`document.documentElement.classList.toggle('dark', ${koyu})`)
      await bekle(300)
      const olcu = await cdp.degerlendir(`({ yukseklik: Math.min(document.documentElement.scrollHeight, 5000),
        tasma: document.documentElement.scrollWidth - document.documentElement.clientWidth })`)
      if (olcu.tasma > 0) kaydirma.push(`${en} px${koyu ? ' koyu' : ''}: ${olcu.tasma} px taşıyor`)
      const { data } = await cdp.gonder('Page.captureScreenshot', {
        format: 'png',
        captureBeyondViewport: true,
        clip: { x: 0, y: 0, width: en, height: olcu.yukseklik, scale: 0.5 },
      })
      writeFileSync(join(klasor, `${temiz}-${en}-${koyu ? 'koyu' : 'acik'}.png`), Buffer.from(data, 'base64'))
    }
  }
  await cdp.degerlendir(`document.documentElement.classList.toggle('dark', ${koyuBasta})`)
  await cdp.gonder('Emulation.setDeviceMetricsOverride', { width: 360, height: 720, deviceScaleFactor: 2, mobile: true })
  return kaydirma
}

async function girisBekle(cdp) {
  console.log('\nAçılan Chrome penceresinde bir PERSONEL hesabıyla giriş yapın. (5 dk bekliyorum)')
  for (let i = 0; i < 300; i++) {
    const yol = await cdp.degerlendir('location.pathname').catch(() => '')
    if (yol && !/\/(giris|kayit|sifre-sifirla)$/.test(yol)) return true
    await bekle(1000)
  }
  return false
}

// ---------------------------------------------------------------- report
const sn = (ms) => (ms == null ? '—' : ms < 1000 ? `${Math.round(ms)} ms` : `${(ms / 1000).toFixed(1)} sn`)
const notSure = (ms) => (ms == null ? 'AÇILMADI' : ms <= SURE_IYI ? 'iyi' : ms <= SURE_KABUL ? 'kabul edilir' : 'YAVAŞ')
const notHeap = (mb) => (mb <= HEAP_IYI ? 'iyi' : mb <= HEAP_KABUL ? 'kabul edilir' : 'RİSKLİ')

function rapor(ortam, olcumler, parca, girisli) {
  const s = []
  s.push('OTOPARK — P2 TEST TEZGAHI SONUCU')
  s.push(`Tarih: ${new Date().toLocaleString('tr-TR', { timeZone: 'Europe/Istanbul' })}`)
  s.push(`Tarayıcı: ${ortam.surum}${/Chrome\/119\./.test(ortam.surum) ? '  (P2 ile aynı sürüm)' : '  (P2\'de en çok Chrome 119 var — bu sürüm farklı)'}`)
  s.push(`Taklit: 360x720 ekran, CPU ${SECENEK.cpu}x yavaş, yavaş 4G, Chrome düşük-RAM modu`)
  s.push(`Uygulama: ${ortam.ekranAdresi}`)
  s.push('')
  for (const o of olcumler) {
    s.push(`■ ${o.ad}  (${o.adres ?? o.yol})`)
    s.push(`   Kullanılabilir: ${sn(o.hazir)}  → ${notSure(o.hazir)}`)
    s.push(`   İlk görüntü: ${sn(o.fcp)}   En büyük öğe: ${sn(o.lcp)}`)
    s.push(`   Takılma (50 ms üstü işler): ${o.uzunSay ?? 0} kez, toplam ${sn(o.uzun)}`)
    if (o.yazma) {
      s.push(o.yazma.harf === 0
        ? '   Yazma: plaka alanı bulunamadı'
        : `   Yazma (${o.yazma.harf} harf): yazmanın üstüne ${sn(o.yazma.gecikme)} gecikme, takılma ${o.yazma.uzunSay} kez (${sn(o.yazma.uzun)})`)
    }
    s.push(`   Ana iş: ${sn(o.is.toplam)} (kod ${sn(o.is.kod)}, yerleşim ${sn(o.is.yerlesim)}, stil ${sn(o.is.stil)})`)
    if (o.sicak.toplamMs > 0) {
      s.push(`   En çok zaman alan (profil, toplam ${sn(o.sicak.toplamMs)}):`)
      for (const d of o.sicak.dosyalar) s.push(`     ${sn(d.ms).padStart(7)}  ${d.ad}`)
      s.push('   En pahalı yerler:')
      for (const d of o.sicak.isler) s.push(`     ${sn(d.ms).padStart(7)}  ${d.ad}`)
    }
    s.push(`   Bellek (JS): ${o.heapMb.toFixed(0)} MB → ${notHeap(o.heapMb)}   DOM: ${o.dugum}`)
    s.push(`   İndirilen: ${o.kb.toFixed(0)} KB, ${o.istek} istek`)
    if (o.kaydirma) s.push(`   Yatay kaydırma (360/375/430, açık/koyu): ${o.kaydirma.length === 0 ? 'yok' : o.kaydirma.join('; ')}`)
    s.push(`   Hata: ${o.hatalar.length === 0 ? 'yok' : ''}`)
    for (const h of o.hatalar.slice(0, 5)) s.push(`     - ${h}`)
    s.push('')
  }
  if (parca) {
    s.push(`■ Kod parçaları bu Chrome'da çalışıyor mu: ${parca.toplam - parca.hata.length}/${parca.toplam}`)
    for (const h of parca.hata) s.push(`     - ${h}`)
    s.push('')
  }
  if (!girisli) {
    s.push('Not: giriş yapılmadığı için yalnızca Giriş ekranı ölçüldü. Personel ekranları için:')
    s.push('     node tools/cihaz-testi/p2_tezgahi.mjs --elle-giris')
    s.push('')
  }
  s.push(`Sınırlar (tahminim, cihazda ölçülmedi): kullanılabilir ≤${SURE_IYI / 1000} sn iyi, ≤${SURE_KABUL / 1000} sn kabul;`)
  s.push(`bellek ≤${HEAP_IYI} MB iyi, ≤${HEAP_KABUL} MB kabul. RAM'in kendisi sınırlanamaz; gerçek cihazda`)
  s.push('başka uygulamalar açıkken Chrome sekmeyi yeniden yükleyebilir.')
  return s.join('\n')
}

// ------------------------------------------------------------------ main
async function main() {
  let sunucu = null
  let ekranAdresi = SECENEK.url
  if (SECENEK.derle && !ekranAdresi) {
    SECENEK.dist = join(BURASI, 'derleme')
    console.log('Uygulama kaynak haritalarıyla derleniyor…')
    const kod = await new Promise((ok) =>
      spawn('npx', ['vite', 'build', '--sourcemap', '--emptyOutDir', '--outDir', `"${SECENEK.dist}"`], {
        cwd: DEPO, shell: true, stdio: 'inherit',
      }).on('exit', ok))
    if (kod !== 0) {
      console.error('Derleme başarısız.')
      process.exit(2)
    }
  }
  if (!ekranAdresi) {
    SECENEK.distKok = SECENEK.dist
    if (!existsSync(join(SECENEK.dist, 'index.html'))) {
      console.error(`Derleme yok: ${SECENEK.dist}\nÖnce: npm run build  (ya da --dist <klasör>)`)
      process.exit(2)
    }
    sunucu = await sunucuAc(SECENEK.dist)
    ekranAdresi = `http://127.0.0.1:${sunucu.address().port}${BASE}`
  }

  const { surec, port } = await chromeAc()
  try {
    const liste = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()
    const sayfa = liste.find((t) => t.type === 'page')
    const cdp = await Cdp.bagla(sayfa.webSocketDebuggerUrl)
    const ortam = await hazirlik(cdp, ekranAdresi)
    console.log(`Tarayıcı: ${ortam.surum}   Uygulama: ${ekranAdresi}`)

    // Each screen is measured first, then (with --ekran-goruntusu) pictured.
    const olcVeCek = async (ad, yol, secenek) => {
      const o = await olc(cdp, ortam, ad, yol, secenek)
      if (SECENEK.ekran) o.kaydirma = await ekranlariKaydet(cdp, ad)
      return o
    }
    const olcumler = []
    olcumler.push(await olcVeCek('İlk açılış (önbellek boş)', BASE, { soguk: true }))
    let girisli = !/\/giris$/.test(olcumler[0].adres ?? '')
    if (!girisli && SECENEK.elleGiris) girisli = await girisBekle(cdp)

    console.log('Uygulamanın kendini önbelleğe alması bekleniyor…')
    await onbellekBekle(cdp)

    if (girisli) {
      olcumler.push(await olcVeCek('Tekrar açılış (önbellekli)', BASE))
      olcumler.push(await olcVeCek('Gişe — Giriş (plaka yazılır, kaydedilmez)', `${BASE}gise/giris`, { yaz: '34ABC123' }))
      olcumler.push(await olcVeCek('Gişe — Çıkış / İçeride (arama yazılır)', `${BASE}gise/cikis`, { yaz: '34' }))
      olcumler.push(await olcVeCek('Vardiya', `${BASE}vardiya`))
    } else {
      olcumler.push(await olcVeCek('Tekrar açılış (önbellekli)', `${BASE}giris`))
    }
    const parca = sunucu ? await parcaKontrolu(cdp).catch((e) => ({ toplam: 0, hata: [String(e)] })) : null

    const metin = rapor(ortam, olcumler, parca, girisli)
    writeFileSync(SECENEK.rapor, '\ufeff' + metin.replace(/\n/g, '\r\n'), 'utf8')
    console.log('\n' + metin + `\n\nRapor: ${SECENEK.rapor}`)
    if (!SECENEK.sessiz) spawn('notepad.exe', [SECENEK.rapor], { detached: true, stdio: 'ignore' }).unref()
    cdp.ws.close()
  } finally {
    surec.kill()
    sunucu?.close()
  }
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
