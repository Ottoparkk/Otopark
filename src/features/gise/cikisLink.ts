// "Çıkış" from Çözülmemiş kayıtlar. There is no separate exit screen any more
// — /gise/cikis renders Gişe — so the link alone landed on the plain gate with
// nothing about the car, which read as "nothing happened" (owner,
// 2026-11-15). The card's plate now travels in the router state and becomes
// Gişe's search; Gişe also puts the cursor in that search, so an unread plate
// is typed there straight away. No imports: `node tests/cikisLink.check.mjs`
// runs this file directly.

const temizle = (s: string) => s.replace(/\s+/g, '').toUpperCase()

/** Where the card's "Çıkış" goes, carrying whatever its plate field holds. */
export function cikisLinki(plaka: string): { to: string; state: { cikisAra: string } } {
  return { to: '/gise/cikis', state: { cikisAra: temizle(plaka) } }
}

/**
 * On Gişe: the search to start with when the page was opened as "Çıkış", or
 * null for any other way in. '' still means "focus the search".
 */
export function cikisAramasi(pathname: string, state: unknown): string | null {
  if (!pathname.endsWith('/cikis')) return null
  const ara = (state as { cikisAra?: unknown } | null)?.cikisAra
  return typeof ara === 'string' ? temizle(ara) : ''
}
