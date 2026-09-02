/**
 * Everything the operator sees is in Istanbul time, regardless of what the
 * device clock is set to. Turkey is UTC+3 year-round (no DST since 2016),
 * but these go through Intl with an explicit zone rather than a hardcoded
 * offset — a device in another timezone must still show lot-local times.
 */

const TZ = 'Europe/Istanbul'

const saatFmt = new Intl.DateTimeFormat('tr-TR', {
  timeZone: TZ,
  hour: '2-digit',
  minute: '2-digit',
})

const gunFmt = new Intl.DateTimeFormat('tr-TR', {
  timeZone: TZ,
  day: 'numeric',
  month: 'long',
})

const tamFmt = new Intl.DateTimeFormat('tr-TR', {
  timeZone: TZ,
  day: '2-digit',
  month: '2-digit',
  year: 'numeric',
  hour: '2-digit',
  minute: '2-digit',
})

const isoGunFmt = new Intl.DateTimeFormat('en-CA', {
  timeZone: TZ,
  year: 'numeric',
  month: '2-digit',
  day: '2-digit',
})

/** "14:35" */
export function formatSaat(iso: string | Date): string {
  return saatFmt.format(typeof iso === 'string' ? new Date(iso) : iso)
}

/** "12.08.2026 14:35" */
export function formatTam(iso: string | Date): string {
  return tamFmt.format(typeof iso === 'string' ? new Date(iso) : iso)
}

/** Istanbul calendar date as 'YYYY-MM-DD' — safe to compare as strings. */
export function istanbulGun(d: Date = new Date()): string {
  return isoGunFmt.format(d)
}

/**
 * Istanbul hour of day as 0–23, for bucketing entries into an hourly chart.
 *
 * `hourCycle: 'h23'` is load-bearing, not decoration. The default cycle for
 * many locales is h24, which formats midnight as "24" — that would push every
 * midnight arrival into a 25th bucket that no chart draws, silently losing the
 * quietest hour of the night. h23 gives "00".."23", which is what an array
 * index needs.
 */
const saatNoFmt = new Intl.DateTimeFormat('en-GB', {
  timeZone: TZ,
  hour: '2-digit',
  hourCycle: 'h23',
})

export function istanbulSaat(iso: string | Date): number {
  return Number(saatNoFmt.format(typeof iso === 'string' ? new Date(iso) : iso))
}

/**
 * "Bugün 14:35" / "Dün 09:10" / "8 Ağustos 14:35"
 * Relative to the ISTANBUL calendar day, not the device's — a phone left on
 * another timezone must not label this morning's entry as yesterday.
 */
export function formatGoreceli(iso: string): string {
  const d = new Date(iso)
  const hedef = istanbulGun(d)
  const bugun = istanbulGun()
  const dun = istanbulGun(new Date(Date.now() - 86_400_000))

  if (hedef === bugun) return `Bugün ${formatSaat(d)}`
  if (hedef === dun) return `Dün ${formatSaat(d)}`
  return `${gunFmt.format(d)} ${formatSaat(d)}`
}

/** "12.08.2026" from a 'YYYY-MM-DD' date column (no timezone shifting). */
export function formatTarih(gun: string): string {
  const [y, m, d] = gun.split('-')
  return d && m && y ? `${d}.${m}.${y}` : gun
}

/**
 * "12.08" from 'YYYY-MM-DD' — day and month only, for a chip that has to show
 * two dates at once. The year is dropped because it never fits there; the
 * dialog that set the range is where the full dates live.
 */
export function formatTarihKisa(gun: string): string {
  const [, m, d] = gun.split('-')
  return d && m ? `${d}.${m}` : gun
}

/** Days from today (Istanbul) until a 'YYYY-MM-DD' date. Negative = past. */
export function gunFarki(gun: string): number {
  const [ty, tm, td] = istanbulGun().split('-').map(Number)
  const [hy, hm, hd] = gun.split('-').map(Number)
  if (!ty || !hy) return 0
  // UTC math on bare calendar numbers: no DST, no zone, no drift.
  const a = Date.UTC(ty, (tm ?? 1) - 1, td ?? 1)
  const b = Date.UTC(hy, (hm ?? 1) - 1, hd ?? 1)
  return Math.round((b - a) / 86_400_000)
}

/** 'YYYY-MM-DD' n days from today, Istanbul. For date-input defaults. */
export function gunEkle(n: number, from: string = istanbulGun()): string {
  const [y, m, d] = from.split('-').map(Number)
  if (!y) return from
  const t = new Date(Date.UTC(y, (m ?? 1) - 1, (d ?? 1) + n))
  return t.toISOString().slice(0, 10)
}
