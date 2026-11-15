// Ücretsiz çıkış (065, sahip 2026-11-15): sebep listesi, etiketler ve formun
// kuralları. Sunucu aynısını söyler (bilet_ucretsiz_cikis, PASS 82);
// etiketler 065'teki ucretsiz_etiket ile birebir olmalı.
//
//   node tests/ucretsiz.check.mjs
import {
  UCRETSIZ_SEBEPLER,
  sonradanUcretsizMi,
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

// Sonradan ücretsiz (066): kamera ya da "Çıkış Ver" bileti borçlu kapattı.
// Düğme yalnızca sunucunun kabul edeceği bilette görünür (bilet_ucretsiz_cikis,
// KAPALI dal; PASS 83). Borç çağırandan gelir (lib/bilet.ts biletBorcu).
const borclu = {
  durum: 'KAPALI', tahsil_kurus: 0, indirim_kurus: 0, ucretsiz_sebep: null,
}
esit('sonradan: kamera kapattı, 200 ₺ borç', sonradanUcretsizMi(borclu, 20000), true)
esit('sonradan: borç yok (0 ₺ kalış)', sonradanUcretsizMi(borclu, 0), false)
esit('sonradan: ödemesi alınmış', sonradanUcretsizMi({ ...borclu, tahsil_kurus: 20000 }, 20000), false)
esit('sonradan: puan kullanılmış', sonradanUcretsizMi({ ...borclu, indirim_kurus: 500 }, 19500), false)
esit('sonradan: zaten ücretsiz', sonradanUcretsizMi({ ...borclu, ucretsiz_sebep: 'POLIS' }, 20000), false)
esit('sonradan: araç içeride (çıkış ekranının işi)', sonradanUcretsizMi({ ...borclu, durum: 'ACIK' }, 20000), false)
esit('sonradan: iptal', sonradanUcretsizMi({ ...borclu, durum: 'IPTAL' }, 20000), false)
esit('sonradan: 065 öncesi satır (alan yok)', sonradanUcretsizMi({ durum: 'KAPALI', tahsil_kurus: 0, indirim_kurus: 0 }, 20000), true)

console.log(`ucretsiz: ${gecen} geçti, ${kalan} kaldı`)
if (kalan > 0) process.exit(1)
