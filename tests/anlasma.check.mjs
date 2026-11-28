// Anlaşmalı fiyat (080) — süre, bitiş, çubuk ve "Anlaşma bitti" uyarısı.
//
//   node tests/anlasma.check.mjs
//
// Süre girişten sayılır (bitiş = giriş + saat, sunucudaki bilet_anlasma ile
// aynı). Çubuk girişten bitişe doluluk; süre dolunca %100 ve aşım dakikası.
import assert from 'node:assert/strict'
import {
  anlasmaSaat,
  anlasmaSaatGecerli,
  anlasmaBitis,
  anlasmaDurumu,
  anlasmaBittiUyarisi,
  bitisMetni,
  kalanMetni,
} from '../src/features/gise/anlasma.ts'

const giris = '2026-11-27T10:03:00Z' // 13:03 İstanbul
const dk = 60_000
const t0 = Date.parse(giris)

// Saat / gün → saat; sınırlar sunucudakiyle aynı (1 saat – 90 gün).
assert.equal(anlasmaSaat(3, 'gun'), 72)
assert.equal(anlasmaSaat(5, 'saat'), 5)
assert.equal(anlasmaSaatGecerli(1), true)
assert.equal(anlasmaSaatGecerli(2160), true)
assert.equal(anlasmaSaatGecerli(0), false)
assert.equal(anlasmaSaatGecerli(2161), false)
assert.equal(anlasmaSaatGecerli(1.5), false)
assert.equal(anlasmaSaatGecerli(Number.NaN), false)

// Bitiş girişten sayılır.
assert.equal(anlasmaBitis(giris, 72).toISOString(), '2026-11-30T10:03:00.000Z')
// Ekranda İstanbul saatiyle, cihazın saat diliminden bağımsız.
assert.equal(bitisMetni(anlasmaBitis(giris, 72)), '30.11 13:03')

const bitis = anlasmaBitis(giris, 72).toISOString()

// Başta %0, yarıda %50, kalan süre.
let d = anlasmaDurumu(giris, bitis, t0)
assert.deepEqual(d, { doldu: false, yuzde: 0, kalanDk: 72 * 60, asimDk: 0 })
d = anlasmaDurumu(giris, bitis, t0 + 36 * 60 * dk)
assert.equal(d.yuzde, 50)
assert.equal(d.kalanDk, 36 * 60)
assert.equal(d.doldu, false)

// Tam bitişte doldu, aşım 0.
d = anlasmaDurumu(giris, bitis, Date.parse(bitis))
assert.deepEqual(d, { doldu: true, yuzde: 100, kalanDk: 0, asimDk: 0 })

// Bitişten 2 sa 10 dk sonra: %100, aşım 130 dk.
d = anlasmaDurumu(giris, bitis, Date.parse(bitis) + 130 * dk)
assert.deepEqual(d, { doldu: true, yuzde: 100, kalanDk: 0, asimDk: 130 })

// Bir saatlik anlaşma, 30 sn kalmış: kalan yukarı yuvarlanır (1 dk), dolmadı.
const b1 = anlasmaBitis(giris, 1).toISOString()
d = anlasmaDurumu(giris, b1, Date.parse(b1) - 30_000)
assert.equal(d.doldu, false)
assert.equal(d.kalanDk, 1)

// Kalan metni: biçimleyici dışarıdan (uygulamada formatSure).
const fs = (n) => `${n} dk`
assert.equal(kalanMetni(anlasmaDurumu(giris, bitis, t0 + 60 * dk), fs), `${72 * 60 - 60} dk kaldı`)
assert.equal(kalanMetni(anlasmaDurumu(giris, bitis, Date.parse(bitis) + 130 * dk), fs), '130 dk aşıldı')

// "Anlaşma bitti" uyarısı: süre dolmuş ve fazla süre eklenmemişse.
const sonra = Date.parse(bitis) + dk
assert.equal(anlasmaBittiUyarisi({ anlasma_bitis: bitis, anlasma_fazla_at: null }, sonra), true)
assert.equal(anlasmaBittiUyarisi({ anlasma_bitis: bitis, anlasma_fazla_at: bitis }, sonra), false)
assert.equal(anlasmaBittiUyarisi({ anlasma_bitis: bitis, anlasma_fazla_at: null }, t0), false)
assert.equal(anlasmaBittiUyarisi({ anlasma_bitis: null, anlasma_fazla_at: null }, sonra), false)
assert.equal(anlasmaBittiUyarisi({}, sonra), false)

console.log('anlasma.check: hepsi geçti')
