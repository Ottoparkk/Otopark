// Aşağı çekip yenileme (telefon) — çekme mesafesi ve eşik.
//
//   node tests/cekYenile.check.mjs
//
// Gerçek dosyayı içe aktarır; lib/cekYenile.ts hiçbir şey içe aktarmaz.
import { EN_COK, ESIK, cekmeMesafesi, yenilensinMi, ilerleme } from '../src/lib/cekYenile.ts'

let gecen = 0
let kalan = 0

function esit(ad, gercek, beklenen) {
  const a = JSON.stringify(gercek)
  const b = JSON.stringify(beklenen)
  if (a === b) {
    gecen += 1
  } else {
    kalan += 1
    console.error(`✗ ${ad}\n    beklenen: ${b}\n    gelen:    ${a}`)
  }
}

esit('EN_COK 96', EN_COK, 96)
esit('ESIK 64', ESIK, 64)

// ---- cekmeMesafesi: parmağın yarısı kadar, en çok EN_COK ----------------------
esit('0 → 0', cekmeMesafesi(0), 0)
esit('yukarı (eksi) → 0', cekmeMesafesi(-40), 0)
esit('bozuk → 0', cekmeMesafesi(NaN), 0)
esit('100 px parmak → 50', cekmeMesafesi(100), 50)
esit('128 px parmak → eşik 64', cekmeMesafesi(128), 64)
esit('192 px parmak → 96', cekmeMesafesi(192), 96)
esit('çok uzun çekiş → en çok 96', cekmeMesafesi(1000), 96)

// ---- yenilensinMi: eşikte ve üstünde ------------------------------------------
esit('63 → hayır', yenilensinMi(63), false)
esit('64 → evet', yenilensinMi(64), true)
esit('96 → evet', yenilensinMi(96), true)
esit('0 → hayır', yenilensinMi(0), false)
// Normal bir kaydırma hareketi (~100 px parmak) yenilemez.
esit('100 px parmak yenilemez', yenilensinMi(cekmeMesafesi(100)), false)
esit('130 px parmak yeniler', yenilensinMi(cekmeMesafesi(130)), true)

// ---- ilerleme: 0-1 ------------------------------------------------------------
esit('ilerleme 0', ilerleme(0), 0)
esit('ilerleme yarı', ilerleme(32), 0.5)
esit('ilerleme eşikte 1', ilerleme(64), 1)
esit('ilerleme eşik üstünde de 1', ilerleme(96), 1)
esit('ilerleme eksi → 0', ilerleme(-5), 0)

console.log(`\n${gecen} geçti, ${kalan} kaldı`)
if (kalan) process.exit(1)
