// Şerit kararı — kamera-webhook'un "bu olay hangi şeride ait" sorusu.
//
//   node tests/serit.check.mjs
//
// Gerçek dosyayı içe aktarır (supabase/functions/_shared/serit.ts). Bu makinede
// Deno yok; yardımcı bilerek içe aktarmasız yazıldı ki Node onu doğrudan
// çalıştırabilsin.
import {
  hamFotosuz,
  okunamadiKaydedilir,
  seritKarari,
  sonGonderimMi,
  tekKapiCevabi,
} from '../supabase/functions/_shared/serit.ts'

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

const RED_400 = { ok: false, durum: 400, hata: 'yon belirtilmeli: GIRIS, CIKIS veya ORTAK.' }

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

// --- Tek kapı (037): ORTAK üçüncü bir şerittir, bir "ikisi de olur" DEĞİL ----
// Giriş mi çıkış mı olduğuna sunucu bilet durumundan karar verir; bu dosya
// yalnızca olayın o karara GİDİP GİTMEYECEĞİNİ söyler.
esit('env: ORTAK', seritKarari(null, 'ortak'), { ok: true, yon: 'ORTAK' })
esit('cihaz: ORTAK, istek şerit vermedi', seritKarari('ORTAK', null), { ok: true, yon: 'ORTAK' })
esit('cihaz: ORTAK, aynı şerit', seritKarari('ORTAK', ' ortak '), { ok: true, yon: 'ORTAK' })

// Tek kapıya eşleştirilmiş kamera GIRIS diyemez: derse her araca bilet açar,
// yani ödeyip çıkan araç yeniden içeri yazılır — bu modun kapattığı hata.
const ortakGiris = seritKarari('ORTAK', 'GIRIS')
esit(
  'cihaz: ORTAK kamerası GIRIS diyor → ret',
  [ortakGiris.ok, ortakGiris.durum, ortakGiris.kod],
  [false, 409, 'SERIT_UYUSMAZ'],
)
const ortakCikis = seritKarari('ORTAK', 'CIKIS')
esit(
  'cihaz: ORTAK kamerası CIKIS diyor → ret',
  [ortakCikis.ok, ortakCikis.durum, ortakCikis.kod],
  [false, 409, 'SERIT_UYUSMAZ'],
)
// Tersi de: tek şeritli kamera kendini tek kapı ilan edemez.
const girisOrtak = seritKarari('GIRIS', 'ORTAK')
esit(
  'cihaz: GIRIS kamerası ORTAK diyor → ret',
  [girisOrtak.ok, girisOrtak.durum, girisOrtak.kod],
  [false, 409, 'SERIT_UYUSMAZ'],
)
esit(
  'cihaz: ret mesajı ORTAK şeridini söylüyor',
  ortakGiris.ok === false && ortakGiris.hata.includes('ORTAK'),
  true,
)

