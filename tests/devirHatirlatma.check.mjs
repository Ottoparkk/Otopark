// Vardiya sonu hatırlatması (085, sahip 28.11): terminalde "Vardiyan bitti,
// Mehmet geldiyse Devral'a dokunun" bandı ne zaman görünür.
//
//   node tests/devirHatirlatma.check.mjs
//
// Kurallar (İstanbul saati, sabit UTC+3):
//   * Açık vardiyanın kişisinin bitiş saati, vardiya açıldıktan SONRA geçmiş
//     olmalı (sonra açıldıysa devir zaten olmuştur);
//   * bitişin üstünden 3 saatten az geçmiş olmalı;
//   * bitiş yoksa (saat tanımlı değil) hiç görünmez.
//   21:00 → 09:00 gibi gece yarısını geçen vardiyalar doğru günü bulur.
import assert from 'node:assert/strict'
import { devirHatirlatmasi, siradakiPersonel } from '../src/features/terminal/devirHatirlatma.ts'

// İstanbul saatini UTC'ye çevir: 'YYYY-MM-DDTHH:MM' (İstanbul) → Date.
const ist = (s) => new Date(Date.parse(s + ':00Z') - 3 * 3600_000)

// Gündüz vardiyası 09:04'te açıldı, bitiş 21:00.
const gunduz = ist('2026-11-28T09:04').toISOString()
assert.equal(devirHatirlatmasi(gunduz, ist('2026-11-28T20:59'), '21:00'), false, 'bitişten önce yok')
assert.equal(devirHatirlatmasi(gunduz, ist('2026-11-28T21:00'), '21:00'), true, 'bitişte var')
assert.equal(devirHatirlatmasi(gunduz, ist('2026-11-28T23:59'), '21:00:00'), true, 'HH:MM:SS da olur')
assert.equal(devirHatirlatmasi(gunduz, ist('2026-11-29T00:00'), '21:00'), false, '3 saat geçtiyse yok')

// Devir olmuş: vardiya bitişten SONRA açıldı.
const devirli = ist('2026-11-28T21:10').toISOString()
assert.equal(devirHatirlatmasi(devirli, ist('2026-11-28T21:30'), '21:00'), false)

// Gece vardiyası 21:05'te açıldı, bitiş 09:00 (ertesi gün).
const gece = ist('2026-11-28T21:05').toISOString()
assert.equal(devirHatirlatmasi(gece, ist('2026-11-29T02:00'), '09:00'), false, 'gece yarısı sonrası, bitiş gelmedi')
assert.equal(devirHatirlatmasi(gece, ist('2026-11-29T09:20'), '09:00'), true, 'ertesi sabah bitti')
// Gece yarısından hemen önce bitiş (23:30), şimdi 00:10.
const aksam = ist('2026-11-28T15:00').toISOString()
assert.equal(devirHatirlatmasi(aksam, ist('2026-11-29T00:10'), '23:30'), true, 'gece yarısını aşan pencere')

// Bitiş yok / bozuk → hiç.
assert.equal(devirHatirlatmasi(gunduz, ist('2026-11-28T21:30'), null), false)
assert.equal(devirHatirlatmasi(gunduz, ist('2026-11-28T21:30'), 'bozuk'), false)
assert.equal(devirHatirlatmasi('bozuk', ist('2026-11-28T21:30'), '21:00'), false)

// Sıradaki: başlangıcı bitişe eşit olan (dakikaya kadar), çalışan hariç.
const kisiler = [
  { id: 'a', ad_soyad: 'Ahmet', vardiya_baslangic: '09:00:00' },
  { id: 'm', ad_soyad: 'Mehmet', vardiya_baslangic: '21:00:00' },
  { id: 'x', ad_soyad: 'Saatsiz', vardiya_baslangic: null },
]
assert.equal(siradakiPersonel(kisiler, '21:00', 'a')?.ad_soyad, 'Mehmet')
assert.equal(siradakiPersonel(kisiler, '09:00:00', 'm')?.ad_soyad, 'Ahmet')
assert.equal(siradakiPersonel(kisiler, '21:00', 'm'), null, 'çalışan kendisi sıradaki olmaz')
assert.equal(siradakiPersonel(kisiler, '13:00', 'a'), null)
assert.equal(siradakiPersonel(kisiler, null, 'a'), null)

console.log('devirHatirlatma.check: tamam')
