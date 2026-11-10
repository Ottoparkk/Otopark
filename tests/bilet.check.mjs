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
import { gosterilenUcret, sureBitisi, zatenKapandi } from '../src/lib/bilet.ts'

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

console.log(`${gecen} geçti, ${kalan} kaldı`)
if (kalan > 0) process.exit(1)
