// Kim yaptı (063, sahip 2026-11-15): her para kaydında toplayan, onaylayan /
// reddeden, kaydeden. Ekranlar satırları buradan alır; yalnızca Yönetici görür.
//
//   node tests/kimYapti.check.mjs
//
// Gerçek dosyayı içe aktarır. Kural: bilinmeyen kişi YANLIŞ bir ad olarak
// değil, satırın hiç gösterilmemesiyle ya da "Bilinmiyor" ile görünür.
import {
  adCoz,
  kaydedenSatiri,
  kararKisileri,
  sonKararHaritasi,
  tahsilatKisileri,
  vardiyaKapatanSatiri,
} from '../src/lib/kimYapti.ts'

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

const AT = '2026-11-15T09:30:00.000Z'
const adlar = new Map([
  ['p1', 'Ayşe Personel'],
  ['y1', 'Mehmet Yönetici'],
])

// ------------------------------------------------------------------ adCoz --
esit('adCoz: bilinen', adCoz('p1', adlar), 'Ayşe Personel')
esit('adCoz: bilinmeyen kimlik', adCoz('zz', adlar), 'Bilinmiyor')
esit('adCoz: boş kimlik', adCoz(null, adlar), null)
esit('adCoz: tanımsız kimlik (sütun henüz yok)', adCoz(undefined, adlar), null)

// --------------------------------------------------------- tahsilatKisileri --
const taban = { tutar_kurus: 9500, iptal_of: null, toplayan: 'Ayşe Personel', onaylayan: null, onay_at: null }

esit('bekleyen: yalnız toplayan',
  tahsilatKisileri({ ...taban, durum: 'BEKLIYOR' }),
  [{ etiket: 'Ödeme toplayan', ad: 'Ayşe Personel', zaman: null }])

esit('onaylanan: toplayan + onaylayan (anıyla)',
  tahsilatKisileri({ ...taban, durum: 'ONAYLANDI', onaylayan: 'Mehmet Yönetici', onay_at: AT }),
  [
    { etiket: 'Ödeme toplayan', ad: 'Ayşe Personel', zaman: null },
    { etiket: 'Onaylayan', ad: 'Mehmet Yönetici', zaman: AT },
  ])

esit('reddedilen: toplayan + reddeden',
  tahsilatKisileri({ ...taban, durum: 'REDDEDILDI', onaylayan: 'Mehmet Yönetici', onay_at: AT }),
  [
    { etiket: 'Ödeme toplayan', ad: 'Ayşe Personel', zaman: null },
    { etiket: 'Reddeden', ad: 'Mehmet Yönetici', zaman: AT },
  ])

esit('ters kaydın kendiliğinden reddettiği satır: reddeden yok',
  tahsilatKisileri({ ...taban, durum: 'REDDEDILDI' }),
  [{ etiket: 'Ödeme toplayan', ad: 'Ayşe Personel', zaman: null }])

esit('karşı kayıt (iptal_of): geri alan',
  tahsilatKisileri({ ...taban, tutar_kurus: -9500, iptal_of: 't1', durum: 'ONAYLANDI', onaylayan: 'Mehmet Yönetici', onay_at: AT }),
  [
    { etiket: 'Geri alan', ad: 'Ayşe Personel', zaman: null },
    { etiket: 'Onaylayan', ad: 'Mehmet Yönetici', zaman: AT },
  ])

esit('karşı kayıt, iptal_of gelmeden (onay_listesi): eksi tutar yeter',
  tahsilatKisileri({ ...taban, tutar_kurus: -100, iptal_of: undefined, durum: 'BEKLIYOR' }),
  [{ etiket: 'Geri alan', ad: 'Ayşe Personel', zaman: null }])

esit('toplayan yok: Otomatik',
  tahsilatKisileri({ ...taban, toplayan: null, durum: 'BEKLIYOR' }),
  [{ etiket: 'Ödeme toplayan', ad: 'Otomatik', zaman: null }])

esit('onaylayan var ama an yok (eski satır): zamansız',
  tahsilatKisileri({ ...taban, durum: 'ONAYLANDI', onaylayan: 'Mehmet Yönetici', onay_at: null }),
  [
    { etiket: 'Ödeme toplayan', ad: 'Ayşe Personel', zaman: null },
    { etiket: 'Onaylayan', ad: 'Mehmet Yönetici', zaman: null },
  ])

esit('063 öncesi: onaylayan sütunu hiç yok → satır yok',
  tahsilatKisileri({ ...taban, durum: 'ONAYLANDI', onaylayan: undefined, onay_at: undefined }),
  [{ etiket: 'Ödeme toplayan', ad: 'Ayşe Personel', zaman: null }])

// ----------------------------------------------------------- kaydedenSatiri --
esit('kaydeden: elle', kaydedenSatiri('Mehmet Yönetici', false),
  { etiket: 'Kaydeden', ad: 'Mehmet Yönetici', zaman: null })
esit('kaydeden: düzenli', kaydedenSatiri('Mehmet Yönetici', true),
  { etiket: 'Kaydeden', ad: 'Mehmet Yönetici (düzenli)', zaman: null })
