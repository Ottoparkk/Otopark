/**
 * Çözülmemiş kayıtlar on the terminal: the same calls as
 * src/features/istisna/api.ts (tests/terminalIslem.check.mjs).
 */
import type { Istisna } from '../../src/lib/types'
import type { Sunucu } from './sunucu'
import type { PlakaAraclari } from './giseIslem'

function plakaHazirla(plaka: string, a: PlakaAraclari): string {
  const p = a.normalizePlaka(plaka)
  if (!a.plakaGecerli(p)) throw new Error('Plakayı kontrol edin.')
  return p
}

export interface IstisnaBiletSonuc {
  bilet_id: string
  plaka: string
  yer_kod: string | null
  zaten_vardi: boolean
}

export function bekleyenIstisnalar(s: Sunucu): Promise<Istisna[]> {
  return s.sec<Istisna>('istisnalar', 'select=*&cozuldu_at=is.null&order=created_at.desc&limit=200')
}

/** "Kapat": resolved without a ticket; the Yönetici sees it under Kapatılan. */
export async function istisnaKapat(s: Sunucu, id: string, not: string): Promise<void> {
  await s.rpc('istisna_coz', { p_id: id, p_not: not.trim() || null })
}

export async function istisnaBiletAc(s: Sunucu, id: string, plaka: string, a: PlakaAraclari): Promise<IstisnaBiletSonuc> {
  const p = plakaHazirla(plaka, a)
  return s.rpc<IstisnaBiletSonuc>('istisna_bilet_ac', { p_id: id, p_plaka: p })
}

export async function istisnaBiletAcSaatli(
  s: Sunucu,
  id: string,
  plaka: string,
  girisIso: string,
  sebep: string,
  a: PlakaAraclari,
): Promise<IstisnaBiletSonuc> {
  const p = plakaHazirla(plaka, a)
  if (!sebep.trim()) throw new Error('Sebep yazın.')
  return s.rpc<IstisnaBiletSonuc>('istisna_bilet_ac_saatli', {
    p_id: id,
    p_plaka: p,
    p_giris_at: girisIso,
    p_sebep: sebep.trim(),
  })
}
