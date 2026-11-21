// Şerit kararı — kamera-webhook'un "bu olay hangi şeride ait" sorusu.
//
//   node tests/serit.check.mjs
//
// Gerçek dosyayı içe aktarır (supabase/functions/_shared/serit.ts). Bu makinede
// Deno yok; yardımcı bilerek içe aktarmasız yazıldı ki Node onu doğrudan
// çalıştırabilsin.
import { readFileSync } from 'node:fs'
import {
  GECICI_HATA,
  KAMERA_OKUMA_KAYNAGI,
  KANIT_FOTO_EN_COK_BAYT,
  KANIT_FOTO_KOVA,
  KOPRU_OKUMA_SAGLAYICI,
  OKUMA_DAKIKA_SINIRI,
  OKUMA_GUN_SINIRI,
  SURE_DOLDU,
  cihazKimligi,
  fotoYuklemeTamam,
  hamFotosuz,
  hareketIpucu,
  KAMERA_KAPALI,
  kalpBilgisi,
  kapaliCevabi,
  kartYazilamadiDurumu,
  kameraFotoYolu,
  kameraGirisiKarari,
  kameraOkumaLogu,
  kanitFotoCoz,
  koprudenOkunamadi,
  okumaHatasiKaydedilir,
  okumaSiniriKarari,
  okunamadiKaydedilir,
  reddedilenCevabi,
  rpcHataDurumu,
  seritKarari,
  sonGonderimMi,
  sureSinirli,
  tekKapiCevabi,
  tekKapiFotoGerekli,
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

// --- Geçici veritabanı hatası: 503, köprü aracı YENİDEN dener -----------------
// Köprü yalnızca 5xx ve 429'u yeniden dener; diğer her 4xx kesindir ve araç
// bırakılır. Eskiden geçici bir veritabanı sorunu (zaman aşımı, kilit, bağlantı,
// ağ) da 409 dönüyordu — yani araç hiçbir iz bırakmadan kayboluyordu. Yeniden
// denemek güvenli: köprü her denemede aynı islem_id'yi gönderir ve üç RPC de
// aynı islem_id'ye ilk cevabı verir (ikinci bilet, ikinci kayıt açılmaz).
//
// 409 yalnızca gerçek bir RED: üç RPC'nin bütün iş retleri düz `raise exception`
// (SQLSTATE P0001), bozuk veri 22xxx, bütünlük 23xxx (ör. aynı plakaya ikinci
// açık bilet: 23505). Tekrar denemek aynı reddi alırdı.
for (const kod of ['P0001', '23505', '23503', '23514', '22P02', '22003']) {
  esit(`rpc: ret ${kod} → 409`, rpcHataDurumu(kod), 409)
}
// Geri kalan her şey geçicidir ya da ne olduğu bilinmez → yeniden dene. Bilinmeyen
// biçim bilerek 503'e düşer: fazladan deneme en çok üç ücretli okuma demektir,
// yanlış bir 409 ise kaybolan araç.
for (const kod of [
  '57014', // statement timeout
  '55P03', // kilit alınamadı
  '40001', // serileştirme hatası
  '40P01', // deadlock
  '08006', // bağlantı koptu
  '08001', // bağlanılamadı
  '53300', // çok fazla bağlantı
  'PGRST202', // PostgREST: fonksiyon şema önbelleğinde yok (migration sonrası)
  'PGRST301', // PostgREST: JWT
  'XX000', // iç hata
  'P0002', // yalnızca P0001 iş reddidir
  '21000', // 21 sınıfı: 22/23 değil
  '', // supabase-js ağ hatası: code ""
  null,
  undefined, // JSON olmayan hata gövdesi: code hiç yok
]) {
  esit(`rpc: geçici ${JSON.stringify(kod)} → 503`, rpcHataDurumu(kod), 503)
}
// Yalnızca tam beş karakterlik SQLSTATE sayılır; önek benzerliği yetmez.
esit('rpc: "P00011" → 503', rpcHataDurumu('P00011'), 503)
esit('rpc: "2350" → 503', rpcHataDurumu('2350'), 503)

// Ayar okunamadıysa bu "kamera girişi kapalı" DEĞİLDİR. Eskiden okuma hatası
// yok sayılıyor, ayar boş kalıyor ve 403 dönüyordu: köprü aracı bırakıyor ve
// `durum` saatlerce KAMERA GİRİŞİ KAPALI gösteriyordu. 403 yalnızca BAŞARILI
// bir okuma kamera_aktif = false dediğinde.
const ACIK = { kamera_aktif: true, plaka_saglayici: 'ANTHROPIC', plaka_model: null }
esit('ayar: açık → geçer, aynı satırla', kameraGirisiKarari(ACIK, null), { ok: true, ayar: ACIK })
const KAPALI_403 = { ok: false, durum: 403, hata: 'Kamera girişi kapalı.' }
esit('ayar: kapalı → 403', kameraGirisiKarari({ kamera_aktif: false }, null), KAPALI_403)
esit('ayar: satır yok, hata yok → 403 (eski davranış)', kameraGirisiKarari(null, null), KAPALI_403)
const GECICI_503 = { ok: false, durum: 503, hata: GECICI_HATA }
esit(
  'ayar: okuma hatası → 503',
  kameraGirisiKarari(null, { code: '57014', message: 'canceling statement due to statement timeout' }),
  GECICI_503,
)
esit(
  'ayar: ağ hatası (boş kod) → 503',
  kameraGirisiKarari(null, { code: '', message: 'TypeError: fetch failed' }),
  GECICI_503,
)
esit('ayar: hata varsa veri ne derse desin → 503', kameraGirisiKarari(ACIK, { message: 'x' }), GECICI_503)
esit('ayar: geçici mesaj "kapalı" demez', GECICI_HATA.includes('kapalı'), false)

// Eşleştirilmiş kameranın kimliği veritabanından okunur (036) — gerçek kurulumun
// HER isteğindeki İLK sorgu. Okuma başarısızsa eskiden 401 dönüyordu: köprü
// aracı bırakıyor ve `durum` kamerayı "uygulamadan kaldırılmış" gösteriyordu.
// Artık 503 (yine erişim YOK — kapalı kalır); yanlış ya da bilinmeyen anahtar
// eskisi gibi 401.
const C = 'cccccccc-1111-2222-3333-444444444444'
esit('kimlik: eşleşen satır', cihazKimligi([{ id: C, yon: 'ORTAK' }], null), {
  ok: true,
  cihazId: C,
  cihazYon: 'ORTAK',
})
esit('kimlik: şeritsiz satır → boş şerit (seritKarari kapalı reddeder)', cihazKimligi([{ id: C, yon: null }], null), {
  ok: true,
  cihazId: C,
  cihazYon: '',
})
esit('kimlik: eşleşme yok → 401', cihazKimligi([], null), { ok: false, durum: 401 })
esit('kimlik: veri yok → 401', cihazKimligi(null, null), { ok: false, durum: 401 })
esit('kimlik: id\'siz satır → 401', cihazKimligi([{}], null), { ok: false, durum: 401 })
esit('kimlik: boş id → 401', cihazKimligi([{ id: '' }], null), { ok: false, durum: 401 })
esit('kimlik: okuma hatası → 503', cihazKimligi(null, { code: '57014', message: 't' }), { ok: false, durum: 503 })
esit('kimlik: ağ hatası (boş kod) → 503', cihazKimligi(null, { code: '', message: 'f' }), { ok: false, durum: 503 })
esit(
  'kimlik: hata varsa satır ne derse desin → 503',
  cihazKimligi([{ id: C, yon: 'GIRIS' }], { message: 'x' }),
  { ok: false, durum: 503 },
)

// --- Ücretli okuma sınırı (040) ----------------------------------------------
// Kameradan gelen her fotoğraf parayla okunur. Eski sınır yalnızca BİLETLERİ
// sayıyordu; okumaların çoğu bilet açmaz (boş şerit, okunamayan plaka, okuma
// hatası, her çıkış, her yeniden deneme). Artık okumadan ÖNCE son 1 dakikanın
// ve 24 saatin kamera okumaları sayılır — bütün şeritler birlikte.
//
// Sayılar sahibin kararı (2026-10-24): değiştirmek bilinçli olsun diye burada
// sabitlenir.
esit('sınır: dakikada 20', OKUMA_DAKIKA_SINIRI, 20)
esit('sınır: günde 1500', OKUMA_GUN_SINIRI, 1500)
// Sayımın süzgeci ile satırın etiketi AYNI sabittir; ayrışırsa sınır hiçbir
// satırı görmez.
esit('sınır: etiket KAMERA (kaynak enum değeri)', KAMERA_OKUMA_KAYNAGI, 'KAMERA')

const sayim = (count, error = null) => ({ count, error })
const SINIR_429 = { ok: false, durum: 429, hata: 'Kamera okuma sınırı aşıldı.' }
const SAYILDI = { ok: true, sayilamadi: false }
esit('sınır: hiç okuma yok → oku', okumaSiniriKarari(sayim(0), sayim(0)), SAYILDI)
esit('sınır: 19 / 1499 → oku', okumaSiniriKarari(sayim(19), sayim(1499)), SAYILDI)
// Kenar: sayılan satır sayısı SINIRA ulaştıysa bu okuma sınırın üstündedir —
// "günde 1500" 1500 okumaya izin verir, 1501'inciye vermez.
esit('sınır: dakikada 20 dolmuş → 429', okumaSiniriKarari(sayim(20), sayim(20)), SINIR_429)
esit('sınır: günde 1500 dolmuş → 429', okumaSiniriKarari(sayim(0), sayim(1500)), SINIR_429)
esit('sınır: ikisi de aşılmış → 429', okumaSiniriKarari(sayim(31), sayim(1800)), SINIR_429)
// Bir sayım başarısız ama öbürü zaten sınırda: bilinen yeter, okunmaz.
const HATA = { code: '57014', message: 'canceling statement due to statement timeout' }
esit('sınır: dakika sayılamadı, gün dolu → 429', okumaSiniriKarari(sayim(null, HATA), sayim(1500)), SINIR_429)
esit('sınır: gün sayılamadı, dakika dolu → 429', okumaSiniriKarari(sayim(20), sayim(null, HATA)), SINIR_429)
// Sayım başarısızsa araç YİNE okunur (sahibin kararı, 2026-10-27): sınır o tek
// istekte uygulanmaz ve bu günlüğe yazılır. Tersi — 503 — sayım kalıcı olarak
// bozulduğunda (ör. webhook 040'tan önce yayınlanırsa) her kamera aracını
// düşürürdü, hem de uyarısız. Bilet sınırı da hep böyle davrandı.
const SAYILAMADI = { ok: true, sayilamadi: true }
esit('sınır: dakika sayılamadı → yine oku, işaretli', okumaSiniriKarari(sayim(null, HATA), sayim(3)), SAYILAMADI)
esit('sınır: gün sayılamadı → yine oku, işaretli', okumaSiniriKarari(sayim(3), sayim(null, HATA)), SAYILAMADI)
esit('sınır: ikisi de sayılamadı → yine oku, işaretli', okumaSiniriKarari(sayim(null, HATA), sayim(null, HATA)), SAYILAMADI)
esit(
  'sınır: ağ hatası (boş kod) → yine oku, işaretli',
  okumaSiniriKarari(sayim(null, { code: '', message: 'TypeError: fetch failed' }), sayim(0)),
  SAYILAMADI,
)
// Hata yok ama sayı da yok: bilinmiyor demektir, sıfır DEĞİL.
esit('sınır: sayı gelmedi → işaretli', okumaSiniriKarari(sayim(null), sayim(0)), SAYILAMADI)
esit('sınır: sayı gelmedi (undefined) → işaretli', okumaSiniriKarari(sayim(undefined), sayim(0)), SAYILAMADI)
// Hata varken yanında bir sayı da gelse güvenilmez.
esit('sınır: hatalı sayıma güvenilmez', okumaSiniriKarari(sayim(25, HATA), sayim(0)), SAYILAMADI)

// Webhook'un okuma günlüğüne yazdığı HER satır etiketlenir: etiketsiz bir
// satır sınırın hiç görmediği bir okuma olurdu.
const satir = { saglayici: 'claude-haiku-5-5', guven: 0.91, onerilen: '34ABC123' }
esit('günlük: KAMERA etiketi eklenir', kameraOkumaLogu(satir), { ...satir, kaynak: 'KAMERA' })
esit('günlük: girdi değişmez', Object.prototype.hasOwnProperty.call(satir, 'kaynak'), false)
esit(
  'günlük: girdideki kaynak etiketi ezemez',
  kameraOkumaLogu({ saglayici: 'x', kaynak: 'MOBIL' }).kaynak,
  'KAMERA',
)

// Bu makinede Deno yok, webhook çalıştırılamıyor. O yüzden kaynağına bakılır:
// okuma günlüğüne yazan her `insert` bu yardımcıdan geçmeli. İleride eklenen
// etiketsiz bir yazım, sınırın sessizce delinmesi demektir.
const webhook = readFileSync(
  new URL('../supabase/functions/kamera-webhook/index.ts', import.meta.url),
  'utf8',
)
const yazimlar = [...webhook.matchAll(/\.from\(\s*'plaka_okuma_log'\s*\)\s*\.insert\(\s*([A-Za-z_]*)/g)]
// Üç yer: okundu, okuma hatası, ve (köprü 1.3.0) köprünün "okuyamadım" olayı —
// sonuncusu ücretli okuma değil ama aynı sınıra tabi olsun diye satır yazar.
esit('webhook: okuma günlüğüne üç yerde yazılır (okundu / okuma hatası / köprü okunamadı)', yazimlar.length, 3)
esit(
  'webhook: her yazım etiketli (kameraOkumaLogu)',
  yazimlar.map((m) => m[1]),
  yazimlar.map(() => 'kameraOkumaLogu'),
)
// Sayım da aynı sabitle süzer — 'KAMERA' metni elle yazılmaz.
const sayimlar = [
  ...webhook.matchAll(
    /\.from\(\s*'plaka_okuma_log'\s*\)\s*\.select\([^)]*\)\s*\.eq\(\s*'kaynak'\s*,\s*([^)\s]+)\s*\)/g,
  ),
]
esit('webhook: okumalar iki pencerede sayılır (1 dk / 24 sa)', sayimlar.length, 2)
esit(
  'webhook: sayım etiket sabitiyle süzer',
  sayimlar.map((m) => m[1]),
  sayimlar.map(() => 'KAMERA_OKUMA_KAYNAGI'),
)

