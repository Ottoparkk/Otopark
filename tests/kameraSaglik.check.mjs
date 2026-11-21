// Kamera sağlığı (070): Gişe şeridi, Yönetici karnesi ve köprü sağlığı satırı.
//
//   node tests/kameraSaglik.check.mjs
//
// Gerçek dosyaları içe aktarır. Şerit herkese (Yönetici ve Personel) görünür
// ve yalnızca dört durumdan birini bilir; tanımadığı her şeyde SUSAR — boş
// alarm şeridi personelin ilk görmezden geldiği şeydir.
import { kameraSeridi } from '../src/features/gise/kameraSeridi.ts'
import { kameraPayi, karneOzeti, saglikParcalari } from '../src/features/yonetim/karne.ts'

let gecen = 0
let kalan = 0
function esit(ad, gercek, beklenen) {
  const a = JSON.stringify(gercek)
  const b = JSON.stringify(beklenen)
  if (a === b) gecen += 1
  else {
    kalan += 1
    console.error(`FAIL ${ad}\n  beklenen: ${b}\n  gelen:    ${a}`)
  }
}

// 1. Şerit
esit('şerit: tamam', kameraSeridi('TAMAM'), null)
esit('şerit: cevap yok', kameraSeridi(null), null)
esit('şerit: tanımsız', kameraSeridi(undefined), null)
esit('şerit: bilinmeyen durum susar', kameraSeridi('BASKA'), null)
esit('şerit: haber yok', kameraSeridi('HABER_YOK'), {
  ton: 'danger',
  metin: 'Kameradan haber yok — araçlar kendiliğinden kaydedilmiyor olabilir',
})
esit('şerit: araç reddediliyor', kameraSeridi('REDDEDILIYOR'), {
  ton: 'danger',
  metin: 'Sunucu kamera araçlarını reddediyor — bazı araçlar kaydedilmedi',
})
esit('şerit: kuyruk takıldı', kameraSeridi('KUYRUK_TAKILDI'), {
  ton: 'warn',
  metin: 'Kamera araçları sunucuya gönderemiyor — kayıtlar gecikiyor',
})
esit('şerit: izleme kapandı', kameraSeridi('IZLEME_KAPANDI'), {
  ton: 'warn',
  metin: 'Kamera araç izlemesi kapandı — daha çok çözülmemiş kayıt çıkabilir',
})
// 073: kamera girişi Ayarlar'dan kapatıldı — kameranın gördüğü araçlar atılır
// (sahibin kararı 20.11), personel elle kaydeder.
esit('şerit: kamera girişi kapalı', kameraSeridi('KAPALI'), {
  ton: 'warn',
  metin: 'Kamera girişi kapalı — araçları elle kaydedin',
})

// 2. Kamera payı (yüzde, tam sayı); hiç araç yoksa null — "%0" yanlış olurdu
esit('pay: hepsi kamera', kameraPayi(10, 0), 100)
esit('pay: yarı', kameraPayi(1, 1), 50)
esit('pay: yuvarlanır', kameraPayi(2, 1), 67)
esit('pay: araç yok', kameraPayi(0, 0), null)

// 3. Karne özeti: günler toplanır
const gun = (o) => ({
  gun: '2026-11-18', kamera_giris: 0, elle_giris: 0, kamera_cikis: 0, elle_cikis: 0,
  kart: 0, kart_plakasiz: 0, kart_tur: {}, geri_acilan: 0, yon_bilinmiyor: 0,
  gecikme_sn: null, ...o,
})
esit(
  'özet: toplar',
  karneOzeti([
    gun({ kamera_giris: 8, elle_giris: 2, kamera_cikis: 6, elle_cikis: 4, kart: 3, kart_plakasiz: 2, geri_acilan: 1, yon_bilinmiyor: 1 }),
    gun({ gun: '2026-11-17', kamera_giris: 2, elle_giris: 0, kamera_cikis: 0, elle_cikis: 0, kart: 1, kart_plakasiz: 0 }),
  ]),
  { giris: 12, kameraGirisPayi: 83, cikis: 10, kameraCikisPayi: 60, kart: 4, kartPlakasiz: 2, geriAcilan: 1, yonBilinmiyor: 1 },
)
esit('özet: boş', karneOzeti([]), {
  giris: 0, kameraGirisPayi: null, cikis: 0, kameraCikisPayi: null, kart: 0, kartPlakasiz: 0, geriAcilan: 0, yonBilinmiyor: 0,
})

// 4. Köprü sağlığı satırı: olmayan sayı yazılmaz, yanlış türdeki atılır
esit(
  'sağlık: tam',
  saglikParcalari({ surum: '1.4.3', fps: 8.6, kuyruk: 0, kuyruk_en_eski_sn: 0, takip: 'acik', kume: 'GPU · YOLO11s' }),
  ['Sürüm 1.4.3', 'GPU · YOLO11s', '8,6 kare/sn', 'Kuyruk boş', 'İzleme açık'],
)
esit(
  'sağlık: takılı kuyruk dakikayla',
  saglikParcalari({ kuyruk: 4, kuyruk_en_eski_sn: 600, takip: 'kapandi' }),
  ['Kuyrukta 4 araç (en eskisi 10 dk)', 'İzleme kapandı'],
)
esit('sağlık: kısa bekleyen dakika yazmaz', saglikParcalari({ kuyruk: 1, kuyruk_en_eski_sn: 20 }), ['Kuyrukta 1 araç'])
esit('sağlık: reddedilen', saglikParcalari({ kuyruk: 0, reddedilen: 3 }), ['Kuyruk boş', 'Son saatte 3 araç reddedildi'])
esit('sağlık: reddedilen yoksa yazılmaz', saglikParcalari({ reddedilen: 0 }), [])
// 1.4.3 (1a): son saatte aynı aracın parçası sayılırdı (yalnızca kayıt) / sayıldı.
esit(
  'sağlık: parça sayılırdı',
  saglikParcalari({ emilirdi: 2, emildi: 0, takip: 'acik' }),
  ['Son saatte 2 parça aynı araca sayılırdı', 'İzleme açık'],
)
esit('sağlık: parça sayıldı', saglikParcalari({ emilirdi: 0, emildi: 1 }), ['Son saatte 1 parça aynı araca sayıldı'])
esit('sağlık: parça yoksa yazılmaz', saglikParcalari({ emilirdi: 0, emildi: 0 }), [])
esit('sağlık: izleme kapalı', saglikParcalari({ takip: 'kapali' }), ['İzleme kapalı'])
esit('sağlık: eski köprü (boş)', saglikParcalari({}), [])
esit('sağlık: null', saglikParcalari(null), [])
esit('sağlık: yanlış tür atılır', saglikParcalari({ fps: '9', kuyruk: 'x', takip: 'bilinmez' }), [])

console.log(`${gecen} geçti, ${kalan} kaldı`)
process.exit(kalan === 0 ? 0 : 1)
