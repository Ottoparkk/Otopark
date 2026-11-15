/**
 * Çıkanlar date filter (067, owner 2026-11-15): an inclusive Istanbul day
 * range ('YYYY-MM-DD' … 'YYYY-MM-DD') as half-open `cikis_at` bounds,
 * [bas 00:00, bit+1 00:00). Writes hardcode +03:00: Turkey has been UTC+3
 * year-round since 2016 (lib/dates.ts, lib/aralik.ts).
 *
 * No imports: `node tests/cikisAraligi.check.mjs` runs this file directly.
 */
const ISTANBUL_OFFSET = '+03:00'

export function cikisAraligi(bas: string, bit: string): { gte: string; lt: string } {
  return {
    gte: `${bas}T00:00:00${ISTANBUL_OFFSET}`,
    lt: `${gunSonrasi(bit)}T00:00:00${ISTANBUL_OFFSET}`,
  }
}

/** 'YYYY-MM-DD' + 1 day, by UTC arithmetic on bare calendar numbers. */
function gunSonrasi(gun: string): string {
  const [y, m, d] = gun.split('-').map(Number)
  return new Date(Date.UTC(y!, (m ?? 1) - 1, (d ?? 1) + 1)).toISOString().slice(0, 10)
}
