import type { Abonman } from './types'

// Abonman payment day (owner, 2026-11-15): instead of a start and an end date
// the form asks for the day of the month the customer pays — "Ayın 13'ü".
// 29–31 fall on the month's last day in a shorter month.
//
// The SERVER decides the dates (062: `abonman_sonraki_yenileme`, used by
// `abonman_ekle` and `abonman_tahsil`); this file only previews them. The two
// must agree — tests/abonman.check.mjs and PASS 80b check the same table.
// Type-only imports: `node tests/abonman.check.mjs` runs this file directly.

function parcala(gun: string): [number, number, number] | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(gun)
  if (!m) return null
  const [y, a, g] = [Number(m[1]), Number(m[2]), Number(m[3])]
  if (a < 1 || a > 12 || g < 1 || g > ayinSonGunu(y, a)) return null
  return [y, a, g]
}

/** Days in month `a` (1–12) of year `y`. */
function ayinSonGunu(y: number, a: number): number {
  return new Date(Date.UTC(y, a, 0)).getUTCDate()
}

function yaz(y: number, a: number, g: number): string {
  return `${y}-${String(a).padStart(2, '0')}-${String(g).padStart(2, '0')}`
}

/**
 * The first date strictly AFTER `tarih` ('YYYY-MM-DD') that falls on payment
 * day `gun` — or on the month's last day when the month is shorter. Null for
 * a day outside 1–31 or a malformed date.
 */
export function sonrakiYenileme(gun: number, tarih: string): string | null {
  if (!Number.isInteger(gun) || gun < 1 || gun > 31) return null
  const p = parcala(tarih)
  if (!p) return null
  const [y, a, g] = p
  const buAy = Math.min(gun, ayinSonGunu(y, a))
  if (buAy > g) return yaz(y, a, buAy)
  const [y2, a2] = a === 12 ? [y + 1, 1] : [y, a + 1]
  return yaz(y2, a2, Math.min(gun, ayinSonGunu(y2, a2)))
}

/**
 * The period a payment with "Dönemi uzat" buys (062's `abonman_tahsil`):
 * still running (AKTIF and the end date not yet past) → continues from the
 * end date, the start is kept; otherwise a fresh period from today — days
 * already in the past are never sold. A missing payment day falls back to
 * the end date's day, like the server.
 */
export function yenilemeDonemi(
  a: Pick<Abonman, 'durum' | 'baslangic' | 'bitis' | 'yenileme_gunu'>,
  bugun: string,
): { bas: string; bit: string | null } {
  const gun = a.yenileme_gunu ?? Number(a.bitis.slice(8, 10))
  if (a.durum === 'AKTIF' && a.bitis >= bugun) {
    return { bas: a.baslangic, bit: sonrakiYenileme(gun, a.bitis) }
  }
  return { bas: bugun, bit: sonrakiYenileme(gun, bugun) }
}

// Turkish possessive after a number follows how it is READ: the last
// non-zero digit, or the tens word (on, yirmi, otuz) for 10/20/30.
const BIRLER = ['', 'i', 'si', 'ü', 'ü', 'i', 'sı', 'si', 'i', 'u']
const ONLAR: Record<number, string> = { 10: 'u', 20: 'si', 30: 'u' }

/** "Ayın 1'i", "Ayın 13'ü", "Ayın 20'si", "Ayın 31'i". */
export function ayinGunu(n: number): string {
  const ek = n % 10 === 0 ? (ONLAR[n] ?? '') : BIRLER[n % 10]
  return `Ayın ${n}'${ek}`
}
