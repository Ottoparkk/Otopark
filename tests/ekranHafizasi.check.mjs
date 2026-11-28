// Ekran hafızası — sekme, filtre ve arama geri dönünce kaybolmasın (sahip, 27.11).
//
//   node tests/ekranHafizasi.check.mjs
//
// Değer `op.ekran.<anahtar>` altında JSON olarak durur. Okunamayan, bozuk ya
// da artık geçerli olmayan değer varsayılana döner (eski bir sürümün bıraktığı
// sekme adı ekranı kırmamalı). Çıkışta yalnızca ekran anahtarları silinir.
import assert from 'node:assert/strict'
import { hafizaOku, hafizaTemizle, hafizaYaz } from '../src/lib/ekranHafizasi.ts'

function sahteDepo(ilk = {}) {
  const m = new Map(Object.entries(ilk))
  return {
    get length() { return m.size },
    key: (i) => [...m.keys()][i] ?? null,
    getItem: (k) => (m.has(k) ? m.get(k) : null),
    setItem: (k, v) => m.set(k, String(v)),
    removeItem: (k) => m.delete(k),
    _m: m,
  }
}

const SEKMELER = ['ICERIDE', 'CIKAN']

// Yoksa varsayılan.
let d = sahteDepo()
assert.equal(hafizaOku(d, 'gise.filtre', 'ICERIDE', SEKMELER), 'ICERIDE')

// Yaz → oku.
hafizaYaz(d, 'gise.filtre', 'CIKAN')
assert.equal(d.getItem('op.ekran.gise.filtre'), '"CIKAN"')
assert.equal(hafizaOku(d, 'gise.filtre', 'ICERIDE', SEKMELER), 'CIKAN')

// Bozuk JSON ve geçersiz değer → varsayılan.
d = sahteDepo({ 'op.ekran.gise.filtre': '{bozuk' })
assert.equal(hafizaOku(d, 'gise.filtre', 'ICERIDE', SEKMELER), 'ICERIDE')
d = sahteDepo({ 'op.ekran.gise.filtre': '"ESKI_SEKME"' })
assert.equal(hafizaOku(d, 'gise.filtre', 'ICERIDE', SEKMELER), 'ICERIDE')

// Liste verilmezse tür denetlenir: sayı bekleyene metin gelmez.
d = sahteDepo({ 'op.ekran.gise.adet': '"yirmi"' })
assert.equal(hafizaOku(d, 'gise.adet', 25), 25)
d = sahteDepo({ 'op.ekran.gise.adet': '50' })
assert.equal(hafizaOku(d, 'gise.adet', 25), 50)
d = sahteDepo({ 'op.ekran.gise.ara': '"34AB"' })
assert.equal(hafizaOku(d, 'gise.ara', ''), '34AB')
// Nesne (özel tarih aralığı) ve null varsayılan.
d = sahteDepo({ 'op.ekran.gise.ozel': '{"bas":"2026-11-01","bit":"2026-11-27"}' })
assert.deepEqual(hafizaOku(d, 'gise.ozel', null), { bas: '2026-11-01', bit: '2026-11-27' })

// Depo hiç yoksa ya da patlıyorsa: varsayılan, hata yok.
assert.equal(hafizaOku(null, 'gise.filtre', 'ICERIDE', SEKMELER), 'ICERIDE')
const patlayan = { getItem() { throw new Error('SecurityError') }, setItem() { throw new Error('quota') } }
assert.equal(hafizaOku(patlayan, 'gise.filtre', 'ICERIDE', SEKMELER), 'ICERIDE')
assert.doesNotThrow(() => hafizaYaz(patlayan, 'gise.filtre', 'CIKAN'))

// Temizle: yalnızca op.ekran.* gider.
d = sahteDepo({ 'op.ekran.a': '1', 'op.ekran.b.c': '"x"', 'sb-oturum': 'tut', 'op.kayit.d': 'tut' })
hafizaTemizle(d)
assert.deepEqual([...d._m.keys()].sort(), ['op.kayit.d', 'sb-oturum'])
assert.doesNotThrow(() => hafizaTemizle(null))

console.log('ekranHafizasi.check: OK')