// --- Kamera fotoğrafı (042) -------------------------------------------------
// Köprü 1.2.3 okuduğu plaka kesitinin sıkıştırılmış bir kopyasını da gönderir
// (`foto_kanit_base64`, ≤100 KB). Webhook karardan SONRA onu
// `kamera/<islem_id>.jpg` olarak yükler ve kamera_foto_bagla ile bağlar.

const KIMLIK = 'abcdef12-3456-4789-abcd-ef1234567890'
esit('foto: sınır 100 KB — köprüyle aynı sayı', KANIT_FOTO_EN_COK_BAYT, 102400)
esit('foto: kova', KANIT_FOTO_KOVA, 'plaka-foto')

// Yol olayın kimliğinden türer; veritabanı da `'kamera/' || p_islem_id::text ||
// '.jpg'` ile karşılaştırır (uuid::text küçük harflidir).
esit('foto: yol', kameraFotoYolu(KIMLIK), `kamera/${KIMLIK}.jpg`)
esit('foto: büyük harfli kimlik küçültülür', kameraFotoYolu(KIMLIK.toUpperCase()), `kamera/${KIMLIK}.jpg`)
esit('foto: boşluklu kimlik', kameraFotoYolu(` ${KIMLIK} `), `kamera/${KIMLIK}.jpg`)
esit(
  'foto: türetilmiş kimlik (deriveIslemId, sürüm 5)',
  kameraFotoYolu('9b2c1f3e-0a4d-5e6f-8a7b-1c2d3e4f5a6b'),
  'kamera/9b2c1f3e-0a4d-5e6f-8a7b-1c2d3e4f5a6b.jpg',
)
esit('foto: kimlik yok', kameraFotoYolu(null), null)
esit('foto: kimlik undefined', kameraFotoYolu(undefined), null)
esit('foto: kimlik boş', kameraFotoYolu(''), null)
esit('foto: uuid değil', kameraFotoYolu('abc'), null)
esit('foto: üst klasöre çıkma', kameraFotoYolu(`../${KIMLIK}`), null)
esit('foto: alt klasör', kameraFotoYolu(`${KIMLIK}/x`), null)
esit('foto: tiresiz uuid', kameraFotoYolu(KIMLIK.replaceAll('-', '')), null)

