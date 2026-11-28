// Bilet ekranında gösterilen ücret — açık, kapalı ve iptal bilet.
//
//   node tests/bilet.check.mjs
//
// Hata (2026-11-02): açık biletin `ucret_kurus`'u çıkışa kadar 0'dır; Bilet
// Detay ücreti oradan okuduğu için içerideki araca ₺0 (puan kullanıldıysa
// eksi) yazıyordu. Açık bilette ücret, Tahsilat'taki gibi sunucunun canlı
// hesabından (ucret_hesapla) gelir.
//
// Gerçek dosyayı içe aktarır; lib/bilet.ts yalnızca `import type` kullanır.
import {
  cikisGeriAlma,
  gosterilenUcret,
  kapaliBiletIslemYapabilir,
  sureBitisi,
  uzunKalan,
  zatenKapandi,
} from '../src/lib/bilet.ts'

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

const acik = { durum: 'ACIK', ucret_kurus: 0, indirim_kurus: 0, abonman_id: null }

esit('açık: canlı ücret', gosterilenUcret(acik, 15000), 15000)
esit('açık: saklı 0 değil canlı ücret okunur', gosterilenUcret({ ...acik, ucret_kurus: 0 }, 7500), 7500)
esit('açık: puan düşülür', gosterilenUcret({ ...acik, indirim_kurus: 5000 }, 15000), 10000)
esit('açık: puan ücreti aşsa da eksi olmaz', gosterilenUcret({ ...acik, indirim_kurus: 5000 }, 3000), 0)
esit('açık: abonman ücretsiz', gosterilenUcret({ ...acik, abonman_id: 'x' }, 15000), 0)
esit('açık: canlı ücret henüz yok → bilinmiyor', gosterilenUcret(acik, undefined), null)
esit('açık: abonmanda beklemeye gerek yok', gosterilenUcret({ ...acik, abonman_id: 'x' }, undefined), 0)
// 078: abonmanın otoparkı ücretsiz, oto yıkaması değil — ücret tam olarak yıkama.
esit('açık: abonman + yıkama = yıkama', gosterilenUcret({ ...acik, abonman_id: 'x', yikama_kurus: 15000 }, undefined), 15000)

const kapali = { durum: 'KAPALI', ucret_kurus: 20000, indirim_kurus: 5000, abonman_id: null }
esit('kapalı: saklı ücret − puan', gosterilenUcret(kapali, undefined), 15000)
esit('kapalı: canlı ücret yok sayılır', gosterilenUcret(kapali, 99999), 15000)

esit('iptal: ücret yok', gosterilenUcret({ ...kapali, durum: 'IPTAL' }, 99999), null)

// ---- Süre nerede biter --------------------------------------------------
// Hata (2026-11-02): bilet_iptal `cikis_at` yazmaz; içerideyken iptal edilen
// biletin süresi ekranda sonsuza dek artıyordu. Süre çıkışta, yoksa iptal
// anında biter; yalnızca açık bilette "şimdi"ye kadar sayılır (null).
const T1 = '2026-11-02T10:00:00Z'
const T2 = '2026-11-02T11:30:00Z'
esit('açık: şimdiye kadar', sureBitisi({ durum: 'ACIK', cikis_at: null, iptal_at: null }), null)
esit('kapalı: çıkışta', sureBitisi({ durum: 'KAPALI', cikis_at: T1, iptal_at: null }), T1)
esit('içerideyken iptal: iptal anında', sureBitisi({ durum: 'IPTAL', cikis_at: null, iptal_at: T2 }), T2)
esit('çıktıktan sonra iptal: yine çıkışta', sureBitisi({ durum: 'IPTAL', cikis_at: T1, iptal_at: T2 }), T1)

// ---- Tahsilat sırasında bilet kapandı -----------------------------------
// 054 (inceleme): kamera çıkışı görüp bileti ÖDEMESİZ kapatırsa, Tahsilat
// ekranındaki kasiyerin bilet_kapat'ı "zaten kapatılmış" ile düşer. Ekran
// bunu tanıyıp biletin sayfasına ("Ödeme topla") götürmeli; başka hatalar
// eskisi gibi yalnızca gösterilir.
esit('kapandı: sunucunun mesajı', zatenKapandi('Bu bilet zaten kapatılmış veya iptal edilmiş.'), true)
esit('kapandı: başka hata değil', zatenKapandi('Ödeme yöntemi seçin.'), false)
esit('kapandı: ağ hatası değil', zatenKapandi('Tahsilat kaydedilemedi. Tekrar deneyin — tahsilat otomatik tekrarlanmaz.'), false)
esit('kapandı: boş', zatenKapandi(''), false)

