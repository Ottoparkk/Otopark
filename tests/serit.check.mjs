// Şerit kararı — kamera-webhook'un "bu olay hangi şeride ait" sorusu.
//
//   node tests/serit.check.mjs
//
// Gerçek dosyayı içe aktarır (supabase/functions/_shared/serit.ts). Bu makinede
// Deno yok; yardımcı bilerek içe aktarmasız yazıldı ki Node onu doğrudan
// çalıştırabilsin.
import { seritKarari } from '../supabase/functions/_shared/serit.ts'

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

const RED_400 = { ok: false, durum: 400, hata: 'yon belirtilmeli: GIRIS veya CIKIS.' }

// --- Ortak (env) anahtarla gelen köprü: davranış 036 öncesiyle AYNI ---------
esit('env: GIRIS', seritKarari(null, 'GIRIS'), { ok: true, yon: 'GIRIS' })
esit('env: CIKIS', seritKarari(null, 'CIKIS'), { ok: true, yon: 'CIKIS' })
esit('env: küçük harf', seritKarari(null, 'giris'), { ok: true, yon: 'GIRIS' })
esit('env: boşluklu', seritKarari(null, ' cikis '), { ok: true, yon: 'CIKIS' })
esit('env: şerit yok', seritKarari(null, null), RED_400)
esit('env: undefined', seritKarari(null, undefined), RED_400)
esit('env: boş metin', seritKarari(null, ''), RED_400)
esit('env: anlamsız', seritKarari(null, 'SAG'), RED_400)

// --- Eşleştirilmiş kamera: şerit SATIRDAN gelir, istekten değil -------------
esit('cihaz: istek şerit vermedi', seritKarari('CIKIS', null), { ok: true, yon: 'CIKIS' })
esit('cihaz: istek boş', seritKarari('GIRIS', ''), { ok: true, yon: 'GIRIS' })
esit('cihaz: aynı şerit', seritKarari('CIKIS', 'cikis'), { ok: true, yon: 'CIKIS' })
esit('cihaz: aynı şerit (GIRIS)', seritKarari('GIRIS', 'GIRIS'), { ok: true, yon: 'GIRIS' })

// ASIL KURAL: çıkışa eşleştirilmiş kamera giriş bileti AÇAMAZ.
const cikisGiris = seritKarari('CIKIS', 'GIRIS')
esit('cihaz: CIKIS kamerası GIRIS diyor → ret', [cikisGiris.ok, cikisGiris.durum], [false, 409])
const girisCikis = seritKarari('GIRIS', 'cikis')
esit('cihaz: GIRIS kamerası CIKIS diyor → ret', [girisCikis.ok, girisCikis.durum], [false, 409])
// Köprü bu reddi durum koduyla DEĞİL bu alanla tanır: sıradan bir 409 (aynı
// plakaya ikinci bilet) arıza değildir, şerit uyuşmazlığı ise her aracı düşürür.
esit('cihaz: şerit reddi makinece tanınır', cikisGiris.kod, 'SERIT_UYUSMAZ')
esit('env: sıradan ret bu alanı taşımaz', seritKarari(null, null).kod, undefined)
esit(
  'cihaz: ret mesajı kameranın KENDİ şeridini söylüyor',
  cikisGiris.ok === false && cikisGiris.hata.includes('CIKIS'),
  true,
)

// Anlamsız bir şerit, eşleştirilmiş kamerada da sessizce yutulmaz.
esit('cihaz: anlamsız istek', seritKarari('GIRIS', 'SAG'), RED_400)

// Satırdaki şerit bozuksa (olmamalı — CHECK kısıtı var) KAPALI kal: tahmin yok.
const bozuk = seritKarari('SAG', 'GIRIS')
esit('cihaz: bozuk satır → ret', [bozuk.ok, bozuk.durum], [false, 409])
const bozuk2 = seritKarari('', null)
esit('cihaz: boş satır şeridi → ret', [bozuk2.ok, bozuk2.durum], [false, 409])

console.log(`${gecen} geçti, ${kalan} kaldı`)
process.exit(kalan === 0 ? 0 : 1)
