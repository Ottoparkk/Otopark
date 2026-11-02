// "Değiştir" — bilet düzeltme formunun kuralları (plaka, giriş saati, ücret,
// sebep) ve giriş saatinin İstanbul saatiyle gidip gelmesi.
//
//   node tests/degistir.check.mjs
//   TZ=UTC node tests/degistir.check.mjs
//   TZ=EST5EDT node tests/degistir.check.mjs
//
// Sonuç cihazın saat diliminden BAĞIMSIZ olmalı: uygulama her saati İstanbul
// saatiyle gösterir (lib/dates.ts), form da öyle yazmalı. Üç koşu da aynı
// sonucu vermeli. Windows'ta Node `America/New_York` gibi IANA adlarını yok
// sayar (sistem saatinde koşar) — POSIX biçimi `EST5EDT` çalışır.
//
// Gerçek dosyaları içe aktarır. degistir.ts çalışma zamanında hiçbir şey içe
// aktarmaz (Node uzantısız yolu çözemez); plaka ve para yardımcıları ona
// parametre olarak verilir — burada da GERÇEKLERİ veriliyor.
import { normalizePlaka, plakaGecerli } from '../src/lib/plaka.ts'
import { parseTLToKurus, kurusToInput } from '../src/lib/money.ts'
import {
  istanbulYerel,
  yereldenISO,
  degistirBaslangic,
  degisiklikler,
} from '../src/features/gise/degistir.ts'

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

const ARACLAR = { normalizePlaka, plakaGecerli, parseTLToKurus, kurusToInput }

// "Şimdi" sabit: 2026-11-02 14:00:30 İstanbul.
const NOW = new Date('2026-11-02T11:00:30.000Z')

// Saniyeli giriş: dokunulmamış bir alan bu saniyeleri "değişiklik" saymamalı.
const BILET = { plaka: '34ABC123', giris_at: '2026-11-02T08:15:45.678Z', indirim_kurus: 0 }

function taslakOf(bas, yama = {}) {
  return {
    plaka: bas.plaka,
    girisYerel: bas.girisYerel,
    ucretMetni: bas.ucretMetni ?? '',
    sebep: '',
    ...yama,
  }
}

// ---- 1. İstanbul saati, cihazdan bağımsız -----------------------------------
esit('yerel: UTC 10:05:45 → İstanbul 13:05', istanbulYerel('2026-11-02T10:05:45.123Z'), '2026-11-02T13:05')
esit('yerel: gece yarısını geçer', istanbulYerel('2026-11-01T22:30:00Z'), '2026-11-02T01:30')
esit('yerel: Date nesnesi', istanbulYerel(new Date('2026-12-31T21:00:00Z')), '2027-01-01T00:00')
esit('ISO: 13:05 İstanbul → 10:05 UTC', yereldenISO('2026-11-02T13:05'), '2026-11-02T10:05:00.000Z')
esit('ISO: gidip gelme', istanbulYerel(yereldenISO('2026-03-29T03:30')), '2026-03-29T03:30')
esit('ISO: boş', yereldenISO(''), null)
esit('ISO: çöp', yereldenISO('abc'), null)
esit('ISO: 13. ay', yereldenISO('2026-13-01T10:00'), null)
esit('ISO: 30 Şubat taşmaz', yereldenISO('2026-02-30T10:00'), null)
esit('ISO: 24:00 yok', yereldenISO('2026-11-02T24:00'), null)
esit('ISO: saniyeli biçim kabul edilmez', yereldenISO('2026-11-02T13:05:10'), null)