const JPEG_BAS = [0xff, 0xd8, 0xff, 0xe0]
const b64 = (bayt) => Buffer.from(bayt).toString('base64')
const kucukJpeg = b64([...JPEG_BAS, 1, 2, 3, 4, 0xff, 0xd9])
const kucuk = kanitFotoCoz(kucukJpeg)
esit('kanıt: geçerli JPEG çözülür', kucuk ? Array.from(kucuk) : null, [...JPEG_BAS, 1, 2, 3, 4, 0xff, 0xd9])
esit('kanıt: Uint8Array döner', kucuk instanceof Uint8Array, true)
esit('kanıt: data: öneki soyulur', kanitFotoCoz(`data:image/jpeg;base64,${kucukJpeg}`)?.length, 10)
esit('kanıt: yok', kanitFotoCoz(null), null)
esit('kanıt: undefined', kanitFotoCoz(undefined), null)
esit('kanıt: boş', kanitFotoCoz(''), null)
esit('kanıt: metin değil', kanitFotoCoz(42), null)
esit('kanıt: PNG reddedilir', kanitFotoCoz(b64([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])), null)
esit('kanıt: bozuk base64', kanitFotoCoz('!!!!'), null)
esit('kanıt: eksik dolgu', kanitFotoCoz(kucukJpeg.slice(0, -1)), null)
esit('kanıt: çok kısa', kanitFotoCoz(b64([0xff, 0xd8])), null)
const tamSinir = new Uint8Array(102400)
tamSinir.set(JPEG_BAS)
esit('kanıt: tam 100 KB kabul', kanitFotoCoz(Buffer.from(tamSinir).toString('base64'))?.length, 102400)
const birFazla = new Uint8Array(102401)
birFazla.set(JPEG_BAS)
esit('kanıt: 100 KB + 1 bayt reddedilir', kanitFotoCoz(Buffer.from(birFazla).toString('base64')), null)

