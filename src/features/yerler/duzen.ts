import type { ParkYeri, ParkYeriTip } from '../../lib/types'

/**
 * How the lot plan is arranged on screen.
 *
 * ONE arrangement: bays along the top and both sides, an island in the middle.
 * There was a second (islands back to back) behind a switch, and the switch is
 * gone — a view preference that every operator would set the same way is a
 * control that only ever costs a tap.
 *
 * It places bays in CODE ORDER into a stylised shape and does not know where a
 * bay physically is. Making the plan match the ground would mean storing a
 * position per bay and an editor to set it; until that exists, "P-14 is the
 * second bay down the left side" is a fact about this screen, not about the
 * car park.
 */

export interface CevrePlani<T> {
  ust: T[]
  sol: T[]
  orta: T[]
  sag: T[]
}

/** Eight across the top: one row on a desktop, two rows of four on a phone. */
const UST = 8
/** Below this there is no ring worth drawing — one row reads better. */
const EN_AZ = 12

/**
 * Bays dealt around the edge of the plan, then into the island in the middle.
 *
 * The top edge takes a fixed count rather than a share, because it is the one
 * region whose width is fixed by the grid; the sides take a quarter of what is
 * left each, and the island gets the rest. A small block skips the ring
 * entirely — four bays arranged around a courtyard is a diagram of nothing.
 *
 * THE ORDER IS A WALK, not four independent slices: across the top, down the
 * left, through the middle, then down the right. That is what puts the highest
 * code in the last tile of the plan — the right column used to take the slice
 * before the island, so a 50-bay lot ended at P-30 with P-50 stranded in the
 * middle, and the plan read as if it were numbered at random.
 */
export function cevreyeBol<T>(yerler: T[]): CevrePlani<T> {
  if (yerler.length < EN_AZ) return { ust: yerler, sol: [], orta: [], sag: [] }
  const ust = yerler.slice(0, UST)
  const kalan = yerler.slice(UST)
  const yan = Math.max(1, Math.round(kalan.length * 0.25))
  return {
    ust,
    sol: kalan.slice(0, yan),
    orta: kalan.slice(yan, kalan.length - yan),
    sag: kalan.slice(kalan.length - yan),
  }
}

/* ----------------------------------------------------------------- blocks */

export interface BlokOrtak {
  /** The type every bay in the block shares, or null when they differ. */
  tip: ParkYeriTip | null
  /** True only when EVERY bay in the block is reserved. */
  rezerve: boolean
}

/**
 * What a whole block has in common.
 *
 * The header says it once and the bays stop repeating it, which is the only
 * way a chip fits on a tile this small — and in practice it is nearly always
 * shared, since the generated scheme puts engelli and rezerve bays in blocks
 * of their own. A bay that differs from its block still carries its own chip;
 * that is exactly the case worth drawing attention to.
 */
export function blokOrtak(yerler: ParkYeri[]): BlokOrtak {
  const ilk = yerler[0]
  if (!ilk) return { tip: null, rezerve: false }
  return {
    tip: yerler.every((y) => y.tip === ilk.tip) ? ilk.tip : null,
    rezerve: yerler.every((y) => y.rezerve),
  }
}