// ---- 2. Başlangıç: ücret BRÜT gelir (eski hata) ----------------------------
// Eski modal NET'i (ücret − puan) önden dolduruyor, ama BRÜT diye kaydediyordu:
// ₺200 ücret, ₺50 puan → ₺150 önden dolu → "Uygula" → ücret 150, net 100.
{
  const bas = degistirBaslangic({ ...BILET, indirim_kurus: 5000 }, 20000, ARACLAR)
  esit('başlangıç: ücret metni brüt', bas.ucretMetni, '200')
  esit('başlangıç: ücret kuruşu brüt', bas.ucretKurus, 20000)
  esit('başlangıç: puan indirimi taşınır', bas.indirimKurus, 5000)
  esit('başlangıç: giriş dakika hassasiyetinde', bas.girisYerel, '2026-11-02T11:15')
  esit('başlangıç: plaka', bas.plaka, '34ABC123')
  const s = degisiklikler(bas, taslakOf(bas), NOW, ARACLAR)
  esit('dokunulmamış form: hiçbir şey değişmez (ücret 150 olmaz)', s, {
    hata: null, bos: true, plaka: null, girisISO: null, ucretKurus: null, sebep: null,
  })
}
{
  const bas = degistirBaslangic(BILET, null, ARACLAR)
  esit('başlangıç: ücret düzenlenemez → null', [bas.ucretMetni, bas.ucretKurus], [null, null])
  const s = degisiklikler(bas, taslakOf(bas, { ucretMetni: '999' }), NOW, ARACLAR)
  esit('ücret düzenlenemezken yazılan değer yok sayılır', s.bos, true)
}
{
  const bas = degistirBaslangic(BILET, 25050, ARACLAR)
  esit('başlangıç: kuruşlu ücret', bas.ucretMetni, '250,50')
}

const BAS = degistirBaslangic(BILET, 20000, ARACLAR)

// ---- 3. Giriş saati -------------------------------------------------------
esit('saat değişti, sebep yok → sebep hatası',
  degisiklikler(BAS, taslakOf(BAS, { girisYerel: '2026-11-02T10:00' }), NOW, ARACLAR),
  { hata: 'Giriş saati ya da ücret değiştiyse sebep yazın — denetim kaydına geçer.', alan: 'sebep' })
esit('saat değişti, yalnızca boşluklu sebep → sebep hatası',
  degisiklikler(BAS, taslakOf(BAS, { girisYerel: '2026-11-02T10:00', sebep: '   ' }), NOW, ARACLAR).alan,
  'sebep')
esit('saat değişti + sebep',
  degisiklikler(BAS, taslakOf(BAS, { girisYerel: '2026-11-02T10:00', sebep: '  kamera geç okudu ' }), NOW, ARACLAR),
  { hata: null, bos: false, plaka: null, girisISO: '2026-11-02T07:00:00.000Z', ucretKurus: null, sebep: 'kamera geç okudu' })
esit('gelecek saat reddedilir',
  degisiklikler(BAS, taslakOf(BAS, { girisYerel: '2026-11-02T14:01', sebep: 'x' }), NOW, ARACLAR),
  { hata: 'Giriş saati ileri bir zaman olamaz.', alan: 'giris' })
esit('şu anki dakika kabul edilir (14:00:00 < 14:00:30)',
  degisiklikler(BAS, taslakOf(BAS, { girisYerel: '2026-11-02T14:00', sebep: 'x' }), NOW, ARACLAR).girisISO,
  '2026-11-02T11:00:00.000Z')
esit('bir yıldan eski reddedilir',
  degisiklikler(BAS, taslakOf(BAS, { girisYerel: '2025-11-02T13:59', sebep: 'x' }), NOW, ARACLAR),
  { hata: 'Giriş saati bir yıldan eski olamaz.', alan: 'giris' })
esit('tam bir yıl önce (sınır) kabul edilir',
  degisiklikler(BAS, taslakOf(BAS, { girisYerel: '2025-11-02T14:01', sebep: 'x' }), NOW, ARACLAR).hata,
  null)
esit('temizlenmiş saat alanı reddedilir',
  degisiklikler(BAS, taslakOf(BAS, { girisYerel: '', sebep: 'x' }), NOW, ARACLAR),
  { hata: 'Geçerli bir tarih ve saat girin.', alan: 'giris' })

// ---- 4. Plaka -------------------------------------------------------------
esit('yalnızca plaka: sebep gerekmez, normalize edilir',
  degisiklikler(BAS, taslakOf(BAS, { plaka: '34 xyz 99' }), NOW, ARACLAR),
  { hata: null, bos: false, plaka: '34XYZ99', girisISO: null, ucretKurus: null, sebep: null })
