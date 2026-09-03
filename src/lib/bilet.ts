import type { Bilet, OnayDurum } from './types'

/**
 * The approval state of the money a ticket took, or null when it took none.
 *
 * The LIVE collection is the one without `iptal_of` — a cancelled ticket also
 * carries the reversal that undid it, and reading that row's state would
 * describe the correction rather than the charge.
 *
 * Null is a real answer, not a missing one: a ₺0 exit — an abonman holder, or
 * a fee fully covered by points — writes no collection at all, so there is
 * nothing to approve. Rendering "Onaylanmadı" there would invent a problem.
 *
 * Shared rather than local to one screen: Gişe and Finans describe the same
 * fact about the same ticket, and two copies of this rule would eventually
 * disagree about a cancelled one.
 */
export function onayDurumu(b: Bilet): OnayDurum | null {
  return b.tahsilat?.find((t) => t.iptal_of === null)?.durum ?? null
}

/**
 * What the stay cost after any points discount — what is owed, or what was.
 *
 * Read from the ticket rather than from the collection, because since 027 a
 * ticket can be closed WITHOUT taking the money: `tahsil_kurus` then says 0
 * while the driver still owes this.
 */
export function biletBorcu(b: Bilet): number {
  return b.ucret_kurus - b.indirim_kurus
}

/**
 * Whether the money was taken. One field, and deliberately the same one the
 * "Ödeme" filter queries — a badge that disagreed with the filter that found
 * the row would be worse than no badge.
 */
export function odemeAlindi(b: Bilet): boolean {
  return b.tahsil_kurus > 0
}
