// Abonman ödeme günü — sonraki ödeme günü, uzatma dönemi, "Ayın 13'ü".
//
//   node tests/abonman.check.mjs
//
// Sahip (2026-11-15): başlangıç/bitiş yerine ödeme günü seçilir; 29–31 kısa
// ayda ayın son günü olur. Sunucu (062, abonman_sonraki_yenileme) aynı
// kuralı uygular; PASS 80b aynı tabloyu sınar — ikisi ayrışmasın.
//
// Gerçek dosyayı içe aktarır; lib/abonman.ts yalnızca `import type` kullanır.
import { ayinGunu, sonrakiYenileme, yenilemeDonemi } from '../src/lib/abonman.ts'

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

// 1. Sonraki ödeme günü — PASS 80b ile AYNI tablo.
const TABLO = [
  [13, '2026-11-13', '2026-12-13'], [13, '2026-11-12', '2026-11-13'], [31, '2027-02-15', '2027-02-28'],
  [31, '2027-02-28', '2027-03-31'], [31, '2028-02-15', '2028-02-29'], [30, '2028-02-29', '2028-03-30'],
  [1, '2026-12-01', '2027-01-01'], [15, '2026-12-20', '2027-01-15'], [31, '2026-04-30', '2026-05-31'],
  [31, '2026-03-31', '2026-04-30'], [29, '2027-01-31', '2027-02-28'], [1, '2026-11-30', '2026-12-01'],
]
for (const [gun, tarih, beklenen] of TABLO) {
  esit(`sonraki(${gun}, ${tarih})`, sonrakiYenileme(gun, tarih), beklenen)
}
esit('geçersiz gün → null', sonrakiYenileme(0, '2026-11-15'), null)
esit('32 → null', sonrakiYenileme(32, '2026-11-15'), null)
esit('bozuk tarih → null', sonrakiYenileme(5, '2026-13-40'), null)

// 2. Tahsil + uzat: süren abonman bitişten devam eder, başlangıç korunur;
//    süresi dolmuş / DOLDU bugünden yeniden başlar. Gün boşsa bitişin günü.
const BUGUN = '2026-11-15'
const ab = (o) => ({ durum: 'AKTIF', baslangic: '2026-10-13', bitis: '2026-11-13', yenileme_gunu: 13, ...o })
esit('süren: bitişten', yenilemeDonemi(ab({ bitis: '2026-12-13' }), BUGUN), { bas: '2026-10-13', bit: '2027-01-13' })
esit('bugün bitiyor: hâlâ sürüyor', yenilemeDonemi(ab({ bitis: BUGUN, yenileme_gunu: 15 }), BUGUN),
  { bas: '2026-10-13', bit: '2026-12-15' })
esit('dünden doldu (AKTIF)', yenilemeDonemi(ab({ bitis: '2026-11-14', yenileme_gunu: 14 }), BUGUN),
  { bas: BUGUN, bit: '2026-12-14' })
esit('DOLDU: bugünden', yenilemeDonemi(ab({ durum: 'DOLDU' }), BUGUN), { bas: BUGUN, bit: '2026-12-13' })
esit('gün boş: bitişin günü', yenilemeDonemi(ab({ bitis: '2026-12-20', yenileme_gunu: null }), BUGUN),
  { bas: '2026-10-13', bit: '2027-01-20' })
esit('31, Ocak sonu → Şubat sonu', yenilemeDonemi(ab({ bitis: '2027-01-31', yenileme_gunu: 31 }), BUGUN),
  { bas: '2026-10-13', bit: '2027-02-28' })

// 3. "Ayın N'i" — okunuşa göre ek; 31 günün hepsi.
const EK = ['i', 'si', 'ü', 'ü', 'i', 'sı', 'si', 'i', 'u', 'u',
            'i', 'si', 'ü', 'ü', 'i', 'sı', 'si', 'i', 'u', 'si',
            'i', 'si', 'ü', 'ü', 'i', 'sı', 'si', 'i', 'u', 'u', 'i']
for (let n = 1; n <= 31; n++) esit(`ayinGunu(${n})`, ayinGunu(n), `Ayın ${n}'${EK[n - 1]}`)

console.log(`${gecen} geçti, ${kalan} kaldı`)
if (kalan) process.exit(1)