esit('aynı plaka farklı yazım → değişmedi',
  degisiklikler(BAS, taslakOf(BAS, { plaka: '34 abc 123' }), NOW, ARACLAR).bos,
  true)
esit('geçersiz plaka',
  degisiklikler(BAS, taslakOf(BAS, { plaka: 'A' }), NOW, ARACLAR),
  { hata: 'Geçerli bir plaka girin.', alan: 'plaka' })
esit('boş plaka',
  degisiklikler(BAS, taslakOf(BAS, { plaka: '' }), NOW, ARACLAR),
  { hata: 'Geçerli bir plaka girin.', alan: 'plaka' })

// ---- 5. Ücret -------------------------------------------------------------
esit('ücret değişti + sebep',
  degisiklikler(BAS, taslakOf(BAS, { ucretMetni: '250,50', sebep: 'müşteri itirazı' }), NOW, ARACLAR),
  { hata: null, bos: false, plaka: null, girisISO: null, ucretKurus: 25050, sebep: 'müşteri itirazı' })
esit('ücret değişti, sebep yok',
  degisiklikler(BAS, taslakOf(BAS, { ucretMetni: '100' }), NOW, ARACLAR).alan,
  'sebep')
esit('"200,00" = 200 → değişmedi',
  degisiklikler(BAS, taslakOf(BAS, { ucretMetni: ' 200,00 ' }), NOW, ARACLAR).bos,
  true)
esit('ücret 0 kabul edilir',
  degisiklikler(BAS, taslakOf(BAS, { ucretMetni: '0', sebep: 'x' }), NOW, ARACLAR).ucretKurus,
  0)
esit('belirsiz binlik ayraç reddedilir',
  degisiklikler(BAS, taslakOf(BAS, { ucretMetni: '1.250', sebep: 'x' }), NOW, ARACLAR),
  { hata: 'Geçerli bir tutar girin (örn. 250 ya da 250,50).', alan: 'ucret' })
esit('boş ücret reddedilir',
  degisiklikler(BAS, taslakOf(BAS, { ucretMetni: '', sebep: 'x' }), NOW, ARACLAR).alan,
  'ucret')
{
  const bas = degistirBaslangic({ ...BILET, indirim_kurus: 5000 }, 20000, ARACLAR)
  esit('ücret kullanılan puandan düşük olamaz',
    degisiklikler(bas, taslakOf(bas, { ucretMetni: '49,99', sebep: 'x' }), NOW, ARACLAR),
    { hata: 'Yeni ücret kullanılan puandan düşük olamaz.', alan: 'ucret' })
  esit('ücret = puan kabul edilir',
    degisiklikler(bas, taslakOf(bas, { ucretMetni: '50', sebep: 'x' }), NOW, ARACLAR).ucretKurus,
    5000)
}

// ---- 6. Hepsi birden ve öncelik -------------------------------------------
esit('üçü birden',
  degisiklikler(
    BAS,
    taslakOf(BAS, { plaka: '06AB1234', girisYerel: '2026-11-02T09:30', ucretMetni: '300', sebep: 'düzeltme' }),
    NOW,
    ARACLAR,
  ),
  { hata: null, bos: false, plaka: '06AB1234', girisISO: '2026-11-02T06:30:00.000Z', ucretKurus: 30000, sebep: 'düzeltme' })
esit('hata önceliği: plaka, sonra saat',
  degisiklikler(BAS, taslakOf(BAS, { plaka: 'A', girisYerel: '2030-01-01T00:00' }), NOW, ARACLAR).alan,
  'plaka')
esit('hata önceliği: saat, sonra ücret',
  degisiklikler(BAS, taslakOf(BAS, { girisYerel: '2030-01-01T00:00', ucretMetni: 'x' }), NOW, ARACLAR).alan,
  'giris')
esit('hata önceliği: ücret, sonra sebep',
  degisiklikler(BAS, taslakOf(BAS, { ucretMetni: 'x' }), NOW, ARACLAR).alan,
  'ucret')

console.log(`${gecen} geçti, ${kalan} kaldı (TZ=${process.env.TZ ?? 'sistem'})`)
if (kalan > 0) process.exit(1)
