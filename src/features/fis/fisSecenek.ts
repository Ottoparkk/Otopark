/**
 * The entry fiş's "Müşteri ne kadar kalacak?" choices (owner 28.11: the same
 * as the tariff's bands — 0–2, 2–4, 4–8, 8–24 saat).
 *
 * Each choice's minutes are its band's UPPER bound, so the server
 * (`fis_tahmini`, 088) prices it at exactly that band's price. A tariff
 * without bands (SÜRELİ / SABİT) keeps the old fixed hour list.
 *
 * Pure, with only `import type`: Node cannot resolve the app's extensionless
 * imports, so the helpers come in as arguments (tests/fisSecenek.check.mjs
 * passes the real ones).
 */
import type { Tarife } from '../../lib/types'

export interface FisTahminSecenegi {
  dakika: number
  etiket: string
}

export interface FisSecenekYardimcilari {
  /** `kademeAraliklari` from finans/kademe.ts. */
  araliklar: (liste: { dakika: number; kurus: number }[]) => { etiket: string }[]
  /** `sureMetni` from fisIcerik.ts. */
  sure: (dakika: number) => string
}

/** Used when the ticket's tariff has no bands. */
const SABIT_SECENEKLER = [60, 120, 180, 240, 360]

export function fisTahminSecenekleri(
  tarife: Pick<Tarife, 'tur' | 'kademeler'> | null | undefined,
  y: FisSecenekYardimcilari,
): FisTahminSecenegi[] {
  if (!tarife) return []
  const k = tarife.kademeler
  if (tarife.tur === 'KADEMELI' && k && k.length > 0) {
    const etiketler = y.araliklar(k)
    return k.map((x, i) => ({ dakika: x.dakika, etiket: etiketler[i]?.etiket ?? y.sure(x.dakika) }))
  }
  return SABIT_SECENEKLER.map((dakika) => ({ dakika, etiket: y.sure(dakika) }))
}

/** `fis_tahmini` takes at most 6 minutes per call; a tariff may have 12 bands. */
export function parcala<T>(liste: readonly T[], boyut: number): T[][] {
  const parcalar: T[][] = []
  for (let i = 0; i < liste.length; i += boyut) parcalar.push(liste.slice(i, i + boyut))
  return parcalar
}
