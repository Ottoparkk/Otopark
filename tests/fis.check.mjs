// Fiş içeriği (088) — giriş ve çıkış fişinin satırları.
//
//   node tests/fis.check.mjs
//   TZ=UTC node tests/fis.check.mjs
//
// Gerçek dosyayı içe aktarır. fisIcerik.ts çalışma zamanında hiçbir şey içe
// aktarmaz; para ve saat biçimleyicileri ona parametre olarak verilir —
// burada da GERÇEKLERİ veriliyor. Sahip 28.11: fişte süre/tolerans yazmaz
// ("No grace on the fiş"), mali değeri yoktur, tekrar basım belli olur.
import assert from 'node:assert/strict'
import { formatTL } from '../src/lib/money.ts'
import { formatSaat, formatTam } from '../src/lib/dates.ts'
import { ucretsizEtiket } from '../src/lib/ucretsiz.ts'
import { formatPlaka } from '../src/lib/plaka.ts'
import { girisFisi, cikisFisi, fisNo, sureMetni } from '../src/features/fis/fisIcerik.ts'
import { fisAdaylari, fisYazdirir } from '../src/features/fis/fisIste.ts'

const araclar = { tl: formatTL, saat: formatSaat, tam: formatTam, ucretsizEtiket, plaka: formatPlaka }
const otopark = { ad: 'Merkez Otopark', adres: 'Atatürk Cd. 1', telefon: '0212 000 00 00' }
const ist = (s) => new Date(`${s}:00+03:00`).toISOString()

const temel = {
  id: '1a2b3c4d-0000-4000-8000-000000000001',
  plaka: '34ABC123',
  giris_at: ist('2026-11-28T14:05'),
  cikis_at: null,
  ucret_kurus: 0,
  indirim_kurus: 0,
  puan_kullanilan: 0,
  tahsil_kurus: 0,
  odeme_yontemi: null,
  abonman_id: null,
  yikama_kurus: null,
  anlasma_kurus: null,
  anlasma_bitis: null,
  ucretsiz_sebep: null,
}
const basimAt = ist('2026-11-28T14:06')

/** Bütün satırlar düz metin, alt alta — "fişte yazıyor mu?" için. */
function metin(satirlar) {
  return satirlar
    .map((s) => {
      switch (s.t) {
        case 'satir':
          return `${s.sol} | ${s.sag}`
        case 'cizgi':
          return '---'
        default:
          return s.metin
      }
    })
    .join('\n')
}
const HER_FISTE = ['Merkez Otopark']
// Sahip 28.11: fişte adres ve telefon yok; önceden belirlenmiş bir ücret
// yoksa fiyat bilgisi (tarife, ücretsiz süre) yok; "gerçek süreye göre"
// satırı yok. Süre/tolerans hiçbir fişte yazmaz.
const YOK = ['Mali değeri', 'Atatürk', 'Tel:', 'İlk saat', 'Sonraki', 'Ücretsiz', 'Günlük', 'Sabit', 'gerçek süreye']
const TOLERANS = /tolerans|içinde çık|dk içinde|süreniz|çıkış süresi/i
function yokMu(m, yer) {
  for (const x of YOK) assert.ok(!m.includes(x), `${yer} fişinde olmamalı: ${x}`)
  assert.ok(!TOLERANS.test(m), `${yer} fişinde süre/tolerans yazıyor`)
}

// ---------------------------------------------------------------- yardımcılar
assert.equal(fisNo(temel.id), '1A2B3C4D')
assert.equal(sureMetni(0), '0 dk')
assert.equal(sureMetni(45), '45 dk')
assert.equal(sureMetni(120), '2 sa')
assert.equal(sureMetni(127), '2 sa 7 dk')
assert.equal(sureMetni(1440 + 185), '1 gün 3 sa 5 dk')

// ------------------------------------------------------ giriş fişi, tahminsiz
{
  const s = girisFisi({ otopark, bilet: temel, basim: 1, basimAt, tahmin: null }, araclar)
  const m = metin(s)
  for (const x of HER_FISTE) assert.ok(m.includes(x), `giriş fişinde yok: ${x}`)
  yokMu(m, 'giriş')
  assert.ok(m.includes('GİRİŞ FİŞİ'))
  assert.ok(s.some((x) => x.t === 'buyuk' && x.metin === '34 ABC 123'), 'plaka büyük yazılmalı')
  assert.ok(m.includes('Giriş | 28.11.2026 14:05'))
  assert.ok(m.includes('Fiş no | 1A2B3C4D'))
  // Sahip 28.11: QR yok (taranmadığı sürece işe yaramıyor, kâğıt yiyor).
  assert.ok(!s.some((x) => x.t === 'qr'), 'giriş fişinde QR olmamalı')
  assert.ok(!m.includes('TEKRAR BASIM'))
  assert.ok(!m.includes('Tahmini'))
  assert.ok(!m.includes('₺'), 'önceden belirlenmiş ücret yokken fişte para yazmaz')
}

// ------------------------------------------- giriş fişi, 2 saat tahmin, tekrar
// Tahmin seçildiyse o önceden konuşulmuş ücrettir: yazar.
{
  const s = girisFisi({ otopark, bilet: temel, basim: 2, basimAt, tahmin: { dakika: 120, kurus: 20000 } }, araclar)
  const m = metin(s)
  yokMu(m, 'tahminli giriş')
  assert.ok(m.includes('TEKRAR BASIM (2)'))
  assert.ok(m.includes('Tahmini çıkış | 16:05'))
  assert.ok(m.includes('Tahmini ücret (2 sa) | 200 ₺'))
}

