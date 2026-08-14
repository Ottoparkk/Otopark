/**
 * `tstzrange` helpers for `rezervasyonlar.gecerlilik`.
 *
 * This is the only place in the app that touches a Postgres range literal, so
 * the two traps live here with the code that avoids them:
 *
 * 1. PostgREST serialises the range using the DATABASE's timezone, which on
 *    Supabase is UTC. A reservation stored as Istanbul midnight comes back as
 *    `2026-08-12 21:00:00+00` — so slicing the first ten characters off the
 *    string gives the WRONG DAY. Every read goes through a real Date and the
 *    Istanbul formatter instead.
 * 2. That serialised form is not ISO-8601 (`' '` instead of `'T'`, and a
 *    two-digit offset), and `new Date()` on it is engine-dependent. It is
 *    normalised first.
 *
 * Writes hardcode `+03:00`: Turkey has been UTC+3 year-round with no DST
 * since 2016, the same assumption `lib/dates.ts` already documents.
 */

import { istanbulGun } from './dates'

const ISTANBUL_OFFSET = '+03:00'

/**
 * An inclusive day range as a half-open tstzrange literal.
 * `2026-08-13 … 2026-09-12` becomes `[13 Aug 00:00, 13 Sep 00:00)` — the last
 * day is fully covered, and two ranges that merely touch do not overlap, which
 * is what lets a spot be re-let the day after a subscription ends.
 */
export function gunAraligi(basGun: string, bitGun: string): string {
  const ust = gunSonrasi(bitGun)
  return `["${basGun}T00:00:00${ISTANBUL_OFFSET}","${ust}T00:00:00${ISTANBUL_OFFSET}")`
}

/** 'YYYY-MM-DD' + 1 day, by UTC arithmetic on bare calendar numbers. */
function gunSonrasi(gun: string): string {
  const [y, m, d] = gun.split('-').map(Number)
  if (!y) return gun
  return new Date(Date.UTC(y, (m ?? 1) - 1, (d ?? 1) + 1)).toISOString().slice(0, 10)
}

/** Normalises Postgres's timestamp rendering into something Date can parse. */
function tarihCoz(raw: string): Date | null {
  const s = raw.trim().replace(' ', 'T')
  // '+03' -> '+03:00', '+0300' -> '+03:00'. A 'Z' or '+03:00' passes through.
  const fixed = s
    .replace(/([+-]\d{2})$/, '$1:00')
    .replace(/([+-]\d{2})(\d{2})$/, '$1:$2')
  const d = new Date(fixed)
  return Number.isNaN(d.getTime()) ? null : d
}

/**
 * Splits a range literal into its two bounds. Empty bound = unbounded.
 * Timestamps contain neither a comma nor a quote, so this stays simple.
 */
export function araligiCoz(range: string): { bas: Date | null; bit: Date | null } {
  const m = /^[[(]\s*"?([^",]*)"?\s*,\s*"?([^",]*)"?\s*[\])]$/.exec(range.trim())
  if (!m) return { bas: null, bit: null }
  return {
    bas: m[1] ? tarihCoz(m[1]) : null,
    bit: m[2] ? tarihCoz(m[2]) : null,
  }
}

/**
 * The inclusive Istanbul days a range covers, for display.
 * The upper bound is exclusive, so a millisecond is stepped back before the
 * day is read — otherwise every reservation would appear to run one day long.
 */
export function araligiGunler(range: string): { bas: string | null; bit: string | null } {
  const { bas, bit } = araligiCoz(range)
  return {
    bas: bas ? istanbulGun(bas) : null,
    bit: bit ? istanbulGun(new Date(bit.getTime() - 1)) : null,
  }
}

/** True while now falls inside the range. */
export function araliktaMi(range: string, now: Date = new Date()): boolean {
  const { bas, bit } = araligiCoz(range)
  if (bas && now < bas) return false
  if (bit && now >= bit) return false
  return true
}
