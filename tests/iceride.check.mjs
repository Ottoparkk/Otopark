// Gişe → İçeride: kaç araç çizilir, kaçı düğmenin arkasında kalır.
//
//   node tests/iceride.check.mjs
//
// Sahip (2026-11-22): yavaş cihazda (P2) liste ilk 25 araçla açılır, gerisi
// "Daha fazla göster" ile. Kurallar: hiçbir araç sessizce gizlenmez (kalan ve
// içindeki uzun kalanlar sayılır), arama yazılıysa sınır yoktur.
import { ICERIDE_SAYFA, icerideGorulduMetni, icerideGorunen } from '../src/features/gise/iceride.ts'

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

// Araç n: { no: n, uzun: n numaralılar listede }
const liste = (adet, uzunlar = []) =>
  Array.from({ length: adet }, (_, i) => ({ no: i + 1, uzun: uzunlar.includes(i + 1) }))
const uzunMu = (b) => b.uzun
const ozet = (s) => ({ ilk: s.gorunen[0]?.no ?? null, son: s.gorunen.at(-1)?.no ?? null, adet: s.gorunen.length, kalan: s.kalan, kalanUzun: s.kalanUzun })

esit('sayfa 25', ICERIDE_SAYFA, 25)

// 1. Az araç: hepsi görünür
esit('10 araç', ozet(icerideGorunen(liste(10), 25, false, uzunMu)), { ilk: 1, son: 10, adet: 10, kalan: 0, kalanUzun: 0 })
esit('tam 25 araç', ozet(icerideGorunen(liste(25), 25, false, uzunMu)), { ilk: 1, son: 25, adet: 25, kalan: 0, kalanUzun: 0 })

// 2. Çok araç: ilk 25, gerisi sayılır
esit('60 araç, 25 göster', ozet(icerideGorunen(liste(60), 25, false, uzunMu)), { ilk: 1, son: 25, adet: 25, kalan: 35, kalanUzun: 0 })
esit('60 araç, 50 göster', ozet(icerideGorunen(liste(60), 50, false, uzunMu)), { ilk: 1, son: 50, adet: 50, kalan: 10, kalanUzun: 0 })
esit('adet listeden büyük', ozet(icerideGorunen(liste(30), 75, false, uzunMu)), { ilk: 1, son: 30, adet: 30, kalan: 0, kalanUzun: 0 })

// 3. Uzun kalanlar: yalnızca GİZLİ olanlar sayılır
esit('gizlide 2 uzun kalan', ozet(icerideGorunen(liste(40, [30, 40]), 25, false, uzunMu)), { ilk: 1, son: 25, adet: 25, kalan: 15, kalanUzun: 2 })
esit('görünen uzun kalan sayılmaz', ozet(icerideGorunen(liste(40, [3, 26]), 25, false, uzunMu)), { ilk: 1, son: 25, adet: 25, kalan: 15, kalanUzun: 1 })

// 4. Boş liste
esit('boş', ozet(icerideGorunen([], 25, false, uzunMu)), { ilk: null, son: null, adet: 0, kalan: 0, kalanUzun: 0 })

// 5. Arama yazılıysa sınır yok
esit('arama: 40 eşleşmenin hepsi', ozet(icerideGorunen(liste(40, [40]), 25, true, uzunMu)), { ilk: 1, son: 40, adet: 40, kalan: 0, kalanUzun: 0 })

// 6. Liste değiştirilmez (React state'i)
const l = liste(30)
icerideGorunen(l, 25, false, uzunMu)
esit('girdi değişmez', l.length, 30)

// 077 H: köprü açık biletli aracı otoparkın içinde gördüyse satır o saati
// söyler (saat biçimi dışarıdan: uygulamada İstanbul saati, formatSaat).
const saat = (iso) => `[${iso}]`
esit('içeride görüldü: saat var',
  icerideGorulduMetni({ iceride_goruldu_at: '2026-11-25T07:35:00Z' }, saat),
  'İçeride görüldü [2026-11-25T07:35:00Z]')
esit('içeride görüldü: yok', icerideGorulduMetni({ iceride_goruldu_at: null }, saat), null)
esit('içeride görüldü: 077 öncesi alan hiç yok', icerideGorulduMetni({}, saat), null)

console.log(`${gecen} geçti, ${kalan} kaldı`)
if (kalan > 0) process.exit(1)
