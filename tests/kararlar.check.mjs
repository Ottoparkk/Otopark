// Onay ekranı — Vardiya ve Bilet iptali geçmişi (audit_log satırı → kart),
// açılışta seçili kart ve Finans'taki "Onay" kartının alt yazısı.
//
//   node tests/kararlar.check.mjs
//
// Gerçek dosyayı içe aktarır. audit_log.detay bir jsonb'dir: eski bir sürümün
// yazdığı ya da elle düzeltilmiş bir satır beklenen biçimde olmayabilir.
// Kural: tanınmayan alan sessizce null olur, ekran ASLA patlamaz.
import {
  KARAR_AKSIYONLARI,
  kararAksiyonu,
  kararSatiri,
  varsayilanKategori,
  onayAltYazisi,
} from '../src/features/finans/kararlar.ts'

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

const YON = '11111111-1111-1111-1111-111111111111'
const PER = '22222222-2222-2222-2222-222222222222'
const ROW = '33333333-3333-3333-3333-333333333333'
const AT = '2026-11-07T10:00:00+00:00'

function satir(action, detay) {
  return { id: 42, actor: YON, action, row_id: ROW, detay, created_at: AT }
}

// ---- 1. Aksiyon adları — migration'lardaki audit() çağrılarıyla birebir -----
esit('aksiyon: vardiya onay', kararAksiyonu('VARDIYA', 'ONAY'), 'vardiya_kapatma_onay')
esit('aksiyon: vardiya ret', kararAksiyonu('VARDIYA', 'RET'), 'vardiya_kapatma_ret')
esit('aksiyon: iptal onay', kararAksiyonu('BILET_IPTAL', 'ONAY'), 'bilet_iptal_onay')
esit('aksiyon: iptal ret', kararAksiyonu('BILET_IPTAL', 'RET'), 'bilet_iptal_ret')
esit('aksiyon: iki tür', Object.keys(KARAR_AKSIYONLARI).length, 2)

// ---- 2. Tam satırlar --------------------------------------------------------
// 035 vardiya_kapatma_onayla
esit(
  'vardiya onay',
  kararSatiri(
    satir('vardiya_kapatma_onay', {
      talep_eden: PER, beklenen: 150000, talep_beklenen: 150000, sayilan: 149000, fark: -1000,
    }),
  ),
  {
    id: '42', tur: 'VARDIYA', sonuc: 'ONAY', karar_at: AT, karar_veren: YON, satir_id: ROW,
    talep_eden: PER, plaka: null, sebep: null, ret_sebep: null, sayilan_kurus: 149000, fark_kurus: -1000,
  },
)
// 035 vardiya_kapatma_reddet — buradaki "sebep" RET sebebidir
esit(
  'vardiya ret',
  kararSatiri(satir('vardiya_kapatma_ret', { talep_eden: PER, sayilan: 90000, sebep: 'Tekrar say' })),
  {
    id: '42', tur: 'VARDIYA', sonuc: 'RET', karar_at: AT, karar_veren: YON, satir_id: ROW,
    talep_eden: PER, plaka: null, sebep: null, ret_sebep: 'Tekrar say', sayilan_kurus: 90000, fark_kurus: null,
  },
)
// 050 bilet_iptal_onayla
esit(
  'iptal onay',
  kararSatiri(
    satir('bilet_iptal_onay', { talep_eden: PER, talep_at: AT, sebep: 'Yanlış giriş', plaka: '34ABC123' }),
  ),
  {
    id: '42', tur: 'BILET_IPTAL', sonuc: 'ONAY', karar_at: AT, karar_veren: YON, satir_id: ROW,
    talep_eden: PER, plaka: '34ABC123', sebep: 'Yanlış giriş', ret_sebep: null, sayilan_kurus: null, fark_kurus: null,
  },
)
// 050 bilet_iptal_reddet — "sebep" İSTEK sebebi, "ret_sebep" karar sebebi
esit(
  'iptal ret',
  kararSatiri(
    satir('bilet_iptal_ret', {
      talep_eden: PER, talep_at: AT, sebep: 'Yanlış giriş', ret_sebep: 'Araç içeride', plaka: '34ABC123',
    }),
  ),
  {
    id: '42', tur: 'BILET_IPTAL', sonuc: 'RET', karar_at: AT, karar_veren: YON, satir_id: ROW,
    talep_eden: PER, plaka: '34ABC123', sebep: 'Yanlış giriş', ret_sebep: 'Araç içeride', sayilan_kurus: null, fark_kurus: null,
  },
)

