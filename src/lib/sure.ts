/**
 * Stay duration, formatted the way an operator reads it out loud.
 *
 * Rounds the same way the server prices it (`ucret_hesapla_core` takes
 * ceil-to-the-minute), so the duration on screen can never look like it
 * disagrees with the amount next to it.
 */

export function dakikaFarki(giris: string, cikis: string | Date = new Date()): number {
  const a = new Date(giris).getTime()
  const b = typeof cikis === 'string' ? new Date(cikis).getTime() : cikis.getTime()
  return Math.max(0, Math.ceil((b - a) / 60_000))
}

/** 45 -> "45 dk" · 135 -> "2 sa 15 dk" · 1500 -> "1 gün 1 sa" */
export function formatSure(dakika: number): string {
  if (dakika < 60) return `${dakika} dk`

  const gun = Math.floor(dakika / 1440)
  const saat = Math.floor((dakika % 1440) / 60)
  const dk = dakika % 60

  if (gun > 0) {
    // Minutes are noise once a stay is measured in days.
    return saat > 0 ? `${gun} gün ${saat} sa` : `${gun} gün`
  }
  return dk > 0 ? `${saat} sa ${dk} dk` : `${saat} sa`
}

/** Convenience: "2 sa 15 dk" straight from an entry timestamp. */
export function sureMetni(giris: string, cikis?: string | null): string {
  return formatSure(dakikaFarki(giris, cikis ?? new Date()))
}
