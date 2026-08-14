/**
 * Money is integer KURUŞ, everywhere, always. Floats appear only at the last
 * moment, inside a formatter, and are never fed back into a calculation.
 *
 * The server computes every fee (`ucret_hesapla`). Nothing here decides what
 * anyone owes — these are display and input helpers only.
 */

const wholeTL = new Intl.NumberFormat('tr-TR', { maximumFractionDigits: 0 })
const centTL = new Intl.NumberFormat('tr-TR', {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
})

/**
 * 25000 -> "250 ₺" · 25050 -> "250,50 ₺" · -25000 -> "-250 ₺"
 * Whole liras drop the decimals: ",00" on every price is noise at a gate.
 */
export function formatTL(kurus: number, opts: { decimals?: 0 | 2 } = {}): string {
  const sign = kurus < 0 ? '-' : ''
  const abs = Math.abs(kurus)
  const decimals = opts.decimals ?? (abs % 100 === 0 ? 0 : 2)
  const formatter = decimals === 0 ? wholeTL : centTL
  return `${sign}${formatter.format(abs / 100)} ₺`
}

/** Same, without the symbol — for a hero number that renders ₺ separately. */
export function formatTutar(kurus: number): string {
  const abs = Math.abs(kurus)
  const formatter = abs % 100 === 0 ? wholeTL : centTL
  return `${kurus < 0 ? '-' : ''}${formatter.format(abs / 100)}`
}

/**
 * Parses operator input ("250", "250,50", "250.50") to integer kuruş.
 * Thousands separators are REJECTED rather than guessed: "1.250" is
 * genuinely ambiguous between 1250 ₺ and 1,25 ₺, and silently picking one
 * is how a charge ends up a thousandfold wrong.
 */
export function parseTLToKurus(input: string): number | null {
  const cleaned = input.replace(/[₺\s]/g, '')
  if (!cleaned) return null
  const match = /^(\d{1,9})(?:[.,](\d{1,2}))?$/.exec(cleaned)
  if (!match) return null
  const whole = Number(match[1])
  const frac = match[2] ? Number(match[2].padEnd(2, '0')) : 0
  return whole * 100 + frac
}

/** Integer kuruş -> editable input string ("250" / "250,50"). */
export function kurusToInput(kurus: number): string {
  if (kurus % 100 === 0) return String(Math.trunc(kurus / 100))
  const abs = Math.abs(kurus)
  const whole = Math.floor(abs / 100)
  const frac = abs % 100
  return `${kurus < 0 ? '-' : ''}${whole},${String(frac).padStart(2, '0')}`
}

/** Keeps only digits — for numeric fields where type="number" misbehaves. */
export function digitsOnly(value: string, max = 9): string {
  return value.replace(/\D/g, '').slice(0, max)
}
