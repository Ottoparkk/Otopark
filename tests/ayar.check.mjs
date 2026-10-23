// Otopark ayarları — tek kapı süreleri ve plaka modeli metni.
//
//   node tests/ayar.check.mjs
//
// Gerçek dosyaları içe aktarır; ikisi de içe aktarmasız yazıldı ki Node onları
// doğrudan çalıştırabilsin.
import { tekKapiHatasi } from '../src/features/yonetim/tekKapiAyar.ts'
import { plakaModeliMetni } from '../src/lib/plakaModelleri.ts'

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

const GIRIS = 'Tek kapı: girişten sonra yok sayma 3-60 dakika arasında olmalı.'
const CIKIS = 'Tek kapı: çıkıştan sonra yok sayma 1-60 dakika arasında olmalı.'

// --- 037'deki CHECK'lerin aynası: giriş 3-60, çıkış 1-60 -----------------------
esit('varsayılanlar geçer', tekKapiHatasi('3', '5'), null)
esit('giriş alt sınır', tekKapiHatasi('3', '1'), null)
esit('giriş üst sınır', tekKapiHatasi('60', '60'), null)
esit('giriş 2 reddedilir', tekKapiHatasi('2', '5'), GIRIS)
esit('giriş 61 reddedilir', tekKapiHatasi('61', '5'), GIRIS)
esit('giriş 0 reddedilir', tekKapiHatasi('0', '5'), GIRIS)
esit('giriş boş reddedilir', tekKapiHatasi('', '5'), GIRIS)
esit('çıkış 0 reddedilir', tekKapiHatasi('3', '0'), CIKIS)
esit('çıkış 61 reddedilir', tekKapiHatasi('3', '61'), CIKIS)
esit('çıkış boş reddedilir', tekKapiHatasi('3', ''), CIKIS)
esit('ondalık reddedilir', tekKapiHatasi('3.5', '5'), GIRIS)
esit('işaret reddedilir', tekKapiHatasi('+4', '5'), GIRIS)
esit('boşluklu reddedilir', tekKapiHatasi(' 4', '5'), GIRIS)
esit('ikisi de yanlışsa önce giriş', tekKapiHatasi('1', '0'), GIRIS)

// --- plaka modeli, onay listesinde okunacak metin -----------------------------
esit('boş = varsayılan', plakaModeliMetni(null), 'Varsayılan (Claude Haiku 4.5)')
esit('boş metin = varsayılan', plakaModeliMetni(''), 'Varsayılan (Claude Haiku 4.5)')
esit('bilinen model', plakaModeliMetni('claude-haiku-5-5'), 'Claude Haiku 5.5')
esit('bilinen model 2', plakaModeliMetni('claude-sonnet-5'), 'Claude Sonnet 5')
// Sunucu bilinmeyen değeri varsayılana düşürür; ekran bunu saklamamalı.
esit(
  'bilinmeyen model açıkça söylenir',
  plakaModeliMetni('claude-haiku-9'),
  'claude-haiku-9 (geçersiz — varsayılan kullanılıyor)',
)

console.log(`${gecen} geçti, ${kalan} kaldı`)
if (kalan > 0) process.exit(1)