// --------------------------------------------- giriş fişi: yıkama, anlaşma
{
  const b = { ...temel, yikama_kurus: 15000, anlasma_kurus: 30000, anlasma_bitis: ist('2026-11-28T18:00') }
  const m = metin(girisFisi({ otopark, bilet: b, basim: 1, basimAt, tahmin: null }, araclar))
  yokMu(m, 'anlaşmalı giriş')
  assert.ok(m.includes('Oto yıkama | 150 ₺'))
  assert.ok(m.includes('Anlaşmalı fiyat | 300 ₺'))
  assert.ok(m.includes('Anlaşma bitişi | 18:00'))
}

// ------------------------------------------------------- giriş fişi: abonman
{
  const m = metin(girisFisi({ otopark, bilet: { ...temel, abonman_id: 'ab-1' }, basim: 1, basimAt, tahmin: null }, araclar))
  yokMu(m, 'abonman giriş')
  assert.ok(m.includes('Abonman | Ücret alınmaz'))
}

// ------------------------------------------------------- çıkış fişi, ödenmiş
{
  const b = {
    ...temel,
    cikis_at: ist('2026-11-28T16:12'),
    ucret_kurus: 35000,
    yikama_kurus: 15000,
    indirim_kurus: 2000,
    puan_kullanilan: 20,
    tahsil_kurus: 33000,
    odeme_yontemi: 'KREDI_KARTI',
  }
  const s = cikisFisi({ otopark, bilet: b, basim: 1, basimAt }, araclar)
  const m = metin(s)
  for (const x of HER_FISTE) assert.ok(m.includes(x), `çıkış fişinde yok: ${x}`)
  assert.ok(!m.includes('Atatürk') && !m.includes('Tel:'), 'çıkış fişinde adres/telefon olmamalı')
  assert.ok(!m.includes('Mali değeri'), 'çıkış fişinde "Mali değeri yoktur" olmamalı (sahip 28.11)')
  assert.ok(m.includes('ÇIKIŞ FİŞİ'))
  assert.ok(s.some((x) => x.t === 'buyuk' && x.metin === '34 ABC 123'))
  assert.ok(m.includes('Giriş | 28.11.2026 14:05'))
  assert.ok(m.includes('Çıkış | 28.11.2026 16:12'))
  assert.ok(m.includes('Süre | 2 sa 7 dk'))
  assert.ok(m.includes('Park ücreti | 200 ₺'))
  assert.ok(m.includes('Oto yıkama | 150 ₺'))
  assert.ok(m.includes('Puan indirimi | -20 ₺'))
  assert.ok(s.some((x) => x.t === 'satir' && x.sol === 'TOPLAM' && x.sag === '330 ₺' && x.kalin))
  assert.ok(m.includes('Ödeme | Kredi kartı'))
  assert.ok(m.includes('ÖDENDİ'))
  assert.ok(!s.some((x) => x.t === 'qr'), 'çıkış fişinde QR olmamalı')
  assert.ok(!TOLERANS.test(m))
  assert.ok(!m.includes('TEKRAR BASIM'))
  // Tekrar basım ("Araç çıkmadı"dan sonra, ya da müşteri yeniden istedi).
  assert.ok(metin(cikisFisi({ otopark, bilet: b, basim: 3, basimAt }, araclar)).includes('TEKRAR BASIM (3)'))
}

// ------------------------------------------- çıkış fişi: ücretsiz, abonman, 0
{
  const kapali = { ...temel, cikis_at: ist('2026-11-28T14:20') }
  const m = metin(
    cikisFisi({ otopark, bilet: { ...kapali, ucretsiz_sebep: 'POLIS' }, basim: 1, basimAt }, araclar),
  )
  assert.ok(m.includes('Ücretsiz çıkış | Polis / resmi araç'))
  assert.ok(m.includes('TOPLAM | 0 ₺'))
  assert.ok(!m.includes('ÖDENDİ'))
  assert.ok(!m.includes('Ödeme |'))

  const m2 = metin(cikisFisi({ otopark, bilet: { ...kapali, abonman_id: 'ab-1' }, basim: 1, basimAt }, araclar))
  assert.ok(m2.includes('Abonman | Ücret alınmaz'))
  assert.ok(m2.includes('TOPLAM | 0 ₺'))

  // Ücretsiz süre içinde çıkış: 0 ₺, ödeme satırı yok.
  const m3 = metin(cikisFisi({ otopark, bilet: kapali, basim: 1, basimAt }, araclar))
  assert.ok(m3.includes('TOPLAM | 0 ₺'))
  assert.ok(!m3.includes('Park ücreti'))
}

// ---------------------------------- borçlu ya da çıkmamış bilete çıkış fişi yok
// Sunucu (fis_basildi) zaten reddeder; içerik de kendi başına basmaz.
assert.throws(
  () =>
    cikisFisi(
      { otopark, bilet: { ...temel, cikis_at: ist('2026-11-28T16:12'), ucret_kurus: 20000 }, basim: 1, basimAt },
      araclar,
    ),
  /Önce ödeme toplayın/,
)
assert.throws(() => cikisFisi({ otopark, bilet: temel, basim: 1, basimAt }, araclar), /çıkış yaptıktan sonra/)

// ------------------------------------- kim fiş basar (sahip 28.11): Personel
// P2'yi Personel kullanır; Yönetici'ye ve onaysız hesaba fiş düğmesi yok.
assert.equal(fisYazdirir({ rol: 'PERSONEL', durum: 'ACTIVE' }), true)
assert.equal(fisYazdirir({ rol: 'YONETICI', durum: 'ACTIVE' }), false)
assert.equal(fisYazdirir({ rol: 'PERSONEL', durum: 'DISABLED' }), false)
assert.equal(fisYazdirir({ rol: null, durum: 'PENDING' }), false)
assert.equal(fisYazdirir(null), false)

console.log('fis.check: tamam')
