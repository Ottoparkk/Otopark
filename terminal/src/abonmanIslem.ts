/**
 * Abonman on the terminal: list, one abonman, its payments, and "Tahsilat
 * al" — every staff role collects (062). Same calls as
 * src/features/abonman/api.ts (tests/terminalIslem.check.mjs).
 */
import type { Abonman, OdemeYontemi, Tahsilat } from '../../src/lib/types'
import type { Sunucu } from './sunucu'

export function abonmanlar(s: Sunucu): Promise<Abonman[]> {
  return s.sec<Abonman>('abonmanlar', 'select=*&order=bitis.asc')
}

export async function abonmanAl(s: Sunucu, id: string): Promise<Abonman> {
  const r = await s.sec<Abonman>('abonmanlar', `select=*&id=eq.${id}`)
  if (!r[0]) throw new Error('Abonman bulunamadı.')
  return r[0]
}

export function abonmanTahsilatlari(s: Sunucu, id: string): Promise<Tahsilat[]> {
  return s.sec<Tahsilat>('tahsilatlar', `select=*&abonman_id=eq.${id}&order=created_at.desc`)
}

export async function abonmanTahsil(
  s: Sunucu,
  g: { id: string; yontem: OdemeYontemi; tutar: number; yenile: boolean },
): Promise<void> {
  if (!(g.tutar > 0)) throw new Error('Tutar girin.')
  await s.rpc('abonman_tahsil', {
    p_abonman_id: g.id,
    p_yontem: g.yontem,
    p_tutar_kurus: g.tutar,
    p_yenile: g.yenile,
  })
}
