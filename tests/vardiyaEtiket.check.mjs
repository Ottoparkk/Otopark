// Vardiya raporu (086, sahip 28.11): liste satırının etiketi ve işlem adları.
//
//   node tests/vardiyaEtiket.check.mjs
//
// Kurallar (İstanbul saati, sabit UTC+3):
//   * Etiket: "28.11 Gündüz 09:04 → 21:35". Tarih açılış günü.
//   * 06:00-17:59 arasında açıldıysa Gündüz, yoksa Gece.
//   * Açık vardiya: "→ şimdi".
//   * İşlem adları Türkçe; bilinmeyen kod olduğu gibi döner (boş kalmasın).
//   * Kısa etiket (rapor başlığı, liste satırı): "28.11 Gündüz".
//   * Karşılaştırma (sahip 28.11, Rocket Money özeti): aynı türden (Gündüz ile
//     Gündüz, Gece ile Gece) bir önceki vardiyaya göre yüzde, tam sayıya
//     yuvarlanmış. Önceki yoksa ya da toplamı 0 ise karşılaştırma yok.
import assert from 'node:assert/strict'
import {
  gecenGunMetni,
  gecmisGunler,
  gunEtiketi,
  oncekiAy,
  oncekiAyVar,
  yuzdeFark,
  islemEtiketi,
  oncekiKarsilastirma,
  vardiyaEtiketi,
  vardiyaTuru,
} from '../src/features/finans/vardiyaEtiket.ts'

const ist = (s) => new Date(Date.parse(s + ':00Z') - 3 * 3600_000).toISOString()

assert.equal(vardiyaEtiketi(ist('2026-11-28T09:04'), ist('2026-11-28T21:35')), '28.11 Gündüz 09:04 → 21:35')
assert.equal(vardiyaEtiketi(ist('2026-11-28T21:05'), ist('2026-11-29T09:02')), '28.11 Gece 21:05 → 09:02')
assert.equal(vardiyaEtiketi(ist('2026-11-28T21:05'), null), '28.11 Gece 21:05 → şimdi')

// Sınırlar: 06:00 Gündüz, 05:59 Gece, 17:59 Gündüz, 18:00 Gece.
assert.match(vardiyaEtiketi(ist('2026-11-28T06:00'), null), /Gündüz/)
assert.match(vardiyaEtiketi(ist('2026-11-28T05:59'), null), /Gece/)
assert.match(vardiyaEtiketi(ist('2026-11-28T17:59'), null), /Gündüz/)
assert.match(vardiyaEtiketi(ist('2026-11-28T18:00'), null), /Gece/)

// Gece yarısından sonra açılan (00:30) bir önceki gecenin devamı değil, kendi günü.
assert.equal(vardiyaEtiketi(ist('2026-12-01T00:30'), null), '01.12 Gece 00:30 → şimdi')

assert.equal(islemEtiketi('bilet_ucretsiz_cikis'), 'Ücretsiz çıkış')
assert.equal(islemEtiketi('bilet_cikis_geri_alindi'), 'Araç çıkmadı')
assert.equal(islemEtiketi('vardiya_devir'), 'Devraldı')
assert.equal(islemEtiketi('odeme_sonrasi_gec_cikis'), 'Ödedikten sonra geç çıktı')
assert.equal(islemEtiketi('bilinmeyen_kod'), 'bilinmeyen_kod')

// Kısa etiket ve tür.
assert.equal(vardiyaEtiketi(ist('2026-11-26T13:42'), ist('2026-11-27T01:42'), { kisa: true }), '26.11 Gündüz')
assert.equal(vardiyaEtiketi(ist('2026-11-27T01:42'), null, { kisa: true }), '27.11 Gece')
assert.equal(vardiyaTuru(ist('2026-11-28T06:00')), 'Gündüz')
assert.equal(vardiyaTuru(ist('2026-11-28T18:00')), 'Gece')

// Karşılaştırma: liste en yeniden eskiye, toplamlar kuruş.
const liste = [
  { id: 'g3', acilis_at: ist('2026-11-28T09:00') }, // Gündüz
  { id: 'n2', acilis_at: ist('2026-11-27T21:00') }, // Gece
  { id: 'g2', acilis_at: ist('2026-11-27T09:00') }, // Gündüz
  { id: 'n1', acilis_at: ist('2026-11-26T21:00') }, // Gece
  { id: 'g1', acilis_at: ist('2026-11-26T09:00') }, // Gündüz
]
const t = (o) => new Map(Object.entries(o).map(([k, v]) => [k, { toplam: v }]))
const T = t({ g3: 113000, n2: 50000, g2: 100000, n1: 54348, g1: 0 })
// Gündüz → önceki Gündüz (aradaki Gece atlanır): 113000 / 100000 → +%13.
assert.deepEqual(oncekiKarsilastirma(liste, 'g3', T), { yuzde: 13, yon: 'yukari' })
// Gece → önceki Gece: 50000 / 54348 → -%8.
assert.deepEqual(oncekiKarsilastirma(liste, 'n2', T), { yuzde: 8, yon: 'asagi' })
// Önceki toplam 0 → yok.
assert.equal(oncekiKarsilastirma(liste, 'g2', T), null)
// Daha eski aynı tür yok → yok.
assert.equal(oncekiKarsilastirma(liste, 'n1', T), null)
assert.equal(oncekiKarsilastirma(liste, 'g1', T), null)
// Eşit → %0, 'ayni'. Yarım yüzde aşağı yuvarlanınca 0 da 'ayni'.
assert.deepEqual(oncekiKarsilastirma(liste, 'g3', t({ g3: 100000, g2: 100000 })), { yuzde: 0, yon: 'ayni' })
assert.deepEqual(oncekiKarsilastirma(liste, 'g3', t({ g3: 100400, g2: 100000 })), { yuzde: 0, yon: 'ayni' })
// Toplamlar henüz gelmediyse ya da kendi toplamı yoksa → yok.
assert.equal(oncekiKarsilastirma(liste, 'g3', undefined), null)
assert.equal(oncekiKarsilastirma(liste, 'g3', t({ g2: 100000 })), null)
// Bilinmeyen id → yok.
assert.equal(oncekiKarsilastirma(liste, 'yok', T), null)

