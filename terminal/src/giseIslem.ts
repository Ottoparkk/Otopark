/**
 * Gişe and ticket calls for the terminal (owner 28.11: the whole Personel
 * app). The same RPCs and arguments as src/features/gise/api.ts — no new
 * rights; the server re-checks everything. Type-only imports; plate helpers
 * come in as `a` (tests/terminalIslem.check.mjs).
 */
import type { AcikBilet, Bilet, BiletKapatSonuc, GunlukOzet, OdemeYontemi, UcretsizSebep } from '../../src/lib/types'
import type { AsimOnizleme } from '../../src/features/gise/asim'
import type { normalizePlaka, plakaGecerli } from '../../src/lib/plaka'
import type { Sunucu } from './sunucu'

export interface PlakaAraclari {
  normalizePlaka: typeof normalizePlaka
  plakaGecerli: typeof plakaGecerli
}

export type CikanBilet = Pick<
  Bilet,
  | 'id'
  | 'plaka'
  | 'giris_at'
  | 'cikis_at'
  | 'ucret_kurus'
  | 'indirim_kurus'
  | 'tahsil_kurus'
  | 'abonman_id'
  | 'yikama_kurus'
  | 'ucretsiz_sebep'
  | 'cikis_kaynak'
  | 'durum'
>

const CIKAN_SUTUNLARI =
  'id,plaka,giris_at,cikis_at,ucret_kurus,indirim_kurus,tahsil_kurus,abonman_id,yikama_kurus,ucretsiz_sebep,cikis_kaynak,durum'

export async function gunlukOzet(s: Sunucu): Promise<GunlukOzet | null> {
  const r = await s.rpc<GunlukOzet[] | null>('gunluk_ozet', {})
  return (r && r[0]) || null
}

export async function acikBiletler(s: Sunucu, q: string): Promise<AcikBilet[]> {
  return (await s.rpc<AcikBilet[] | null>('acik_bilet_ara', { p_q: q })) || []
}

/** Exits since `basIso` (today's Istanbul midnight); RLS decides the rest. */
export function cikanlar(s: Sunucu, basIso: string): Promise<CikanBilet[]> {
  return s.sec<CikanBilet>(
    'biletler',
    `select=${CIKAN_SUTUNLARI}&durum=eq.KAPALI&cikis_at=gte.${encodeURIComponent(basIso)}&order=cikis_at.desc,id.desc&limit=30`,
  )
}

export async function biletAl(s: Sunucu, id: string): Promise<Bilet> {
  const r = await s.sec<Bilet>('biletler', `select=*&id=eq.${id}`)
  if (!r[0]) throw new Error('Bilet bulunamadı.')
  return r[0]
}

export async function ucretOnizle(s: Sunucu, id: string): Promise<number> {
  const r = await s.rpc<number | null>('bilet_ucret_onizle', { p_bilet_id: id })
  return r === null || r === undefined ? 0 : r
}

/** The caller's open shift, for "closed ticket: own shift only" (067). */
export async function vardiyamId(s: Sunucu): Promise<string | null> {
  const r = await s.rpc<{ vardiya_id: string }[] | null>('vardiya_ozetim', {})
  return (r && r[0] && r[0].vardiya_id) || null
}

export async function yikamaUcreti(s: Sunucu): Promise<number | null> {
  const r = await s.sec<{ yikama_kurus: number | null }>('tarifeler', 'select=yikama_kurus&gecerli_bitis=is.null&limit=1')
  return r[0] && typeof r[0].yikama_kurus === 'number' ? r[0].yikama_kurus : null
}

export async function biletKapat(s: Sunucu, id: string, yontem: OdemeYontemi | null): Promise<BiletKapatSonuc> {
  const r = await s.rpc<BiletKapatSonuc[] | null>('bilet_kapat', {
    p_bilet_id: id,
    p_odeme_yontemi: yontem,
    p_ucret_override_kurus: null,
    p_sebep: null,
    p_foto: null,
    p_kaynak: 'MOBIL',
    p_tahsil: true,
  })
  if (!r || !r[0]) throw new Error('Tahsilat sonucu alınamadı.')
  return r[0]
}

export async function biletTahsil(s: Sunucu, id: string, yontem: OdemeYontemi): Promise<void> {
  await s.rpc('bilet_tahsil', { p_bilet_id: id, p_odeme_yontemi: yontem })
}

export async function ucretsizCikis(s: Sunucu, id: string, sebep: UcretsizSebep, not: string): Promise<void> {
  await s.rpc('bilet_ucretsiz_cikis', { p_bilet_id: id, p_sebep: sebep, p_not: not.trim() })
}

export async function kameraGeriAc(s: Sunucu, id: string): Promise<void> {
  await s.rpc('bilet_kamera_geri_ac', { p_bilet_id: id })
}

export async function cikisGeriAl(s: Sunucu, id: string, sebep: string): Promise<void> {
  if (!sebep.trim()) throw new Error('Sebep yazın.')
  await s.rpc('bilet_cikis_geri_al', { p_bilet_id: id, p_sebep: sebep.trim() })
}

/** A Personel's İptal is a request the Yönetici approves (050). */
export async function iptalIste(s: Sunucu, id: string, sebep: string): Promise<void> {
  if (!sebep.trim()) throw new Error('İptal sebebi zorunludur.')
  await s.rpc('bilet_iptal', { p_bilet_id: id, p_sebep: sebep.trim() })
}

export async function yikama(s: Sunucu, id: string, acik: boolean): Promise<void> {
  await s.rpc('bilet_yikama', { p_bilet_id: id, p_acik: acik })
}

export async function anlasma(s: Sunucu, id: string, kurus: number, saat: number): Promise<void> {
  await s.rpc('bilet_anlasma', { p_bilet_id: id, p_kurus: kurus, p_saat: saat })
}

export async function asimOnizle(s: Sunucu, id: string): Promise<AsimOnizleme | null> {
  const r = await s.rpc<AsimOnizleme[] | null>('bilet_asim_onizle', { p_bilet_id: id })
  return (r && r[0]) || null
}

export async function asimKarar(s: Sunucu, id: string, tam: boolean): Promise<void> {
  await s.rpc('bilet_asim_karar', { p_bilet_id: id, p_tam: tam })
}

function plakaHazirla(plaka: string, a: PlakaAraclari): string {
  const p = a.normalizePlaka(plaka)
  if (!a.plakaGecerli(p)) throw new Error('Plakayı kontrol edin.')
  return p
}

export async function plakaDuzelt(s: Sunucu, id: string, plaka: string, a: PlakaAraclari): Promise<void> {
  const p = plakaHazirla(plaka, a)
  await s.rpc('bilet_plaka_duzelt', { p_bilet_id: id, p_plaka: p })
}

export function kayipBilet(
  s: Sunucu,
  plaka: string,
  yontem: OdemeYontemi,
  islemId: string,
  a: PlakaAraclari,
): Promise<string> {
  let p: string
  try {
    p = plakaHazirla(plaka, a)
  } catch (e) {
    return Promise.reject(e)
  }
  return s.rpc<string>('kayip_bilet_tahsil', { p_plaka: p, p_odeme_yontemi: yontem, p_islem_id: islemId })
}

export async function acikIstisnaSayisi(s: Sunucu): Promise<number> {
  return (await s.sec<{ id: string }>('istisnalar', 'select=id&cozuldu_at=is.null&limit=200')).length
}