// --- uzunKalan (F14, 1.4.2): İçeride'de "Uzun süredir içeride" işareti ------------
// Eşik gece işinin "Terk edilmiş olabilir" bildirimiyle AYNI ayar
// (terk_esik_saat). Abonmanlı araç uzun kalabilir — işaretlenmez.
const SIMDI = new Date('2026-11-14T12:00:00Z')
const saatOnce = (sa) => new Date(SIMDI.getTime() - sa * 3600_000).toISOString()
const ab = (sa, abonman_id = null) => ({ giris_at: saatOnce(sa), abonman_id })
esit('uzun: eşiğin altında', uzunKalan(ab(47.99), 48, SIMDI), false)
esit('uzun: tam eşikte', uzunKalan(ab(48), 48, SIMDI), true)
esit('uzun: eşiğin üstünde', uzunKalan(ab(72), 48, SIMDI), true)
esit('uzun: 24 saat eşiği', uzunKalan(ab(30), 24, SIMDI), true)
esit('uzun: 48 saat eşiğinde 30 saat değil', uzunKalan(ab(30), 48, SIMDI), false)
esit('uzun: abonman işaretlenmez', uzunKalan(ab(200, 'abn-1'), 48, SIMDI), false)
esit('uzun: geçersiz giriş saati', uzunKalan({ giris_at: 'bozuk', abonman_id: null }, 48, SIMDI), false)
esit('uzun: eşik yok', uzunKalan(ab(200), undefined, SIMDI), false)
esit('uzun: eşik sıfır', uzunKalan(ab(200), 0, SIMDI), false)
esit('uzun: eşik sayı değil', uzunKalan(ab(200), Number.NaN, SIMDI), false)
esit('uzun: gelecekteki giriş', uzunKalan(ab(-5), 48, SIMDI), false)

// ---- Yanlış verilen çıkışı geri almak (060) ------------------------------
// Sahip (2026-11-15): elle verilen çıkış da (ödenmiş olsa da) geri alınır,
// sebep yazılarak. Kameranın PARASIZ kapattığı bilet 054'ün sebepsiz
// "Araç çıkmadı" kutusunda kalır; geri kalan her kapanmış bilet sebepli
// kutuya gider. Açık ve iptal bilette düğme yok.
const kapanmis = (cikis_kaynak, tahsil_kurus) => ({ durum: 'KAPALI', cikis_kaynak, tahsil_kurus })
esit('geri al: kamera, parasız → eski kutu', cikisGeriAlma(kapanmis('KAMERA', 0)), 'KAMERA')
esit('geri al: kamera, ödenmiş → sebepli', cikisGeriAlma(kapanmis('KAMERA', 5000)), 'SEBEPLI')
esit('geri al: elle, parasız → sebepli', cikisGeriAlma(kapanmis('MOBIL', 0)), 'SEBEPLI')
esit('geri al: elle, ödenmiş → sebepli', cikisGeriAlma(kapanmis('MOBIL', 5000)), 'SEBEPLI')
esit('geri al: manuel kaynak → sebepli', cikisGeriAlma(kapanmis('MANUEL', 2500)), 'SEBEPLI')
esit('geri al: açık bilet → yok', cikisGeriAlma({ durum: 'ACIK', cikis_kaynak: null, tahsil_kurus: 0 }), null)
esit('geri al: iptal → yok', cikisGeriAlma({ durum: 'IPTAL', cikis_kaynak: 'MOBIL', tahsil_kurus: 5000 }), null)

// 067: Personel 3 günlük çıkışları OKUR ama yalnızca kendi açık vardiyasında
// kapanmış bilette işlem yapar (tahsil, ücretsiz, geri alma — sunucu da
// aynısını söyler, 034 / 066 / 054 / 060). Yönetici her bilette.
esit('işlem: Yönetici, başka vardiya', kapaliBiletIslemYapabilir({ kapatan_vardiya_id: 'v9' }, true, 'v1'), true)
esit('işlem: Yönetici, vardiyasız', kapaliBiletIslemYapabilir({ kapatan_vardiya_id: null }, true, null), true)
esit('işlem: Personel, kendi vardiyası', kapaliBiletIslemYapabilir({ kapatan_vardiya_id: 'v1' }, false, 'v1'), true)
esit('işlem: Personel, başka vardiya', kapaliBiletIslemYapabilir({ kapatan_vardiya_id: 'v9' }, false, 'v1'), false)
esit('işlem: Personel, vardiyasız bilet', kapaliBiletIslemYapabilir({ kapatan_vardiya_id: null }, false, 'v1'), false)
esit('işlem: Personel, açık vardiyası yok', kapaliBiletIslemYapabilir({ kapatan_vardiya_id: 'v1' }, false, null), false)
esit('işlem: Personel, ikisi de boş', kapaliBiletIslemYapabilir({ kapatan_vardiya_id: null }, false, null), false)

console.log(`${gecen} geçti, ${kalan} kaldı`)
if (kalan > 0) process.exit(1)
