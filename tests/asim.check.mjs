// Süre aşımı onayı (082) — bir biletin aşım durumu ve karar satırı.
//
//   node tests/asim.check.mjs
//
// Sunucu (bilet_asim_bekliyor / bilet_asim_onizle) karar verir; istemci
// yalnızca neyi göstereceğini seçer: rapor ve iki düğme (BEKLIYOR), karar
// satırı (TAM / ILK) ya da hiçbir şey (YOK).
import assert from 'node:assert/strict'
import { asimDurumu, asimKararMetni } from '../src/features/gise/asim.ts'

const normal = { abonman_id: null, anlasma_kurus: null, asim_karar: null, ucretsiz_sebep: null, ucret_degistirildi: false }
const asan = { ilk_kurus: 20000, tam_kurus: 45000 }

// Rapor geldiyse ve karar yoksa: bekliyor.
assert.equal(asimDurumu(normal, asan), 'BEKLIYOR')
// Rapor yok (ilk kademe içinde, kademesiz tarife ya da yükleniyor): yok.
assert.equal(asimDurumu(normal, null), 'YOK')
assert.equal(asimDurumu(normal, undefined), 'YOK')
// Sunucu tam ≤ ilk göndermez; gönderse bile aşım sayılmaz.
assert.equal(asimDurumu(normal, { ilk_kurus: 20000, tam_kurus: 20000 }), 'YOK')

// Karar verildiyse rapor ne derse desin karar gösterilir.
assert.equal(asimDurumu({ ...normal, asim_karar: 'TAM' }, asan), 'TAM')
assert.equal(asimDurumu({ ...normal, asim_karar: 'ILK' }, null), 'ILK')

// Abonman, anlaşma, ücretsiz çıkış ve elle ücret kendileri bir karardır.
assert.equal(asimDurumu({ ...normal, abonman_id: 'a1' }, asan), 'YOK')
assert.equal(asimDurumu({ ...normal, anlasma_kurus: 60000 }, asan), 'YOK')
assert.equal(asimDurumu({ ...normal, ucretsiz_sebep: 'DIGER' }, asan), 'YOK')
assert.equal(asimDurumu({ ...normal, ucret_degistirildi: true }, asan), 'YOK')
// Alanları hiç taşımayan eski satır (082 koşmadan önce) normal sayılır.
assert.equal(asimDurumu({ abonman_id: null }, asan), 'BEKLIYOR')

// Karar satırı: kim verdi, adı yoksa yalnızca karar.
assert.equal(asimKararMetni('TAM', 'Ali'), 'Tam ücret onaylandı · Ali')
assert.equal(asimKararMetni('ILK', 'Ayşe'), 'İlk kademe ücreti bırakıldı · Ayşe')
assert.equal(asimKararMetni('TAM', null), 'Tam ücret onaylandı')

console.log('asim.check: OK')