// Okuma hatası kaydı yalnızca köprünün SON denemesinde ve giriş / tek kapıda
// yazılır (039) — fotoğraf da yalnızca o zaman: kayıt yoksa bağlanacak yer yok.
esit('okuma hatası: giriş, son deneme', okumaHatasiKaydedilir('GIRIS', true), true)
esit('okuma hatası: tek kapı, son deneme', okumaHatasiKaydedilir('ORTAK', true), true)
esit('okuma hatası: çıkış, son deneme', okumaHatasiKaydedilir('CIKIS', true), false)
esit('okuma hatası: giriş, ara deneme', okumaHatasiKaydedilir('GIRIS', false), false)
esit('okuma hatası: tek kapı, ara deneme', okumaHatasiKaydedilir('ORTAK', false), false)

// Tek kapıda "yok say" hiçbir satır yazmaz: fotoğrafı yüklenmez.
for (const [karar, beklenen] of [
  ['GIRIS', true],
  ['CIKIS', true],
  ['ISTISNA', true],
  ['YOKSAY', false],
]) {
  esit(`tek kapı fotoğrafı: ${karar}`, tekKapiFotoGerekli(karar), beklenen)
}

// "Zaten var" = aynı olayın yeniden denemesi; dosya yerinde, bağlamaya devam.
// Kurulu storage-js (2.112.3) hatayı StorageApiError(status, statusCode, code)
// olarak verir; eski API 400 + gövdede statusCode '409', yenisi 409 döner.
esit('yükleme: hata yok', fotoYuklemeTamam(null), true)
esit('yükleme: undefined', fotoYuklemeTamam(undefined), true)
esit(
  'yükleme: zaten var (400 + statusCode 409)',
  fotoYuklemeTamam({ status: 400, statusCode: '409', message: 'The resource already exists' }),
  true,
)
esit('yükleme: zaten var (409)', fotoYuklemeTamam({ status: 409, statusCode: '409' }), true)
esit('yükleme: zaten var (code Duplicate)', fotoYuklemeTamam({ status: 400, statusCode: '400', code: 'Duplicate' }), true)
esit('yükleme: yetki reddi', fotoYuklemeTamam({ status: 403, statusCode: '403', message: 'row-level security' }), false)
esit('yükleme: boyut', fotoYuklemeTamam({ status: 413, statusCode: '413' }), false)
esit('yükleme: ağ hatası', fotoYuklemeTamam({ message: 'fetch failed' }), false)
esit('yükleme: metin hata', fotoYuklemeTamam('x'), false)

