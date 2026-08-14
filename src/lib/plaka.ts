/**
 * Turkish plate handling.
 *
 * `public.normalize_plaka()` in Postgres is authoritative and runs inside
 * every write. These are the client-side mirror for display and for
 * comparing what the operator typed against what OCR suggested.
 *
 * Validation is deliberately PERMISSIVE: a regex that rejects a valid plate
 * blocks a paying customer at the barrier. Odd input warns, it does not
 * block. The only hard floor is the DB check: 2-15 chars of [A-Z0-9].
 */

/** Folds Turkish letters BEFORE upper-casing — upper('ı') is locale-dependent. */
export function normalizePlaka(raw: string): string {
  return raw
    .replace(/[ıİ]/g, 'I')
    .replace(/[çÇ]/g, 'C')
    .replace(/[ğĞ]/g, 'G')
    .replace(/[öÖ]/g, 'O')
    .replace(/[şŞ]/g, 'S')
    .replace(/[üÜ]/g, 'U')
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, '')
}

/** What the database will accept. Anything else is refused before the call. */
export function plakaGecerli(plaka: string): boolean {
  return /^[A-Z0-9]{2,15}$/.test(normalizePlaka(plaka))
}

/**
 * True when the plate matches a standard Turkish layout. Used ONLY to show a
 * soft "bu plaka alışılmadık görünüyor" hint — never to block a submit.
 *   34 A 1234 · 34 AB 123 · 34 ABC 12
 */
export function plakaOlagan(plaka: string): boolean {
  const p = normalizePlaka(plaka)
  return /^(0[1-9]|[1-7][0-9]|8[01])[A-Z]{1,3}\d{2,5}$/.test(p) && p.length >= 5 && p.length <= 8
}

/** "34ABC123" -> "34 ABC 123". Unrecognised shapes are returned unchanged. */
export function formatPlaka(plaka: string): string {
  const p = normalizePlaka(plaka)
  const m = /^(\d{2})([A-Z]{1,3})(\d{2,5})$/.exec(p)
  return m ? `${m[1]} ${m[2]} ${m[3]}` : p
}

/**
 * The fuzzy match the exit screen uses locally while the server search is in
 * flight. Mirrors `acik_bilet_ara`'s ranking so the list does not reorder
 * under the operator's thumb when the real results land.
 */
export function plakaSkoru(plaka: string, sorgu: string): number {
  const p = normalizePlaka(plaka)
  const q = normalizePlaka(sorgu)
  if (!q) return 2
  if (p === q) return 0
  if (p.startsWith(q)) return 1
  if (p.includes(q)) return 2
  if (q.length >= 3 && p.endsWith(q)) return 2
  return -1 // no match
}
