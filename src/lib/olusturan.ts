import type { Kaynak } from './types'

/**
 * Who created a record, as one word the operator can read at a glance.
 *
 * The SOURCE is checked before the id, and that order is the whole point: a
 * camera has no profile row and never will — `bilet_ac` runs under the
 * webhook's service_role, so `giris_by` is null by construction. A null id on
 * its own cannot tell "the camera did this" apart from "the person who did it
 * is gone", and those are very different answers to give about a ticket.
 *
 * `adlar` comes from `profiles`, which active staff may already read (003's
 * `profiles_select`) — so this needs no widening of anyone's access.
 */
export function olusturanAdi(
  id: string | null,
  kaynak: Kaynak | null,
  adlar: Map<string, string>,
): string {
  if (kaynak === 'KAMERA') return 'Kamera'
  if (!id) return 'Otomatik'
  // A DISABLED account is invisible to Personel (only Yönetici reads those
  // rows), so a name that cannot be resolved is expected rather than broken.
  return adlar.get(id) ?? 'Bilinmiyor'
}
