/**
 * The entry fiş on the P2 (spec 2026-11-28): the same content as the app's
 * FisSayfasi — the ticket's own tariff bands, priced by the server
 * (fis_tahmini), and the print number taken from the server (fis_basildi)
 * BEFORE the paper is drawn. Type-only imports; helpers come in as `y`
 * (tests/terminalFis.check.mjs).
 */
import type { FisAraclari, FisBileti, FisOtopark, FisSatiri, girisFisi, sureMetni } from '../../src/features/fis/fisIcerik'
import type { FisTahminSecenegi, fisTahminSecenekleri, parcala } from '../../src/features/fis/fisSecenek'
import type { kademeAraliklari } from '../../src/features/finans/kademe'
import type { Tarife } from '../../src/lib/types'
import type { Sunucu } from './sunucu'

export interface FisYardimcilari {
  fis: FisAraclari
  girisFisi: typeof girisFisi
  sureMetni: typeof sureMetni
  fisTahminSecenekleri: typeof fisTahminSecenekleri
  parcala: typeof parcala
  kademeAraliklari: typeof kademeAraliklari
}

type FisBiletSatiri = FisBileti & { tarife_id: string | null; durum: string }

const BILET_SUTUNLARI =
  'id,plaka,giris_at,cikis_at,ucret_kurus,indirim_kurus,puan_kullanilan,tahsil_kurus,odeme_yontemi,abonman_id,yikama_kurus,anlasma_kurus,anlasma_bitis,ucretsiz_sebep,tarife_id,durum'

/** fis_tahmini takes at most 6 minutes a call (088). */
const TAHMIN_PARCA = 6

export interface FisVerisi {
  bilet: FisBileti
  otopark: FisOtopark
  secenekler: FisTahminSecenegi[]
  /** minute → kuruş */
  fiyatlar: Map<number, number>
}

export async function fisVerisi(s: Sunucu, biletId: string, y: FisYardimcilari): Promise<FisVerisi> {
  const [biletler, ayarlar] = await Promise.all([
    s.sec<FisBiletSatiri>('biletler', `select=${BILET_SUTUNLARI}&id=eq.${biletId}`),
    s.sec<{ ad: string }>('otopark_ayarlari', 'select=ad&limit=1'),
  ])
  const bilet = biletler[0]
  if (!bilet) throw new Error('Bilet bulunamadı.')
  const otopark = { ad: ayarlar[0] ? ayarlar[0].ad : '' }
  const fiyatlar = new Map<number, number>()

  // Only an open ticket that pays gets "Müşteri ne kadar kalacak?" (as FisSayfasi).
  if (bilet.durum !== 'ACIK' || bilet.abonman_id || !bilet.tarife_id) {
    return { bilet, otopark, secenekler: [], fiyatlar }
  }
  const tarifeler = await s.sec<Pick<Tarife, 'id' | 'tur' | 'kademeler'>>(
    'tarifeler',
    `select=id,tur,kademeler&id=eq.${bilet.tarife_id}`,
  )
  const secenekler = y.fisTahminSecenekleri(tarifeler[0], { araliklar: y.kademeAraliklari, sure: y.sureMetni })
  for (const parca of y.parcala(
    secenekler.map((x) => x.dakika),
    TAHMIN_PARCA,
  )) {
    const satirlar = await s.rpc<{ dakika: number; kurus: number }[]>('fis_tahmini', {
      p_bilet_id: biletId,
      p_dakikalar: parca,
    })
    for (const r of satirlar) fiyatlar.set(r.dakika, r.kurus)
  }
  return { bilet, otopark, secenekler, fiyatlar }
}

/** Takes this print's number first; a refused number means nothing prints. */
export async function girisFisiBas(
  s: Sunucu,
  v: { bilet: FisBileti; otopark: FisOtopark; tahmin: { dakika: number; kurus: number } | null },
  simdi: () => string,
  y: FisYardimcilari,
): Promise<FisSatiri[]> {
  const basim = await s.rpc<number>('fis_basildi', {
    p_bilet_id: v.bilet.id,
    p_tur: 'GIRIS',
    p_tahmin_dk: v.tahmin ? v.tahmin.dakika : null,
  })
  return y.girisFisi({ otopark: v.otopark, bilet: v.bilet, basim, basimAt: simdi(), tahmin: v.tahmin }, y.fis)
}
