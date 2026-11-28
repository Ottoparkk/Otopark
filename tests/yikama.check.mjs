// Oto yıkama (078) — İçeride listesindeki ücret metni ve Hizmetler kartının
// "Otopark" satırı.
//
//   node tests/yikama.check.mjs
//
// acik_bilet_ara'nın ucret_kurus'u otopark + yıkamadır (abonmanda yalnızca
// yıkama). Liste bunu yazar; abonmanda "Ücretsiz + 150 ₺" der.
import assert from 'node:assert/strict'
import { formatTL } from '../src/lib/money.ts'
import { listeUcretMetni, otoparkKurus, puanaAcikKurus } from '../src/features/gise/yikama.ts'

const tl = (k) => k / 100 + ' ₺'
const b = (o) => ({ abonman_id: null, ucret_kurus: 0, indirim_kurus: 0, yikama_kurus: null, ...o })

assert.equal(listeUcretMetni(b({ abonman_id: 'a', ucret_kurus: 0 }), tl), 'Ücretsiz')
assert.equal(listeUcretMetni(b({ abonman_id: 'a', ucret_kurus: 15000, yikama_kurus: 15000 }), tl), 'Ücretsiz + 150 ₺')
assert.equal(listeUcretMetni(b({ ucret_kurus: 35000, indirim_kurus: 5000, yikama_kurus: 15000 }), tl), '300 ₺')
assert.equal(listeUcretMetni(b({ ucret_kurus: 100, indirim_kurus: 500 }), tl), '0 ₺')
// Gerçek biçimleyiciyle de çalışır (uygulamanın kullandığı).
assert.equal(listeUcretMetni(b({ abonman_id: 'a', ucret_kurus: 15000, yikama_kurus: 15000 }), formatTL),
  'Ücretsiz + ' + formatTL(15000))

assert.equal(otoparkKurus(35000, 15000), 20000)
assert.equal(otoparkKurus(20000, null), 20000)
assert.equal(otoparkKurus(100, 15000), 0)

// Puan yalnızca otopark ücretine (puan_kullan, ucret_hesapla'ya göre sınırlar);
// yıkama puanla ödenmez. Ücretsiz süredeki yıkamalı araçta puan yok.
assert.equal(puanaAcikKurus(35000, 15000), 20000)
assert.equal(puanaAcikKurus(20000, null), 20000)
assert.equal(puanaAcikKurus(15000, 15000), 0)

console.log('yikama.check: hepsi geçti')