// Yükleme süresi sınırlı: yavaş depolama aracın cevabını geciktirmesin.
esit('süre: zamanında gelen değer', await sureSinirli(Promise.resolve(7), 50), 7)
esit(
  'süre: geç kalan',
  (await sureSinirli(new Promise((r) => setTimeout(() => r(1), 200)), 20)) === SURE_DOLDU,
  true,
)
esit(
  'süre: hata geçirilir',
  await sureSinirli(Promise.reject(new Error('x')), 50).catch((e) => e.message),
  'x',
)

// Kanıt kopyası da kayıtlarda saklanmaz (039'un dersi: her satır yüzlerce KB).
esit(
  'ham: kanıt kopyası da çıkarılır',
  hamFotosuz({ cihaz: 'k', foto_base64: 'A', foto_kanit_base64: 'B' }),
  { cihaz: 'k' },
)

// Kaynağa bakış: depoya TEK yerden, sabit kovaya, üzerine yazmadan yüklenir;
// bağlama TEK yerden yapılır ve altı karar yolunun hepsinde çağrılır
// (okunamadı, okuma hatası, tek kapı, giriş, çıkış; 071: reddedilen araç kartı).
const yuklemeler = [...webhook.matchAll(/\.storage\s*\.from\(\s*([A-Z_]+)\s*\)\s*\.upload\(([^)]*)\)/g)]
esit('webhook: depoya tek yerden erişilir', (webhook.match(/\.storage\b/g) ?? []).length, 1)
esit('webhook: yükleme kova sabitiyle', yuklemeler.map((m) => m[1]), ['KANIT_FOTO_KOVA'])
esit('webhook: üzerine yazmaz (upsert: false)', yuklemeler.map((m) => /upsert:\s*false/.test(m[2])), [true])
esit('webhook: kamera_foto_bagla tek yerden', (webhook.match(/'kamera_foto_bagla'/g) ?? []).length, 1)
esit('webhook: fotoğraf altı karar yolunda bağlanır', (webhook.match(/await kanitFotosunuBagla\(/g) ?? []).length, 6)

// --- Köprü 1.3.0: plakayı köprü okur; emin değilse "okunamadı" der ----------
// Köprü artık fotoğrafı okutmaz (foto_base64 göndermez), plakayı kendi okur.
// Emin olmadığı aracı `okunamadi: true` ile bildirir: ücretli okuma YAPILMADAN
// çözülmemiş kayıt (kamera_okunamadi) + saklanan fotoğraf. Kural tek yerde.
const YOK = { ok: true, okunamadi: false }
esit('köprü okunamadı: alan yok', koprudenOkunamadi({ plaka: '34ABC123' }), YOK)
esit('köprü okunamadı: false', koprudenOkunamadi({ okunamadi: false }), YOK)
esit('köprü okunamadı: null', koprudenOkunamadi({ okunamadi: null }), YOK)
// Yalnızca gerçek true: "true" metni ya da 1 bir bayrak değildir.
esit('köprü okunamadı: "true" metni değil', koprudenOkunamadi({ okunamadi: 'true' }), YOK)
esit('köprü okunamadı: 1 değil', koprudenOkunamadi({ okunamadi: 1 }), YOK)
esit(
  'köprü okunamadı: tahmin ve güven taşır',
  koprudenOkunamadi({ okunamadi: true, tahmin: ' 35AEU362 ', guven: 0.75 }),
  { ok: true, okunamadi: true, tahmin: '35AEU362', guven: 0.75 },
)
esit(
  'köprü okunamadı: tahminsiz',
  koprudenOkunamadi({ okunamadi: true }),
  { ok: true, okunamadi: true, tahmin: null, guven: null },
)
esit(
  'köprü okunamadı: boş tahmin = yok',
  koprudenOkunamadi({ okunamadi: true, tahmin: '   ' }),
  { ok: true, okunamadi: true, tahmin: null, guven: null },
)
// Uzun tahmin kırpılır (kayıt 32 karakter tutar), aracı düşürmez.
esit(
  'köprü okunamadı: uzun tahmin kırpılır',
  koprudenOkunamadi({ okunamadi: true, tahmin: 'A'.repeat(40) }).tahmin,
  'A'.repeat(32),
)
// Güven 0..1 dışıysa ya da sayı değilse YOK sayılır (veritabanı 0..1 ister).
for (const g of [-0.1, 1.1, Number.NaN, Number.POSITIVE_INFINITY, '0.9', null]) {
  esit(`köprü okunamadı: geçersiz güven ${String(g)} → null`, koprudenOkunamadi({ okunamadi: true, guven: g }).guven, null)
}
esit('köprü okunamadı: güven 0 geçerli', koprudenOkunamadi({ okunamadi: true, guven: 0 }).guven, 0)
esit('köprü okunamadı: güven 1 geçerli', koprudenOkunamadi({ okunamadi: true, guven: 1 }).guven, 1)
// Plakayla ya da okunacak fotoğrafla birlikte "okunamadı" çelişkidir: 400.
// (Birlikte kabul edilseydi ya plaka yok sayılırdı ya da ücretli okuma yapılırdı.)
const CELISKI = { ok: false, durum: 400, hata: 'okunamadi, plaka ya da foto_base64 ile birlikte gönderilemez.' }
esit('köprü okunamadı: plakayla → 400', koprudenOkunamadi({ okunamadi: true, plaka: '34ABC123' }), CELISKI)
esit('köprü okunamadı: fotoğrafla → 400', koprudenOkunamadi({ okunamadi: true, foto_base64: 'QUJD' }), CELISKI)
esit(
  'köprü okunamadı: boş plaka çelişki değil',
  koprudenOkunamadi({ okunamadi: true, plaka: '' }).ok,
  true,
)
esit(
  'köprü okunamadı: kanıt fotoğrafı serbest (saklanan kopya)',
  koprudenOkunamadi({ okunamadi: true, foto_kanit_base64: 'QUJD' }).ok,
  true,
)
esit('köprü okunamadı: günlük etiketi', KOPRU_OKUMA_SAGLAYICI, 'KOPRU')

// Kaynağa bakış: köprünün "okunamadı" dalı ücretli okumayı (plakaOku) ÇAĞIRMAZ,
// okuma sınırının altındadır, deneme sorusuna yazmadan cevap verir ve kayıt
// yazılamazsa köprü yeniden denesin diye 503/409 döner (422 değil).
const okDal = /if \(olay\.koprudenOkunamadi\) \{([\s\S]*?)\n    \} else if \(!plaka && olay\.image\) \{/.exec(webhook)
esit('webhook: köprü okunamadı dalı ücretli okumadan ÖNCE ayrı', Boolean(okDal), true)
esit('webhook: köprü okunamadı dalı plakaOku çağırmaz', okDal ? okDal[1].includes('plakaOku(') : true, false)
esit('webhook: köprü okunamadı dalı okuma sınırından geçer', okDal ? okDal[1].includes('await okumaSiniri(') : false, true)
esit('webhook: okuma sınırı tek yardımcıda (iki dal da onu çağırır)', (webhook.match(/await okumaSiniri\(/g) ?? []).length, 2)
esit('webhook: deneme sorusu cevaplanır', webhook.includes('okunamadi_destekli: true'), true)
esit(
  'webhook: köprünün okunamadı kaydı yazılamazsa yeniden denenir',
  /if \(olay\.koprudenOkunamadi\) return rpcHatasi\('kamera_okunamadi', okErr\)/.test(webhook),
  true,
)

// --- 056: köprünün yön ipucu (hareket) -------------------------------------------
// Köprü izlediği aracın yönünü gönderir; sunucu onu YALNIZCA yanlış tahmini
// durdurmak için kullanır. Tanınmayan her değer "ipucu yok" demektir — asla
// 400 değil (400 köprüde kesin ret, araç kaybolurdu).
esit('hareket: GIRDI', hareketIpucu({ hareket: 'GIRDI' }), 'GIRDI')
esit('hareket: CIKTI', hareketIpucu({ hareket: 'CIKTI' }), 'CIKTI')
esit('hareket: ICERIDE', hareketIpucu({ hareket: 'ICERIDE' }), 'ICERIDE')
esit('hareket: yok', hareketIpucu({}), null)
esit('hareket: boş', hareketIpucu({ hareket: null }), null)
esit('hareket: küçük harf tanınmaz', hareketIpucu({ hareket: 'girdi' }), null)
esit('hareket: bilinmeyen', hareketIpucu({ hareket: 'XYZ' }), null)
esit('hareket: sayı', hareketIpucu({ hareket: 1 }), null)
esit('hareket: dizi', hareketIpucu({ hareket: ['GIRDI'] }), null)
esit('hareket: şerit adı yön değildir', hareketIpucu({ hareket: 'ORTAK' }), null)
esit('webhook: tek kapı ipucunu iletir',
  /rpc\('kamera_tek_kapi', \{[\s\S]*?p_hareket: olay\.hareket,[\s\S]*?\}\)/.test(webhook), true)
esit('webhook: ipucu ham gövdeden yardımcıyla okunur', webhook.includes('hareket: hareketIpucu(body)'), true)
const sema = /const OlaySchema = z\.object\(\{([\s\S]*?)\n\}\)/.exec(webhook)
esit('webhook: şema bulundu', Boolean(sema), true)
esit('webhook: ipucu şemada değil (kötü değer 400 olmasın)', sema ? sema[1].includes('hareket') : true, false)

// --- 070: kalp atışındaki sayılar ---------------------------------------------
// Köprü 1.4.3 kalbe {"kalp": {...}} koyar. Yalnızca düz bir nesne kalp bilgisidir;
// süzme (hangi anahtar, hangi tür) Postgres'te (kamera_kalp_bilgi). Eski köprünün
// boş gövdesi kalp bilgisi DEĞİLDİR — eskisi gibi 400 alır, damga yine basılmıştır.
esit('kalp: nesne', kalpBilgisi({ kalp: { surum: '1.4.3', fps: 8.6 } }), { surum: '1.4.3', fps: 8.6 })
esit('kalp: boş nesne de kalptir', kalpBilgisi({ kalp: {} }), {})
esit('kalp: eski köprünün boş gövdesi', kalpBilgisi({}), null)
esit('kalp: dizi değil', kalpBilgisi({ kalp: [1, 2] }), null)
esit('kalp: metin değil', kalpBilgisi({ kalp: 'x' }), null)
esit('kalp: null', kalpBilgisi({ kalp: null }), null)
esit('kalp: gövde nesne değil', kalpBilgisi(null), null)
esit('kalp: gövde dizi', kalpBilgisi([{ kalp: {} }]), null)
esit('kalp: plakalı olay kalp sayılmaz', kalpBilgisi({ kalp: {}, plaka: '34ABC12' }), null)
esit('kalp: zamanlı olay kalp sayılmaz', kalpBilgisi({ kalp: {}, zaman: '2026-11-18T10:00:00Z' }), null)
const kalpYeri = webhook.indexOf("rpc('kamera_kalp_bilgi'")
esit('webhook: kalp bilgisi yazılır', kalpYeri > 0, true)
esit('webhook: kalp bilgisi damgadan sonra', kalpYeri > webhook.indexOf("rpc('kamera_kalp')"), true)
esit('webhook: kalp bilgisi hız sınırından önce', kalpYeri < webhook.indexOf('hız sınırı aşıldı'), true)
esit('webhook: deneme isteği kalp bilgisi yazmaz', /if \(!deneme\) \{[\s\S]{0,400}?rpc\('kamera_kalp_bilgi'/.test(webhook), true)
esit('webhook: kalp bilgisi cihaz kimliğiyle', /rpc\('kamera_kalp_bilgi', \{\s*p_cihaz_id: cihazId \?\? null,\s*p_bilgi: kalp,?\s*\}\)/.test(webhook), true)

// --- 071: sunucunun reddettiği araç kart olur --------------------------------
// 409 sınıfı ret (P0001, 22xxx, 23xxx) artık köprüye 409 olarak gitmez: kart
// yazılır, 200 + karar ISTISNA döner — eski köprüler de aracı teslim sayar.
// Geçici hata (503) eskisi gibi yeniden denenir.
esit('ret: cevap', reddedilenCevabi('i-1'), {
  ok: true, karar: 'ISTISNA', sebep: 'REDDEDILDI', bilet_id: null, islem_id: 'i-1', istisna: true,
})
for (const rpc of ['kamera_tek_kapi', 'bilet_ac', 'kamera_cikis_bildir']) {
  esit(`webhook: ${rpc} reddi karta yazılır`,
    webhook.includes(`if (error) return reddiKartla(admin, '${rpc}', error, `), true)
  esit(`webhook: ${rpc} reddi artık doğrudan 409 değil`,
    webhook.includes(`if (error) return rpcHatasi('${rpc}', error)`), false)
}
const kartla = /async function reddiKartla\([\s\S]*?\n\}/.exec(webhook)?.[0] ?? ''
esit('webhook: reddiKartla var', kartla.length > 0, true)
esit('webhook: yalnızca 409 sınıfı kart olur', /if \(rpcHataDurumu\(error\.code\) !== 409\) return rpcHatasi\(rpc, error\)/.test(kartla), true)
esit('webhook: kart kamera_reddedildi ile yazılır', kartla.includes("admin.rpc('kamera_reddedildi'"), true)
esit('webhook: ret cümlesi karta gider', kartla.includes('p_sebep: error.message'), true)
esit('webhook: kart yazılamazsa geçici hata yeniden denenir', kartla.includes('json({ hata: GECICI_HATA }, 503)'), true)
esit('webhook: kart yazılınca 200', kartla.includes('json(reddedilenCevabi(k.islemId), 200)'), true)
esit('webhook: okunamadı kaydının reddi kart olmaz (kendisi kart)',
  webhook.includes("if (olay.koprudenOkunamadi) return rpcHatasi('kamera_okunamadi', okErr)"), true)

// --- 073: kamera girişi kapalıyken araç ATILIR (sahibin kararı 20.11) ----------
// Kalp atışı (boş {} — 1.4.2; {"kalp":…} — 1.4.3) ve kurulum denemesi eskisi gibi
// 403 alır: her köprü "KAMERA GİRİŞİ KAPALI" satırını yazmaya devam eder. Araç
// olayı 410 alır: her köprü 401/403/429 dışındaki 4xx'i kesin sayar ve aracı
// bırakır; 410, 1.4.2'nin "yeniden kabul" listesinde (400, 409, 413, 422, 429)
// olmadığı için her atılan araçta yanıltıcı "kabul edildi" satırı da çıkmaz.
const KAPALI_403_C = { durum: 403, govde: { hata: 'Kamera girişi kapalı.' } }
const KAPALI_410_C = { durum: 410, govde: { hata: 'Kamera girişi kapalı.', kod: 'KAMERA_KAPALI' } }
esit('kapalı: kod sabiti', KAMERA_KAPALI, 'KAMERA_KAPALI')
esit('kapalı: deneme → 403', kapaliCevabi(true, { islem_id: 'i-1' }), KAPALI_403_C)
esit('kapalı: 1.4.2 boş kalp {} → 403', kapaliCevabi(false, {}), KAPALI_403_C)
esit('kapalı: 1.4.3 kalp → 403', kapaliCevabi(false, { kalp: { surum: '1.4.3' } }), KAPALI_403_C)
esit('kapalı: boş gövde → 403', kapaliCevabi(false, null), KAPALI_403_C)
esit('kapalı: plakalı araç → 410',
  kapaliCevabi(false, { islem_id: 'i-1', yon: 'ORTAK', plaka: '34ABC12', zaman: '2026-11-20T10:00:00Z' }),
  KAPALI_410_C)
esit('kapalı: okunamadı aracı → 410', kapaliCevabi(false, { islem_id: 'i-2', okunamadi: true }), KAPALI_410_C)
esit('kapalı: JSON olmayan gövde (eski fotoğraflı) → 410', kapaliCevabi(false, undefined), KAPALI_410_C)
esit('kapalı: dizi gövde kalp değil → 410', kapaliCevabi(false, [{}]), KAPALI_410_C)

// Ayar okunamadıysa (503) damga basılmaz ve kapalı kararı verilmez; okunduysa
// damga kapalı kararından ÖNCE basılır (kapalı kamera "yaşıyor" görünür, sahte
// "haber yok" gelmez). Kalp bilgisi kapalıyken de yazılır, cevabı 403'tür.
const kapaliYeri = webhook.indexOf('kapaliCevabi(')
esit('webhook: kapalı kararı yardımcıyla', kapaliYeri > 0, true)
esit('webhook: okuma hatası damgadan önce döner',
  webhook.indexOf('giris.durum === 503') > 0 && webhook.indexOf('giris.durum === 503') < webhook.indexOf("rpc('kamera_kalp')"), true)
esit('webhook: damga kapalı kararından önce', webhook.indexOf("rpc('kamera_kalp')") < kapaliYeri, true)
esit('webhook: cihaz damgası da kapalı kararından önce', webhook.indexOf("rpc('kamera_kalp_cihaz'") < kapaliYeri, true)
esit('webhook: kalp bilgisi kapalı kararından önce', kalpYeri > 0 && kalpYeri < kapaliYeri, true)
esit('webhook: kapalıyken kalp cevabı 403, açıkken 200',
  webhook.includes("giris.ok ? json({ kalp: true }, 200) : json({ hata: giris.hata }, giris.durum)"), true)
esit('webhook: kapalı kararı hız sınırından önce', kapaliYeri < webhook.indexOf('hız sınırı aşıldı'), true)

// 071'den önce dağıtılan webhook (kamera_reddedildi yok) her reddedilen aracı
// 503'le sonsuza dek yeniden denetiyordu — sıralı kutuda arkadaki HER araç
// bekliyordu. İşlev yoksa 071 öncesi gibi asıl 409 döner (araç bırakılır).
esit('kart: P0001 → asıl 409', kartYazilamadiDurumu('P0001'), 409)
esit('kart: 23505 → asıl 409', kartYazilamadiDurumu('23505'), 409)
esit('kart: işlev yok (PostgREST PGRST202) → asıl 409', kartYazilamadiDurumu('PGRST202'), 409)
esit('kart: işlev yok (Postgres 42883) → asıl 409', kartYazilamadiDurumu('42883'), 409)
esit('kart: zaman aşımı → 503', kartYazilamadiDurumu('57014'), 503)
esit('kart: başka PostgREST hatası → 503', kartYazilamadiDurumu('PGRST116'), 503)
esit('kart: boş kod (ağ) → 503', kartYazilamadiDurumu(''), 503)
esit('kart: kod yok → 503', kartYazilamadiDurumu(undefined), 503)
esit('webhook: kart hatası yardımcıyla karar verir',
  kartla.includes('if (kartYazilamadiDurumu(kartErr.code) === 409) return rpcHatasi(rpc, error)'), true)

console.log(`${gecen} geçti, ${kalan} kaldı`)
process.exit(kalan === 0 ? 0 : 1)
