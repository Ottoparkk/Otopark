/**
 * Turkish customer phone numbers.
 *
 * Stored as the bare national ten digits, no country code and no leading zero
 * — the shape `abonmanlar.musteri_tel` and `biletler.musteri_tel` both CHECK
 * (`^[1-9][0-9]{9}$`). Keeping the rule in one file is what stops the entry
 * form and the correction form disagreeing about what a valid number is; the
 * database holds the same rule again, because a client check is convenience,
 * never the boundary.
 */

/**
 * What we store: the bare national ten.
 *
 * The trunk prefixes are stripped rather than rejected, because people write
 * them — "0532 111 22 33" and "+90 532 111 22 33" are how a Turkish number is
 * actually dictated, and an operator who types one of those at a barrier
 * should not be told their entry is invalid. Every form of the same number
 * therefore stores identically.
 *
 * The `length > 10` guard on the country code is what keeps a genuine
 * ten-digit number beginning 90 intact; only a longer string can have had +90
 * prepended.
 */
export function normalizeTel(ham: string): string {
  let d = ham.replace(/\D/g, '')
  if (d.startsWith('90') && d.length > 10) d = d.slice(2)
  if (d.startsWith('0')) d = d.slice(1)
  return d.slice(0, 10)
}

/** Empty is allowed everywhere these fields appear — they are all optional. */
export function telGecerli(tel: string): boolean {
  const t = normalizeTel(tel)
  return t === '' || /^[1-9][0-9]{9}$/.test(t)
}

/** `0532 123 45 67` — grouped the way a Turkish number is read aloud. */
export function formatTel(tel: string | null): string {
  if (!tel) return ''
  const t = normalizeTel(tel)
  if (t.length !== 10) return t
  return `0${t.slice(0, 3)} ${t.slice(3, 6)} ${t.slice(6, 8)} ${t.slice(8)}`
}