// Günlük rapor (sahip 28.11, takvim günü 00:00-24:00): yüzde farkı tek yerde.
assert.deepEqual(yuzdeFark(113000, 100000), { yuzde: 13, yon: 'yukari' })
assert.deepEqual(yuzdeFark(50000, 54348), { yuzde: 8, yon: 'asagi' })
assert.deepEqual(yuzdeFark(100400, 100000), { yuzde: 0, yon: 'ayni' })
assert.equal(yuzdeFark(5000, 0), null)
assert.equal(yuzdeFark(5000, null), null)
assert.equal(yuzdeFark(5000, undefined), null)

// Gün etiketi: bugün / dün / "26.11 Perşembe" (28.11.2026 Cumartesi).
assert.equal(gunEtiketi('2026-11-28', '2026-11-28'), 'Bugün')
assert.equal(gunEtiketi('2026-11-27', '2026-11-28'), 'Dün')
assert.equal(gunEtiketi('2026-11-26', '2026-11-28'), '26.11 Perşembe')
assert.equal(gunEtiketi('2026-11-30', '2026-12-01'), 'Dün') // ay değişimi
assert.equal(gunEtiketi('2026-11-22', '2026-11-28'), '22.11 Pazar')

// Karşılaştırma metni: geçen haftanın aynı günü, ayrılma hâli.
const gecen = {
  '2026-11-23': 'geçen pazartesiden',
  '2026-11-24': 'geçen salıdan',
  '2026-11-25': 'geçen çarşambadan',
  '2026-11-26': 'geçen perşembeden',
  '2026-11-27': 'geçen cumadan',
  '2026-11-28': 'geçen cumartesiden',
  '2026-11-29': 'geçen pazardan',
}
for (const [gun, metin] of Object.entries(gecen)) assert.equal(gecenGunMetni(gun), metin, gun)

// ------------------------------------------- Rapor listesi: bu ay, önceki ay
// Sahip 28.11: liste bu ayın günleri; altta "Önceki ayı gör" bir önceki ayı
// ekler, kaydın olduğu ilk aya kadar.
{
  const g = (toplam, arac) => ({ toplam, arac, onceki: 0 })
  const m = new Map([
    ['2026-11-26', g(10000, 3)],
    ['2026-11-28', g(5000, 1)], // bugün: listede değil (üstte büyük kart)
    ['2026-11-27', g(0, 0)], //    ne para ne araç: satır yok
    ['2026-11-25', g(0, 2)], //    para yok ama araç var: satır var
    ['2026-11-24', g(-2000, 0)], // iade: eksi toplam da satır
  ])
  assert.deepEqual(
    gecmisGunler(m, '2026-11-28').map(([gun]) => gun),
    ['2026-11-26', '2026-11-25', '2026-11-24'],
  )
  assert.deepEqual(gecmisGunler(undefined, '2026-11-28'), [])
  // Geçmiş bir ayın bütün günleri (bugün içinde değil).
  assert.deepEqual(
    gecmisGunler(new Map([['2026-10-01', g(1, 1)], ['2026-10-31', g(1, 1)]]), '2026-11-28').map(([x]) => x),
    ['2026-10-31', '2026-10-01'],
  )
}

assert.equal(oncekiAy('2026-11'), '2026-10')
assert.equal(oncekiAy('2026-01'), '2025-12')
assert.equal(oncekiAy('2026-10'), '2026-09')

// Gösterilen en eski ay ilk kaydın ayıysa ya da ondan eskiyse düğme yok.
assert.equal(oncekiAyVar('2026-11', '2026-09-14'), true)
assert.equal(oncekiAyVar('2026-10', '2026-09-14'), true)
assert.equal(oncekiAyVar('2026-09', '2026-09-14'), false)
assert.equal(oncekiAyVar('2026-08', '2026-09-14'), false)
assert.equal(oncekiAyVar('2026-01', '2025-12-31'), true)
// İlk gün henüz bilinmiyor: düğme görünür (sorulunca boş ay "kayıt yok" der).
assert.equal(oncekiAyVar('2026-11', undefined), true)

console.log('vardiyaEtiket.check: tamam')
