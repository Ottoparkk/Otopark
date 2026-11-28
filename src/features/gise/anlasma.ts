/**
 * Anlaşmalı fiyat (080) — time maths for the deal block and the İçeride card.
 * The server prices the deal (bilet_ucreti); these helpers only draw the time
 * bar, the end time and the "Anlaşma bitti" warning.
 *
 * The deal counts from the car's entry: end = entry + hours (bilet_anlasma).
 *
 * No runtime imports (tests/anlasma.check.mjs runs this file in Node, which
 * cannot resolve the app's extensionless paths): the duration formatter is
 * passed in.
 */

export type AnlasmaBirim = 'saat' | 'gun'

/** Same limits as the server: 1 hour to 90 days, whole hours. */
export const ANLASMA_EN_FAZLA_SAAT = 2160

export function anlasmaSaat(sayi: number, birim: AnlasmaBirim): number {
  return birim === 'gun' ? sayi * 24 : sayi
}

export function anlasmaSaatGecerli(saat: number): boolean {
  return Number.isInteger(saat) && saat >= 1 && saat <= ANLASMA_EN_FAZLA_SAAT
}

export function anlasmaBitis(girisIso: string, saat: number): Date {
  return new Date(Date.parse(girisIso) + saat * 3_600_000)
}

const bitisFmt = new Intl.DateTimeFormat('tr-TR', {
  timeZone: 'Europe/Istanbul',
  day: '2-digit',
  month: '2-digit',
  hour: '2-digit',
  minute: '2-digit',
  hour12: false,
})

/** "30.11 13:03" in Istanbul time, whatever the device's zone. */
export function bitisMetni(d: Date | string): string {
  const parts = bitisFmt.formatToParts(typeof d === 'string' ? new Date(d) : d)
  const p = (t: Intl.DateTimeFormatPartTypes) => parts.find((x) => x.type === t)?.value ?? ''
  return `${p('day')}.${p('month')} ${p('hour')}:${p('minute')}`
}

export interface AnlasmaDurumu {
  doldu: boolean
  /** Share of the deal time used, 0–100 (the bar). */
  yuzde: number
  /** Minutes left, rounded up (never shows "0 dk kaldı" while time remains). */
  kalanDk: number
  /** Minutes past the end, rounded down. */
  asimDk: number
}

export function anlasmaDurumu(girisIso: string, bitisIso: string, simdiMs: number): AnlasmaDurumu {
  const bas = Date.parse(girisIso)
  const son = Date.parse(bitisIso)
  const toplam = son - bas
  const yuzde = toplam > 0 ? Math.max(0, Math.min(100, Math.round(((simdiMs - bas) / toplam) * 100))) : 100
  if (simdiMs >= son) {
    return { doldu: true, yuzde: 100, kalanDk: 0, asimDk: Math.floor((simdiMs - son) / 60_000) }
  }
  return { doldu: false, yuzde, kalanDk: Math.ceil((son - simdiMs) / 60_000), asimDk: 0 }
}

/** "1 gün 20 sa kaldı" / "2 sa 10 dk aşıldı". */
export function kalanMetni(d: AnlasmaDurumu, formatSure: (dakika: number) => string): string {
  return d.doldu ? `${formatSure(d.asimDk)} aşıldı` : `${formatSure(d.kalanDk)} kaldı`
}

/** İçeride card warning: the time is over and nobody added the extra time yet. */
export function anlasmaBittiUyarisi(
  b: { anlasma_bitis?: string | null; anlasma_fazla_at?: string | null },
  simdiMs: number,
): boolean {
  return Boolean(b.anlasma_bitis) && !b.anlasma_fazla_at && simdiMs >= Date.parse(b.anlasma_bitis as string)
}
