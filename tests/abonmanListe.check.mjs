// Abonman listesi — ödeme gününe göre gruplar, fiyat sıralaması, arama,
// kısa tarih ve "N gün kaldı" (sahip, 27.11).
//
//   node tests/abonmanListe.check.mjs
//
// Gerçek dosyayı içe aktarır; features/abonman/liste.ts yalnızca `import type`
// kullanır.
import assert from 'node:assert/strict'
import {
  abonmanAra,
  abonmanGruplari,
  abonmanOzeti,
  kalanRozeti,
  kisaTarih,
  odemeGunu,
} from '../src/features/abonman/liste.ts'

const a = (o) => ({
  id: o.plaka, plaka: o.plaka, musteri_ad: o.ad ?? '', musteri_tel: null,
  baslangic: o.bas ?? '2026-11-01', bitis: o.bit, ucret_kurus: o.ucret ?? 100000,
  park_yeri_id: null, yenileme_gunu: o.gun === undefined ? Number(o.bit.slice(8, 10)) : o.gun,
  durum: o.durum ?? 'AKTIF', notlar: null, olusturan: null, created_at: '2026-11-01T00:00:00Z',
})
const plakalar = (g) => g.ogeler.map((x) => x.plaka)

// Kısa tarih: "1.12.26".
assert.equal(kisaTarih('2026-12-01'), '1.12.26')
assert.equal(kisaTarih('2027-01-15'), '15.1.27')
assert.equal(kisaTarih('bozuk'), 'bozuk')

// Ödeme günü: kayıtlı gün, yoksa bitişin günü.
assert.equal(odemeGunu(a({ plaka: 'X', bit: '2026-12-13', gun: 13 })), 13)
assert.equal(odemeGunu(a({ plaka: 'X', bit: '2026-12-13', gun: null })), 13)

const L = [
  a({ plaka: '34B2', ad: 'Ayşe Kaya', bit: '2026-12-15', gun: 15, ucret: 150000 }),
  a({ plaka: '34A1', ad: 'Ahmet Yılmaz', bit: '2026-12-01', gun: 1, ucret: 200000 }),
  a({ plaka: '06C3', ad: 'İsmail Şen', bit: '2026-12-01', gun: 1, ucret: 100000 }),
  // Kısa ayda 31 → 30 Kasım'a düşmüş; grubu yine 31.
  a({ plaka: '35D4', bit: '2026-11-30', gun: 31, ucret: 150000 }),
  a({ plaka: '07E5', bit: '2026-11-29', gun: 1, ucret: 120000 }),
]

// Aktif, varsayılan: ödeme gününe göre 1 → 31; grup içinde bitiş, sonra plaka.
let g = abonmanGruplari(L, 'AKTIF', 'VARSAYILAN')
assert.deepEqual(g.map((x) => x.gun), [1, 15, 31])
assert.deepEqual(plakalar(g[0]), ['07E5', '06C3', '34A1'])
assert.equal(g[0].adet, 3)
assert.equal(g[0].toplamKurus, 420000)
assert.deepEqual(plakalar(g[2]), ['35D4'])

// Fiyat: düz liste, eşitlikte plaka.
g = abonmanGruplari(L, 'AKTIF', 'ARTAN')
assert.equal(g.length, 1)
assert.equal(g[0].gun, null)
assert.deepEqual(plakalar(g[0]), ['06C3', '07E5', '34B2', '35D4', '34A1'])
g = abonmanGruplari(L, 'AKTIF', 'AZALAN')
assert.deepEqual(plakalar(g[0]), ['34A1', '34B2', '35D4', '07E5', '06C3'])

// Doldu / İptal varsayılan: bitiş tarihine göre, en yeni biten üstte.
g = abonmanGruplari(L, 'DOLDU', 'VARSAYILAN')
assert.equal(g.length, 1)
assert.deepEqual(plakalar(g[0]), ['34B2', '06C3', '34A1', '35D4', '07E5'])
assert.deepEqual(plakalar(abonmanGruplari(L, 'IPTAL', 'VARSAYILAN')[0]), plakalar(g[0]))

// Boş liste: grup yok.
assert.deepEqual(abonmanGruplari([], 'AKTIF', 'VARSAYILAN'), [])
assert.deepEqual(abonmanGruplari([], 'DOLDU', 'ARTAN'), [])

// Girdi listesi bozulmaz.
assert.equal(L[0].plaka, '34B2')

// Arama: plaka (boşluk/küçük harf fark etmez) ya da isim (Türkçe küçük harf).
assert.deepEqual(abonmanAra(L, '34 a').map((x) => x.plaka), ['34A1'])
assert.deepEqual(abonmanAra(L, 'ayşe').map((x) => x.plaka), ['34B2'])
assert.deepEqual(abonmanAra(L, 'İSMAİL').map((x) => x.plaka), ['06C3'])
assert.deepEqual(abonmanAra(L, 'ismail').map((x) => x.plaka), ['06C3'])
assert.equal(abonmanAra(L, '  ').length, 5)
assert.equal(abonmanAra(L, 'zzz').length, 0)

// Özet.
assert.deepEqual(abonmanOzeti(L), { adet: 5, toplamKurus: 720000 })
assert.deepEqual(abonmanOzeti([]), { adet: 0, toplamKurus: 0 })

// "N gün kaldı": yalnızca AKTIF ve en çok 4 gün (bildirimle aynı).
const BUGUN = '2026-11-27'
assert.equal(kalanRozeti(a({ plaka: 'X', bit: '2026-11-27' }), BUGUN), 'Bugün bitiyor')
assert.equal(kalanRozeti(a({ plaka: 'X', bit: '2026-11-28' }), BUGUN), '1 gün kaldı')
assert.equal(kalanRozeti(a({ plaka: 'X', bit: '2026-12-01' }), BUGUN), '4 gün kaldı')
assert.equal(kalanRozeti(a({ plaka: 'X', bit: '2026-12-02' }), BUGUN), null)
assert.equal(kalanRozeti(a({ plaka: 'X', bit: '2026-11-28', durum: 'DOLDU' }), BUGUN), null)
// Gece işi henüz çalışmadıysa: süresi geçmiş ama hâlâ AKTIF.
assert.equal(kalanRozeti(a({ plaka: 'X', bit: '2026-11-26' }), BUGUN), 'Süresi doldu')

console.log('abonmanListe.check: OK')