esit('kaydeden: bilinmiyor → satır yok', kaydedenSatiri(null, false), null)
esit('kaydeden: düzenli ama bilinmiyor → satır yok', kaydedenSatiri(null, true), null)

// ------------------------------------------------------------ kararKisileri --
esit('karar onay: isteyen + onaylayan',
  kararKisileri({ sonuc: 'ONAY', karar_at: AT, isteyen: 'Ayşe Personel', karar_veren: 'Mehmet Yönetici' }),
  [
    { etiket: 'İsteyen', ad: 'Ayşe Personel', zaman: null },
    { etiket: 'Onaylayan', ad: 'Mehmet Yönetici', zaman: AT },
  ])
esit('karar ret: isteyen + reddeden',
  kararKisileri({ sonuc: 'RET', karar_at: AT, isteyen: 'Ayşe Personel', karar_veren: 'Mehmet Yönetici' }),
  [
    { etiket: 'İsteyen', ad: 'Ayşe Personel', zaman: null },
    { etiket: 'Reddeden', ad: 'Mehmet Yönetici', zaman: AT },
  ])
esit('karar: isteyen bilinmiyor → yalnız karar veren',
  kararKisileri({ sonuc: 'ONAY', karar_at: AT, isteyen: null, karar_veren: 'Mehmet Yönetici' }),
  [{ etiket: 'Onaylayan', ad: 'Mehmet Yönetici', zaman: AT }])
esit('karar: karar veren silinmiş → Bilinmiyor değil, satır yok',
  kararKisileri({ sonuc: 'RET', karar_at: AT, isteyen: 'Ayşe Personel', karar_veren: null }),
  [{ etiket: 'İsteyen', ad: 'Ayşe Personel', zaman: null }])

// -------------------------------------------------------- sonKararHaritasi --
const satirlar = [
  { id: 1, actor: 'y1', action: 'vardiya_kapatma_onay', row_id: 'v1', detay: { talep_eden: 'p1' }, created_at: '2026-11-10T10:00:00Z' },
  { id: 2, actor: 'y2', action: 'vardiya_zorla_kapat', row_id: 'v1', detay: {}, created_at: '2026-11-12T10:00:00Z' },
  { id: 3, actor: 'y1', action: 'vardiya_kapatma_ret', row_id: 'v2', detay: { talep_eden: 'p1' }, created_at: '2026-11-12T10:00:00Z' },
  { id: 4, actor: null, action: 'vardiya_kapatma_onay', row_id: 'v3', detay: 'bozuk', created_at: '2026-11-13T10:00:00Z' },
  { id: 5, actor: 'y1', action: 'vardiya_kapatma_onay', row_id: null, detay: {}, created_at: '2026-11-13T10:00:00Z' },
  { id: 6, actor: 'y1', action: 'bilet_iptal_onay', row_id: 'b1', detay: { talep_eden: 'p1', talep_at: AT }, created_at: '2026-11-14T10:00:00Z' },
]
const harita = sonKararHaritasi(satirlar, ['vardiya_kapatma_onay', 'vardiya_zorla_kapat'])
esit('harita: aynı satırda EN SON karar kazanır (sıradan bağımsız)',
  harita.get('v1'), { action: 'vardiya_zorla_kapat', actor: 'y2', created_at: '2026-11-12T10:00:00Z', talep_eden: null })
esit('harita: istenmeyen eylem alınmaz', harita.has('v2'), false)
esit('harita: bozuk detay patlatmaz, talep_eden null',
  harita.get('v3'), { action: 'vardiya_kapatma_onay', actor: null, created_at: '2026-11-13T10:00:00Z', talep_eden: null })
esit('harita: row_id olmayan satır atlanır', harita.size, 2)
const ters = sonKararHaritasi([...satirlar].reverse(), ['vardiya_kapatma_onay', 'vardiya_zorla_kapat'])
esit('harita: ters sırada da aynı sonuç', ters.get('v1')?.actor, 'y2')
esit('harita: bilet iptali isteyeni detaydan',
  sonKararHaritasi(satirlar, ['bilet_iptal_onay']).get('b1')?.talep_eden, 'p1')

// ---------------------------------------------------- vardiyaKapatanSatiri --
esit('vardiya: istek onayı → Onaylayan',
  vardiyaKapatanSatiri({ action: 'vardiya_kapatma_onay', created_at: AT }, 'Mehmet Yönetici'),
  { etiket: 'Onaylayan', ad: 'Mehmet Yönetici', zaman: AT })
esit('vardiya: Yönetici zorla kapattı → Kapatan',
  vardiyaKapatanSatiri({ action: 'vardiya_zorla_kapat', created_at: AT }, 'Mehmet Yönetici'),
  { etiket: 'Kapatan', ad: 'Mehmet Yönetici', zaman: AT })
esit('vardiya: karar yok → satır yok', vardiyaKapatanSatiri(undefined, null), null)
esit('vardiya: karar veren silinmiş → satır yok',
  vardiyaKapatanSatiri({ action: 'vardiya_kapatma_onay', created_at: AT }, null), null)

console.log(`kimYapti: ${gecen} geçti, ${kalan} kaldı`)
if (kalan > 0) process.exit(1)