// --- Tek kapı kararının CEVABI ------------------------------------------------
// kamera_tek_kapi dört karardan birini döndürür. Webhook bunun dışındaki her
// şeyi (boş cevap, tanımadığı karar) "işlendi" diye 200 ile GEÇİŞTİRMEMELİ:
// köprü 200 görünce aracı gönderilmiş sayar ve bir daha denemez — yani araç
// hiçbir iz bırakmadan kaybolur. Tanınmayan cevap hatadır, köprü yeniden dener.
const B = '11111111-2222-3333-4444-555555555555'
esit(
  'cevap: GIRIS',
  tekKapiCevabi({ karar: 'GIRIS', bilet_id: B, sebep: 'YENI_ARAC' }),
  { ok: true, karar: 'GIRIS', sebep: 'YENI_ARAC', biletId: B },
)
esit(
  'cevap: CIKIS',
  tekKapiCevabi({ karar: 'CIKIS', bilet_id: B, sebep: 'ACIK_BILET' }),
  { ok: true, karar: 'CIKIS', sebep: 'ACIK_BILET', biletId: B },
)
esit(
  'cevap: YOKSAY bilet taşımayabilir',
  tekKapiCevabi({ karar: 'YOKSAY', bilet_id: null, sebep: 'YENI_CIKIS' }),
  { ok: true, karar: 'YOKSAY', sebep: 'YENI_CIKIS', biletId: null },
)
esit(
  'cevap: ISTISNA',
  tekKapiCevabi({ karar: 'ISTISNA', bilet_id: null, sebep: 'BENZER_ACIK' }),
  { ok: true, karar: 'ISTISNA', sebep: 'BENZER_ACIK', biletId: null },
)
esit('cevap: sebep yoksa null', tekKapiCevabi({ karar: 'YOKSAY' }), {
  ok: true,
  karar: 'YOKSAY',
  sebep: null,
  biletId: null,
})
for (const bozuk of [null, undefined, {}, 'GIRIS', [], { karar: 'ACIK' }, { karar: '' }, { karar: 7 }]) {
  esit(`cevap: tanınmayan → ret (${JSON.stringify(bozuk)})`, tekKapiCevabi(bozuk), { ok: false })
}
// GIRIS ve CIKIS bir bilete İŞARET ETMEK zorunda; etmiyorsa cevap bozuktur.
esit('cevap: biletsiz GIRIS → ret', tekKapiCevabi({ karar: 'GIRIS', bilet_id: null }), { ok: false })
esit('cevap: biletsiz CIKIS → ret', tekKapiCevabi({ karar: 'CIKIS' }), { ok: false })
esit('cevap: bilet metin değilse → ret', tekKapiCevabi({ karar: 'GIRIS', bilet_id: 5 }), { ok: false })

// --- Okunamayan plaka (039) ---------------------------------------------------
// Bir aracın plakası okunamadığında "çözülmemiş kayıt" yazılır — ama yalnızca
// giriş ve tek kapıda (çıkışta para zaten insanda), yalnızca bir fotoğraf
// gerçekten okunduysa, ve ASLA model "görüntüde araç yok" dediyse: köprü her
// araç gittikten sonra boş şeridin fotoğrafını da gönderir ve her biri
// "okunamadı" kaydı olsaydı liste boş yollarla dolardı.
esit('okunamadı: giriş', okunamadiKaydedilir('GIRIS', true, false), true)
esit('okunamadı: tek kapı', okunamadiKaydedilir('ORTAK', true, false), true)
esit('okunamadı: çıkış yazmaz', okunamadiKaydedilir('CIKIS', true, false), false)
esit('okunamadı: boş şerit yazmaz', okunamadiKaydedilir('GIRIS', true, true), false)
esit('okunamadı: tek kapıda boş şerit yazmaz', okunamadiKaydedilir('ORTAK', true, true), false)
esit('okunamadı: fotoğraf okunmadıysa yazmaz', okunamadiKaydedilir('GIRIS', false, false), false)

// Köprünün SON denemesi (1.2.1): yalnızca tam olarak "1". Okuma servisi
// çöktüğünde araç başına kayıt yalnızca o denemede yazılır — daha erken
// yazılan kayıt, aynı islem_id'li başarılı bir yeniden denemeyi tek kapıda
// "ISTISNA TEKRAR" diye keserdi.
esit('son gönderim: "1"', sonGonderimMi('1'), true)
esit('son gönderim: başlık yok', sonGonderimMi(null), false)
esit('son gönderim: "0"', sonGonderimMi('0'), false)
esit('son gönderim: boş', sonGonderimMi(''), false)
esit('son gönderim: "true" değil', sonGonderimMi('true'), false)

// Saklanan ham gövde fotoğrafı TAŞIMAZ: köprünün gövdesi `foto_base64` içerir
// ve kayıt başına yüzlerce KB olurdu. Girdi değiştirilmez (webhook onu okumaya
// devam ediyor).
const govde = { yon: 'GIRIS', cihaz: 'k1', foto_base64: 'QUJD' }
esit('ham: fotoğraf çıkar', hamFotosuz(govde), { yon: 'GIRIS', cihaz: 'k1' })
esit('ham: girdi değişmez', govde.foto_base64, 'QUJD')
esit('ham: fotoğrafsız gövde aynen', hamFotosuz({ plaka: '34AB12' }), { plaka: '34AB12' })

console.log(`${gecen} geçti, ${kalan} kaldı`)
process.exit(kalan === 0 ? 0 : 1)
