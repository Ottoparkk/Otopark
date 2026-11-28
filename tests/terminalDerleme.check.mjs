// P2 terminal (plan 2026-11-28, Task 1): the built terminal must run in the
// P2's Chrome 56 and stay small.
//
//   npm run build && node tests/terminalDerleme.check.mjs
//
// Chrome 56 has no ES modules, no CSS grid, no flex `gap`; ES2017 at most.
// Budget (spec): JS ≤ 100 KB gzip, CSS ≤ 15 KB gzip. And the main app's
// service worker must never answer /Otopark/terminal/ with the main app.
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs'
import { basename, join } from 'node:path'
import { gzipSync } from 'node:zlib'
import { parse } from 'acorn'

let gecen = 0
let kalan = 0
function esit(ad, gercek, beklenen) {
  const a = JSON.stringify(gercek)
  const b = JSON.stringify(beklenen)
  if (a === b) gecen += 1
  else {
    kalan += 1
    console.error(`FAIL ${ad}\n  beklenen: ${b}\n  gelen:    ${a}`)
  }
}

const KOK = new URL('../dist/terminal/', import.meta.url)
const kokYol = KOK.pathname.replace(/^\/([A-Za-z]:)/, '$1')

function dosyalar(dizin) {
  const sonuc = []
  for (const ad of readdirSync(dizin)) {
    const yol = join(dizin, ad)
    if (statSync(yol).isDirectory()) sonuc.push(...dosyalar(yol))
    else sonuc.push(yol)
  }
  return sonuc
}

const htmlVar = existsSync(join(kokYol, 'index.html'))
esit('dist/terminal/index.html var', htmlVar, true)

if (htmlVar) {
  const html = readFileSync(join(kokYol, 'index.html'), 'utf8')
  // Every script that boots the app must run without module support: either
  // a classic script, or nomodule. A type="module" script may exist only if a
  // nomodule twin does the work (plugin-legacy's pattern).
  const betikler = [...html.matchAll(/<script\b[^>]*>/g)].map((m) => m[0])
  const nomodule = betikler.filter((b) => /\bnomodule\b/.test(b))
  const klasik = betikler.filter((b) => !/type=["']module["']/.test(b))
  esit('klasik ya da nomodule betik var', nomodule.length + klasik.length > 0, true)
  esit('index.html servis çalışanı kaydetmez', /serviceWorker/.test(html), false)

  const tum = dosyalar(kokYol)
  const js = tum.filter((f) => f.endsWith('.js'))
  const css = tum.filter((f) => f.endsWith('.css'))
  esit('en az bir JS dosyası', js.length > 0, true)

  for (const f of js) {
    const kaynak = readFileSync(f, 'utf8')
    // plugin-legacy's modern-browser detection stub is inline in the HTML,
    // not here; every emitted .js must parse as an ES2017 classic script.
    let hata = null
    try {
      parse(kaynak, { ecmaVersion: 2017, sourceType: 'script' })
    } catch (e) {
      hata = `${e.message}`
    }
    esit(`ES2017 klasik betik: ${f.slice(kokYol.length)}`, hata, null)
    esit(`servis çalışanı yok: ${f.slice(kokYol.length)}`, /serviceWorker\.register/.test(kaynak), false)
  }

  const YASAK = [/display:\s*grid/, /(^|[;{\s])gap:/, /(^|[;{\s])inset:/, /aspect-ratio/, /:is\(/, /oklch\(/, /color-mix\(/, /@layer/]
  // In legacy-only mode Vite injects the CSS from inside the JS, so no .css
  // file may be emitted at all: scan the terminal's source CSS as well.
  const kaynakKok = new URL('../terminal/src/', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')
  const kaynakCss = dosyalar(kaynakKok).filter((f) => f.endsWith('.css'))
  esit('terminal kaynak CSS dosyası var', kaynakCss.length > 0, true)
  for (const f of [...css, ...kaynakCss]) {
    const kaynak = readFileSync(f, 'utf8').replace(/\/\*[\s\S]*?\*\//g, '')
    for (const y of YASAK) esit(`CSS ${y} yok: ${basename(f)}`, y.test(kaynak), false)
  }

  const gz = (liste) => liste.reduce((t, f) => t + gzipSync(readFileSync(f)).length, 0)
  const jsBoyut = gz(js)
  const cssBoyut = gz(css)
  esit(`JS ≤ 100 KB gzip (${jsBoyut})`, jsBoyut <= 102400, true)
  esit(`CSS ≤ 15 KB gzip (${cssBoyut})`, cssBoyut <= 15360, true)
}

// The main app's Workbox navigateFallback must not cover /Otopark/terminal/.
const viteAna = readFileSync(new URL('../vite.config.ts', import.meta.url), 'utf8')
esit('ana uygulama terminali yakalamaz', /navigateFallbackDenylist[^\]]*Otopark\\\/terminal\\\//.test(viteAna), true)

console.log(`${gecen} geçti, ${kalan} kaldı`)
if (kalan > 0) process.exit(1)
