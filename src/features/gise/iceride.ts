/**
 * How much of the İçeride list is drawn.
 *
 * Owner, 2026-11-22: on a slow device (the P2, Chrome 119, 1 GB) creating
 * every row was the biggest cost of opening Gişe, so the list opens with the
 * first 25 cars and "Daha fazla göster" adds 25 at a time.
 *
 * Two rules keep it from hiding a car:
 * - Nothing goes silently: `kalan` is how many are behind the button and
 *   `kalanUzun` how many of THOSE are long-stayers. The list is newest first
 *   (acik_bilet_ara, 052), so the cars a cut hides are exactly the oldest —
 *   the possibly-abandoned ones the button must name.
 * - A search is never cut: once anything is typed, every match is drawn, so
 *   finding a car never depends on the button.
 *
 * Pure and import-free so tests/iceride.check.mjs can run it under Node; the
 * long-stay rule (`uzunKalan`, src/lib/bilet.ts) is passed in.
 */
export const ICERIDE_SAYFA = 25

export function icerideGorunen<T>(
  liste: readonly T[],
  adet: number,
  aramaVar: boolean,
  uzunMu: (b: T) => boolean,
): { gorunen: T[]; kalan: number; kalanUzun: number } {
  if (aramaVar || liste.length <= adet) {
    return { gorunen: liste.slice(), kalan: 0, kalanUzun: 0 }
  }
  const gizli = liste.slice(adet)
  return {
    gorunen: liste.slice(0, adet),
    kalan: gizli.length,
    kalanUzun: gizli.filter(uzunMu).length,
  }
}

/**
 * 077 H: "İçeride görüldü 14:35" — the single-gate bridge last saw this
 * open-ticket car moving inside the yard (`iceride_goruldu_at`). Null when it
 * never did, or before 077 ran (the field is then absent). The clock format
 * is passed in (formatSaat: Istanbul time) so Node can check this file.
 */
export function icerideGorulduMetni(
  bilet: { iceride_goruldu_at?: string | null },
  saat: (iso: string) => string,
): string | null {
  return bilet.iceride_goruldu_at ? `İçeride görüldü ${saat(bilet.iceride_goruldu_at)}` : null
}
