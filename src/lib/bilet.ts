import type { AcikBilet, Bilet, OnayDurum } from './types'

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
 * The fee a ticket screen shows, or null when there is none to show (a
 * cancelled ticket) or it is not known yet (the live price is still loading).
 *
 * An OPEN ticket's `ucret_kurus` stays 0 until exit, so reading `biletBorcu`
 * there printed ₺0 — or a negative amount once points were used — for a car
 * still inside. Open tickets take the server's live price (`ucret_hesapla`,
 * the same one Tahsilat shows and `bilet_kapat` charges), minus points,
 * floored at 0; an abonman stays free, as `bilet_kapat` makes it.
 */
export function gosterilenUcret(
  b: Pick<Bilet, 'durum' | 'ucret_kurus' | 'indirim_kurus' | 'abonman_id'>,
  canliUcretKurus: number | null | undefined,
): number | null {
  if (b.durum === 'IPTAL') return null
  if (b.durum === 'KAPALI') return b.ucret_kurus - b.indirim_kurus
  if (b.abonman_id) return 0
  if (canliUcretKurus == null) return null
  return Math.max(0, canliUcretKurus - b.indirim_kurus)
}

/**
 * Where a stay ends: the exit, or — for a ticket cancelled while the car was
 * inside — the cancellation, because bilet_iptal writes no `cikis_at`. Null
 * only for an open ticket, which counts up to now. Without the second case a
 * cancelled ticket's duration kept growing on screen forever.
 */
export function sureBitisi(
  b: Pick<Bilet, 'durum' | 'cikis_at' | 'iptal_at'>,
): string | null {
  if (b.cikis_at) return b.cikis_at
  if (b.durum === 'IPTAL') return b.iptal_at
  return null
}

/**
 * F14 (1.4.2): flag a car on the İçeride list that has been inside longer
 * than the "Terk edilmiş olabilir" threshold (`terk_esik_saat`, the SAME
 * setting the nightly notification uses — one number for both). Its exit may
 * have been missed. An abonman car may stay that long, so it is never
 * flagged. A missing / non-positive threshold or an unreadable entry time
 * flags nothing: a wrong warning is worse than none.
 */
export function uzunKalan(
  b: Pick<AcikBilet, 'giris_at' | 'abonman_id'>,
  esikSaat: number | null | undefined,
  simdi: Date = new Date(),
): boolean {
  if (b.abonman_id) return false
  if (typeof esikSaat !== 'number' || !Number.isFinite(esikSaat) || esikSaat <= 0) return false
  const giris = Date.parse(b.giris_at)
  if (Number.isNaN(giris)) return false
  return simdi.getTime() - giris >= esikSaat * 3_600_000
}

/**
 * Whether the money was taken. One field, and deliberately the same one the
 * "Ödeme" filter queries — a badge that disagreed with the filter that found
 * the row would be worse than no badge.
 */
export function odemeAlindi(b: Bilet): boolean {
  return b.tahsil_kurus > 0
}

/**
 * Which "Araç çıkmadı" box a ticket gets, or null for none (owner, 2026-11-15).
 *
 * 'KAMERA': the camera closed it and no money was taken — 054's box, no
 * reason asked (`bilet_kamera_geri_ac`). 'SEBEPLI': any other closed ticket —
 * a person gave the exit, or the debt was already collected — so a reason is
 * required and any payment is reversed (`bilet_cikis_geri_al`, 060). The
 * server checks everything again (own shift, no other open ticket).
 */
export function cikisGeriAlma(
  b: Pick<Bilet, 'durum' | 'cikis_kaynak' | 'tahsil_kurus'>,
): 'KAMERA' | 'SEBEPLI' | null {
  if (b.durum !== 'KAPALI') return null
  return b.cikis_kaynak === 'KAMERA' && b.tahsil_kurus <= 0 ? 'KAMERA' : 'SEBEPLI'
}

/**
 * May this user act on a closed ticket — collect it, make it free, undo the
 * exit (067)? Personel read the last 3 days of exits but act only on a ticket
 * closed in their OWN open shift; the Yönetici on any. The server checks the
 * same thing in every one of those functions (034, 066, 054, 060) — this only
 * keeps the screen from offering a button that will be refused.
 */
export function kapaliBiletIslemYapabilir(
  b: Pick<Bilet, 'kapatan_vardiya_id'>,
  yonetici: boolean,
  acikVardiyaId: string | null | undefined,
): boolean {
  if (yonetici) return true
  return Boolean(b.kapatan_vardiya_id) && b.kapatan_vardiya_id === acikVardiyaId
}

/**
 * Whether a failed exit failed because the ticket is no longer open — the
 * server's `bilet_kapat` message (030). Since 054 the camera closes a ticket
 * UNPAID the moment it sees the car leave, which can land while the cashier
 * is still on the collect screen; the money is then taken on the ticket's own
 * page ("Ödeme topla"), so the screen sends them there instead of showing a
 * dead end.
 */
export function zatenKapandi(mesaj: string): boolean {
  return mesaj.includes('zaten kapatılmış')
}
