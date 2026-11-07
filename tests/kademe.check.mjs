// Kademeli tarife (051) — Tarife penceresinin kademe satırları, doğrulaması
// ve ücret önizlemesi.
//
//   node tests/kademe.check.mjs
//
// Gerçek dosyaları içe aktarır. kademe.ts çalışma zamanında hiçbir şey içe
// aktarmaz; para yardımcıları ona parametre olarak verilir — burada da
// GERÇEKLERİ veriliyor. Ücret beklentileri smoke test PASS 73 ile BİREBİR
// aynıdır: ekrandaki önizleme ile kasadaki fiyat ayrışamaz.
import { parseTLToKurus, kurusToInput } from '../src/lib/money.ts'
import {
  KADEME_EN_COK,
  kademeBaslangic,
  kademeHatasi,
  kademeListesi,
  kademeUcret,
  kademeAraliklari,
} from '../src/features/finans/kademe.ts'

let gecen = 0
let kalan = 0

function esit(ad, gercek, beklenen) {
  const a = JSON.stringify(gercek)
  const b = JSON.stringify(beklenen)
  if (a === b) {
    gecen += 1
  } else {
    kalan += 1
    console.error(`FAIL ${ad}\n  beklenen: ${b}\n  gelen:    ${a}`)
  }
}

const ARACLAR = { parseTLToKurus, kurusToInput }

// Sahibin listesi: 0–2 sa 200, 2–4 sa 300, 4–8 sa 400, 8–24 sa 500.
const SAHIP = [
  { dakika: 120, kurus: 20000 },
  { dakika: 240, kurus: 30000 },
  { dakika: 480, kurus: 40000 },
  { dakika: 1440, kurus: 50000 },
]
const SAHIP_SATIR = [
  { saat: '2', tutar: '200' },
  { saat: '4', tutar: '300' },
  { saat: '8', tutar: '400' },
  { saat: '24', tutar: '500' },
]

// ---- 1. Ücret — PASS 73(a) ile aynı örnekler (ücretsiz süre 5 dk) ----------
for (const [dk, kr] of [
  [0, 0], [5, 0], [6, 20000], [120, 20000], [121, 30000], [240, 30000],
  [241, 40000], [480, 40000], [481, 50000], [1440, 50000], [1441, 70000],
  [1800, 90000], [2880, 100000], [2881, 120000],
]) {
  esit(`ücret: ${dk} dk`, kademeUcret(dk, 5, SAHIP), kr)
}
esit('ücret: ücretsiz süre 0 → ilk dakika ücretli', kademeUcret(1, 0, SAHIP), 20000)
esit('ücret: tek kademe (yalnız 24 sa) → gün fiyatı', kademeUcret(30, 0, [{ dakika: 1440, kurus: 50000 }]), 50000)

// ---- 2. Satırlar ↔ liste ----------------------------------------------------
esit('liste: sahibin satırları', kademeListesi(SAHIP_SATIR, ARACLAR), SAHIP)
esit('başlangıç: kayıtlı listeden satırlar', kademeBaslangic(SAHIP, ARACLAR), SAHIP_SATIR)
esit('başlangıç: liste yok → tek 24 saat satırı', kademeBaslangic(null, ARACLAR), [{ saat: '24', tutar: '' }])
esit(
  'başlangıç: kuruşlu tutar gruplanmaz',
  kademeBaslangic([{ dakika: 1440, kurus: 123450 }], ARACLAR),
  [{ saat: '24', tutar: '1234,50' }],
)
esit(
  'liste: boşluklar ve kuruş',
  kademeListesi([{ saat: ' 2 ', tutar: ' 199,90 ' }, { saat: '24', tutar: '500' }], ARACLAR),
  [{ dakika: 120, kurus: 19990 }, { dakika: 1440, kurus: 50000 }],
)

// ---- 3. Doğrulama — veritabanının kademeler_gecerli'si ile aynı kurallar --
esit('hata: sahibin listesi geçerli', kademeHatasi(SAHIP_SATIR, ARACLAR), null)
esit('hata: yalnız 24 saat geçerli', kademeHatasi([{ saat: '24', tutar: '500' }], ARACLAR), null)
esit('hata: boş liste', kademeHatasi([], ARACLAR), 'En az bir kademe girin.')
esit(
  'hata: 24 saatte bitmiyor',
  kademeHatasi([{ saat: '2', tutar: '200' }, { saat: '8', tutar: '400' }], ARACLAR),
  'Son kademe 24 saate kadar olmalı.',
)
esit(
  'hata: sırasız',
  kademeHatasi(
    [{ saat: '4', tutar: '300' }, { saat: '2', tutar: '200' }, { saat: '24', tutar: '500' }],
    ARACLAR,
  ),
  'Kademe saatleri artan sırada olmalı.',
)
esit(
  'hata: aynı saat iki kez',
  kademeHatasi([{ saat: '2', tutar: '200' }, { saat: '2', tutar: '300' }, { saat: '24', tutar: '500' }], ARACLAR),
  'Kademe saatleri artan sırada olmalı.',
)
for (const saat of ['0', '25', '', 'abc', '2,5', '-1']) {
  esit(
    `hata: saat "${saat}"`,
    kademeHatasi([{ saat, tutar: '200' }, { saat: '24', tutar: '500' }], ARACLAR),
    'Kademe saatleri 1-24 arası tam sayı olmalı.',
  )
}
for (const tutar of ['', 'abc', '-5', '1.000']) {
  esit(
    `hata: tutar "${tutar}"`,
    kademeHatasi([{ saat: '2', tutar }, { saat: '24', tutar: '500' }], ARACLAR),
    'Kademe ücretlerini geçerli girin (örn. 200 ya da 200,50).',
  )
}
esit(
  'hata: ücret azalıyor',
  kademeHatasi([{ saat: '2', tutar: '300' }, { saat: '24', tutar: '200' }], ARACLAR),
  'Daha uzun kalan araç daha az ödeyemez — ücretler azalmamalı.',
)
esit(
  'hata: eşit ücret serbest',
  kademeHatasi([{ saat: '2', tutar: '300' }, { saat: '24', tutar: '300' }], ARACLAR),
  null,
)
const cokFazla = Array.from({ length: KADEME_EN_COK + 1 }, (_, i) => ({
  saat: String(i + 1),
  tutar: String(100 + i),
}))
cokFazla[cokFazla.length - 1].saat = '24'
esit(
  'hata: 13 kademe',
  kademeHatasi(cokFazla, ARACLAR),
  `En fazla ${KADEME_EN_COK} kademe olabilir.`,
)
esit('sınır: 12 kademe', KADEME_EN_COK, 12)

// ---- 4. Ekranda gösterim: aralıklar -----------------------------------------
esit('aralıklar', kademeAraliklari(SAHIP), [
  { etiket: '0–2 saat', kurus: 20000 },
  { etiket: '2–4 saat', kurus: 30000 },
  { etiket: '4–8 saat', kurus: 40000 },
  { etiket: '8–24 saat', kurus: 50000 },
])

console.log(`${gecen} geçti, ${kalan} kaldı`)
process.exit(kalan === 0 ? 0 : 1)