// ---- 3. Bozuk / eksik satırlar asla patlamaz -------------------------------
const BOS_VARDIYA = {
  id: '42', tur: 'VARDIYA', sonuc: 'ONAY', karar_at: AT, karar_veren: YON, satir_id: ROW,
  talep_eden: null, plaka: null, sebep: null, ret_sebep: null, sayilan_kurus: null, fark_kurus: null,
}
esit('detay null', kararSatiri(satir('vardiya_kapatma_onay', null)), BOS_VARDIYA)
esit('detay yok', kararSatiri({ id: 42, actor: YON, action: 'vardiya_kapatma_onay', row_id: ROW, created_at: AT }), BOS_VARDIYA)
esit('detay metin', kararSatiri(satir('vardiya_kapatma_onay', 'bozuk')), BOS_VARDIYA)
esit('detay dizi', kararSatiri(satir('vardiya_kapatma_onay', [1, 2])), BOS_VARDIYA)
esit('detay sayı', kararSatiri(satir('vardiya_kapatma_onay', 5)), BOS_VARDIYA)
esit(
  'kuruş: metin, ondalık, sonsuz, çok büyük → null',
  kararSatiri(
    satir('vardiya_kapatma_onay', { sayilan: '149000', fark: 10.5 }),
  ).sayilan_kurus === null &&
    kararSatiri(satir('vardiya_kapatma_onay', { fark: 10.5 })).fark_kurus === null &&
    kararSatiri(satir('vardiya_kapatma_onay', { fark: Infinity })).fark_kurus === null &&
    kararSatiri(satir('vardiya_kapatma_onay', { fark: 2 ** 60 })).fark_kurus === null,
  true,
)
esit('kuruş: sıfır geçerli', kararSatiri(satir('vardiya_kapatma_onay', { fark: 0 })).fark_kurus, 0)
esit(
  'metin: boş / boşluk / sayı → null',
  [
    kararSatiri(satir('bilet_iptal_ret', { ret_sebep: '' })).ret_sebep,
    kararSatiri(satir('bilet_iptal_ret', { ret_sebep: '   ' })).ret_sebep,
    kararSatiri(satir('bilet_iptal_ret', { plaka: 34 })).plaka,
    kararSatiri(satir('bilet_iptal_ret', { talep_eden: {} })).talep_eden,
  ],
  [null, null, null, null],
)
esit('metin: kenar boşlukları kırpılır', kararSatiri(satir('bilet_iptal_ret', { ret_sebep: '  dolu  ' })).ret_sebep, 'dolu')
esit('tanınmayan aksiyon → null', kararSatiri(satir('vardiya_sil', {})), null)
esit('silinmiş aktör', kararSatiri({ ...satir('bilet_iptal_onay', {}), actor: null }).karar_veren, null)
esit('satır kimliği yok', kararSatiri({ ...satir('bilet_iptal_onay', {}), row_id: null }).satir_id, null)
esit('kimlik metin', kararSatiri({ ...satir('bilet_iptal_onay', {}), id: '7' }).id, '7')

// ---- 4. Açılışta seçili kart -----------------------------------------------
// Sıra ekrandakiyle aynı: Vardiya · Bilet ve abonman · Bilet iptali.
esit('varsayılan: hiçbiri → bilet', varsayilanKategori({ vardiya: 0, bilet: 0, iptal: 0 }), 'BILET')
esit('varsayılan: yalnız iptal', varsayilanKategori({ vardiya: 0, bilet: 0, iptal: 2 }), 'BILET_IPTAL')
esit('varsayılan: bilet + iptal → bilet', varsayilanKategori({ vardiya: 0, bilet: 5, iptal: 2 }), 'BILET')
esit('varsayılan: vardiya önce', varsayilanKategori({ vardiya: 1, bilet: 5, iptal: 2 }), 'VARDIYA')

// ---- 5. Finans "Onay" kartı alt yazısı --------------------------------------
esit('alt: boş', onayAltYazisi({ tahsilat: 0, vardiya: 0, iptal: 0 }), 'bekleyen yok')
esit('alt: tahsilat', onayAltYazisi({ tahsilat: 3, vardiya: 0, iptal: 0 }), '3 tahsilat bekliyor')
esit('alt: vardiya', onayAltYazisi({ tahsilat: 0, vardiya: 1, iptal: 0 }), 'vardiya kapatma bekliyor')
esit('alt: iptal', onayAltYazisi({ tahsilat: 0, vardiya: 0, iptal: 2 }), '2 bilet iptali bekliyor')
esit('alt: tahsilat + vardiya (eski metin aynı)', onayAltYazisi({ tahsilat: 3, vardiya: 1, iptal: 0 }), '3 tahsilat + vardiya kapatma')
esit('alt: üçü', onayAltYazisi({ tahsilat: 3, vardiya: 1, iptal: 2 }), '3 tahsilat + vardiya kapatma + 2 bilet iptali')

console.log(`${gecen} geçti, ${kalan} kaldı`)
process.exit(kalan === 0 ? 0 : 1)
