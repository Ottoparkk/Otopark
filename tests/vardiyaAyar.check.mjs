// Vardiya ayarları — Vardiya ekranındaki ayar penceresinin kuralları
// (otomatik açılış saati, açılış nakdi, kapanma eşiği).
//
//   node tests/vardiyaAyar.check.mjs
//
// Gerçek dosyaları içe aktarır. vardiyaAyar.ts çalışma zamanında hiçbir şey
// içe aktarmaz; para yardımcıları ona parametre olarak verilir — burada da
// GERÇEKLERİ veriliyor.
import { parseTLToKurus, kurusToInput } from '../src/lib/money.ts'
import {
  SAAT_SECENEKLERI,
  vardiyaAyarBaslangic,
  vardiyaAyarHatasi,
  vardiyaAyarYamasi,
} from '../src/features/vardiya/vardiyaAyar.ts'

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

const ARACLAR = { parseTLToKurus, kurusToInput }

// ---- 1. Saat seçenekleri: yarım saatlik 48 dilim ----------------------------
esit('saat: 48 seçenek', SAAT_SECENEKLERI.length, 48)
esit('saat: ilk 00:00', SAAT_SECENEKLERI[0], '00:00')
esit('saat: ikinci 00:30', SAAT_SECENEKLERI[1], '00:30')
esit('saat: son 23:30', SAAT_SECENEKLERI[47], '23:30')

// ---- 2. Başlangıç: veritabanındaki satırdan forma ---------------------------
esit(
  'başlangıç: dolu satır',
  vardiyaAyarBaslangic(
    { vardiya_otomatik_saat: '08:00:00', vardiya_acilis_nakit_kurus: 50000, vardiya_esik_saat: 16 },
    ARACLAR,
  ),
  { otoSaat: '08:00', acilisNakit: '500', esik: '16' },
)
// Kolonlar 025/030 ile geldi; eski bir satırda yoksa varsayılanlar — "undefined"
// metni alana asla düşmemeli.
esit(
  'başlangıç: kolonlar yok',
  vardiyaAyarBaslangic({}, ARACLAR),
  { otoSaat: '', acilisNakit: '0', esik: '16' },
)
esit(
  'başlangıç: kuruşlu nakit gruplanmaz (parse geri okuyabilsin)',
  vardiyaAyarBaslangic(
    { vardiya_otomatik_saat: null, vardiya_acilis_nakit_kurus: 123456, vardiya_esik_saat: 24 },
    ARACLAR,
  ),
  { otoSaat: '', acilisNakit: '1234,56', esik: '24' },
)

// ---- 3. Doğrulama: 025'in CHECK'i (4-72) ve okunabilir tutar ---------------
const iyi = { otoSaat: '08:00', acilisNakit: '500', esik: '16' }
esit('hata: geçerli → yok', vardiyaAyarHatasi(iyi, ARACLAR), null)
esit('hata: eşik 4 sınırda geçer', vardiyaAyarHatasi({ ...iyi, esik: '4' }, ARACLAR), null)
esit('hata: eşik 72 sınırda geçer', vardiyaAyarHatasi({ ...iyi, esik: '72' }, ARACLAR), null)
esit(
  'hata: eşik 3',
  vardiyaAyarHatasi({ ...iyi, esik: '3' }, ARACLAR),
  'Vardiya kapanma eşiği 4-72 saat arasında olmalı.',
)
esit(
  'hata: eşik 73',
  vardiyaAyarHatasi({ ...iyi, esik: '73' }, ARACLAR),
  'Vardiya kapanma eşiği 4-72 saat arasında olmalı.',
)
esit(
  'hata: eşik boş',
  vardiyaAyarHatasi({ ...iyi, esik: '' }, ARACLAR),
  'Vardiya kapanma eşiği 4-72 saat arasında olmalı.',
)
esit(
  'hata: okunamayan nakit',
  vardiyaAyarHatasi({ ...iyi, acilisNakit: 'abc' }, ARACLAR),
  'Otomatik açılış nakdi için geçerli bir tutar girin.',
)
// Boş nakit = 0 ₺ (alan otomatik açılış kapalıyken pasif ve boş olabilir).
esit('hata: boş nakit geçer', vardiyaAyarHatasi({ ...iyi, acilisNakit: '' }, ARACLAR), null)
esit(
  'hata: bilinmeyen saat',
  vardiyaAyarHatasi({ ...iyi, otoSaat: '08:15' }, ARACLAR),
  'Otomatik açılış saati listeden seçilmeli.',
)

// ---- 4. Yama: YALNIZCA üç anahtar, tamsayı kuruş, saniyeli saat ------------
esit(
  'yama: dolu',
  vardiyaAyarYamasi(iyi, ARACLAR),
  { vardiya_otomatik_saat: '08:00:00', vardiya_acilis_nakit_kurus: 50000, vardiya_esik_saat: 16 },
)
esit(
  'yama: saat kapalı → null',
  vardiyaAyarYamasi({ ...iyi, otoSaat: '' }, ARACLAR),
  { vardiya_otomatik_saat: null, vardiya_acilis_nakit_kurus: 50000, vardiya_esik_saat: 16 },
)
esit(
  'yama: boş nakit → 0',
  vardiyaAyarYamasi({ ...iyi, acilisNakit: '' }, ARACLAR),
  { vardiya_otomatik_saat: '08:00:00', vardiya_acilis_nakit_kurus: 0, vardiya_esik_saat: 16 },
)
esit(
  'yama: kuruşlu nakit tamsayı kalır',
  vardiyaAyarYamasi({ ...iyi, acilisNakit: '12,50' }, ARACLAR),
  { vardiya_otomatik_saat: '08:00:00', vardiya_acilis_nakit_kurus: 1250, vardiya_esik_saat: 16 },
)
esit(
  'yama: yalnızca üç anahtar',
  Object.keys(vardiyaAyarYamasi(iyi, ARACLAR)).sort(),
  ['vardiya_acilis_nakit_kurus', 'vardiya_esik_saat', 'vardiya_otomatik_saat'],
)

console.log(`${gecen} geçti, ${kalan} kaldı`)
process.exit(kalan === 0 ? 0 : 1)
