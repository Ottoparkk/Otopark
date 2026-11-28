/**
 * Oto yıkama (078) — display helpers only. The server prices everything:
 * `acik_bilet_ara` / `bilet_ucret_onizle` return parking + wash (abonman:
 * wash only), and these helpers only split or label those numbers.
 *
 * No runtime imports (tests/yikama.check.mjs runs this file in Node, which
 * cannot resolve the app's extensionless paths): the formatter is passed in.
 */

export interface YikamaUcretli {
  abonman_id: string | null
  ucret_kurus: number
  indirim_kurus: number
  yikama_kurus: number | null
}

/** The fee line on an İçeride card: "Ücretsiz", "Ücretsiz + 150 ₺" or the net. */
export function listeUcretMetni(b: YikamaUcretli, formatTL: (kurus: number) => string): string {
  if (b.abonman_id) {
    return b.yikama_kurus ? `Ücretsiz + ${formatTL(b.yikama_kurus)}` : 'Ücretsiz'
  }
  return formatTL(Math.max(0, b.ucret_kurus - b.indirim_kurus))
}

/**
 * What points may pay for: the parking part only. `puan_kullan` caps points
 * against `ucret_hesapla` (the stay), so the wash is never paid in points —
 * and a washed car inside its free minutes is offered none.
 */
export function puanaAcikKurus(netKurus: number, yikamaKurus: number | null): number {
  return otoparkKurus(netKurus, yikamaKurus)
}

/** The "Otopark" row of the Hizmetler card: the total without the wash. */
export function otoparkKurus(toplamKurus: number, yikamaKurus: number | null): number {
  return Math.max(0, toplamKurus - (yikamaKurus ?? 0))
}
