/**
 * Süre aşımı onayı (082). On a KADEMELI tariff a normal ticket stops at the
 * first tier's price; the full tariff price needs a person's "Onayla". The
 * server decides whether a ticket is over (bilet_asim_onizle returns a row
 * only then) and enforces the decision before exit and collection; this only
 * picks what the ticket screen shows.
 *
 * Only `import type` here — tests/asim.check.mjs imports this file in Node.
 */

export type AsimKarar = 'TAM' | 'ILK'
export type AsimDurumu = 'YOK' | 'BEKLIYOR' | AsimKarar

export interface AsimOnizleme {
  ilk_kurus: number
  tam_kurus: number
}

export interface AsimBilet {
  abonman_id: string | null
  anlasma_kurus?: number | null
  asim_karar?: AsimKarar | null
  ucretsiz_sebep?: string | null
  ucret_degistirildi?: boolean | null
}

export function asimDurumu(b: AsimBilet, onizle: AsimOnizleme | null | undefined): AsimDurumu {
  if (b.asim_karar === 'TAM' || b.asim_karar === 'ILK') return b.asim_karar
  // Abonman, a deal, a free exit and a hand-set fee are each a decision already.
  if (b.abonman_id || b.anlasma_kurus != null || b.ucretsiz_sebep || b.ucret_degistirildi) return 'YOK'
  return onizle && onizle.tam_kurus > onizle.ilk_kurus ? 'BEKLIYOR' : 'YOK'
}

export function asimKararMetni(karar: AsimKarar, ad: string | null | undefined): string {
  const metin = karar === 'TAM' ? 'Tam ücret onaylandı' : 'İlk kademe ücreti bırakıldı'
  return ad ? `${metin} · ${ad}` : metin
}
