/**
 * Pull-to-refresh maths (CekYenile). Pure, no imports — checked by
 * `node tests/cekYenile.check.mjs`.
 *
 * The indicator moves half as far as the finger (resistance, so it feels
 * attached but heavy) and stops at EN_COK. A refresh needs ESIK of indicator
 * travel — about 128 px of finger — so an ordinary flick at the top of a list
 * never refreshes by accident.
 */

/** Furthest the indicator travels, px. */
export const EN_COK = 96
/** Indicator travel that triggers a refresh on release, px. */
export const ESIK = 64

/** Finger travel down (px) → indicator travel (px). */
export function cekmeMesafesi(dy: number): number {
  if (!(dy > 0)) return 0
  return Math.min(EN_COK, dy / 2)
}

/** Released here → refresh? */
export function yenilensinMi(mesafe: number): boolean {
  return mesafe >= ESIK
}

/** 0–1 towards the threshold (drives the arc and the opacity). */
export function ilerleme(mesafe: number): number {
  if (!(mesafe > 0)) return 0
  return Math.min(1, mesafe / ESIK)
}
