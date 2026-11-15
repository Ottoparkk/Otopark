// Ücretsiz çıkış (065, sahip 2026-11-15): sebep listesi, etiketler ve formun
// kuralları. Sunucu aynısını söyler (bilet_ucretsiz_cikis, PASS 82);
// etiketler 065'teki ucretsiz_etiket ile birebir olmalı.
//
//   node tests/ucretsiz.check.mjs
import {
  UCRETSIZ_SEBEPLER,
  ucretsizEtiket,
  ucretsizHatasi,
} from '../src/lib/ucretsiz.ts'

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

// Sıra ve etiketler — 065'in enum sırası ve ucretsiz_etiket'i.
esit('sebepler: sıra ve etiketler', UCRETSIZ_SEBEPLER, [
  { value: 'FIYAT_SORDU', label: 'Fiyat sordu' },
  { value: 'POLIS', label: 'Polis / resmi araç' },
  { value: 'ACIL', label: 'Ambulans / itfaiye' },
  { value: 'PERSONEL', label: 'Personel / sahip aracı' },
  { value: 'DIGER', label: 'Diğer' },
])
esit('etiket: POLIS', ucretsizEtiket('POLIS'), 'Polis / resmi araç')
esit('etiket: DIGER', ucretsizEtiket('DIGER'), 'Diğer')
esit('etiket: boş', ucretsizEtiket(null), null)
esit('etiket: tanımsız (065 öncesi satır)', ucretsizEtiket(undefined), null)

// Form kuralları — sunucunun hata metinleriyle aynı.
esit('hata: sebep yok', ucretsizHatasi(null, 'Ekip aracı'), 'Sebep seçin.')
esit('hata: not boş', ucretsizHatasi('POLIS', ''), 'Not zorunludur.')
esit('hata: not yalnız boşluk', ucretsizHatasi('POLIS', '   \n '), 'Not zorunludur.')
esit('hata: sebep de not da yok → önce sebep', ucretsizHatasi(null, ''), 'Sebep seçin.')
esit('hata: 201 karakter', ucretsizHatasi('DIGER', 'x'.repeat(201)), 'Not en fazla 200 karakter olabilir.')
esit('geçerli: 200 karakter', ucretsizHatasi('DIGER', 'x'.repeat(200)), null)
esit('geçerli: kenar boşlukları sayılmaz', ucretsizHatasi('DIGER', `  ${'x'.repeat(200)}  `), null)
esit('geçerli: kısa not', ucretsizHatasi('FIYAT_SORDU', 'Fiyat sordu, çıktı'), null)

console.log(`ucretsiz: ${gecen} geçti, ${kalan} kaldı`)
if (kalan > 0) process.exit(1)
