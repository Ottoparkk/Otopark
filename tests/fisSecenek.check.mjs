// Giriş fişi — "Müşteri ne kadar kalacak?" seçenekleri.
//
//   node tests/fisSecenek.check.mjs
//
// Sahip 28.11: seçenekler biletin tarife kademeleriyle aynı olsun
// (0–2 saat, 2–4 saat, 4–8 saat, 8–24 saat). Her seçeneğin dakikası
// kademenin ÜST sınırıdır; sunucu (`fis_tahmini`) o süreyi fiyatlar, yani
// kademenin fiyatı. Kademesiz tarifede (SÜRELİ / SABİT) eski saat listesi.
// fisSecenek.ts çalışma zamanında hiçbir şey içe aktarmaz; yardımcılar
// parametre — burada GERÇEKLERİ veriliyor.
import assert from 'node:assert/strict'
import { kademeAraliklari } from '../src/features/finans/kademe.ts'
import { sureMetni } from '../src/features/fis/fisIcerik.ts'
import { fisTahminSecenekleri, parcala } from '../src/features/fis/fisSecenek.ts'

const yard = { araliklar: kademeAraliklari, sure: sureMetni }

// ------------------------------------------------ kademeli: sahibin tarifesi
{
  const tarife = {
    tur: 'KADEMELI',
    kademeler: [
      { dakika: 120, kurus: 20000 },
      { dakika: 240, kurus: 30000 },
      { dakika: 480, kurus: 40000 },
      { dakika: 1440, kurus: 50000 },
    ],
  }
  assert.deepEqual(fisTahminSecenekleri(tarife, yard), [
    { dakika: 120, etiket: '0–2 saat' },
    { dakika: 240, etiket: '2–4 saat' },
    { dakika: 480, etiket: '4–8 saat' },
    { dakika: 1440, etiket: '8–24 saat' },
  ])
}

// ----------------------------------------------- tek kademe (yalnızca 24 sa)
assert.deepEqual(
  fisTahminSecenekleri({ tur: 'KADEMELI', kademeler: [{ dakika: 1440, kurus: 50000 }] }, yard),
  [{ dakika: 1440, etiket: '0–24 saat' }],
)

// --------------------------------- kademesiz tarife: eski sabit saat listesi
for (const tur of ['SURELI', 'SABIT']) {
  assert.deepEqual(fisTahminSecenekleri({ tur, kademeler: null }, yard), [
    { dakika: 60, etiket: '1 sa' },
    { dakika: 120, etiket: '2 sa' },
    { dakika: 180, etiket: '3 sa' },
    { dakika: 240, etiket: '4 sa' },
    { dakika: 360, etiket: '6 sa' },
  ])
}
// KADEMELI yazıp listesi boş/eksik (051 öncesi okuma): sabit liste.
assert.equal(fisTahminSecenekleri({ tur: 'KADEMELI', kademeler: [] }, yard).length, 5)
assert.equal(fisTahminSecenekleri({ tur: 'KADEMELI' }, yard).length, 5)
// Tarife henüz yüklenmedi: seçenek yok.
assert.deepEqual(fisTahminSecenekleri(null, yard), [])
assert.deepEqual(fisTahminSecenekleri(undefined, yard), [])

// ------------------------------------ fis_tahmini en çok 6 dakika alır (088)
// 12 kademeye kadar izin var (051): istek 6'lık parçalara bölünür.
assert.deepEqual(parcala([1, 2, 3], 6), [[1, 2, 3]])
assert.deepEqual(parcala([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12], 6), [
  [1, 2, 3, 4, 5, 6],
  [7, 8, 9, 10, 11, 12],
])
assert.deepEqual(parcala([1, 2, 3, 4, 5, 6, 7], 6), [[1, 2, 3, 4, 5, 6], [7]])
assert.deepEqual(parcala([], 6), [])

console.log('fisSecenek.check: tamam')
