/**
 * Shift-end reminder on the shared terminal (085, owner 28.11): when does the
 * "Vardiyan bitti — Mehmet geldiyse Devral'a dokunun" band show, and who is
 * due next. It only reminds; the handover itself is always a person's PIN.
 *
 * Istanbul is fixed UTC+3. Pure (tests/devirHatirlatma.check.mjs).
 */

const IST_MS = 3 * 3600_000
const PENCERE_MS = 3 * 3600_000

/** 'HH:MM' or 'HH:MM:SS' → minutes after midnight, or null. */
function dakika(saat: string | null | undefined): number | null {
  const m = /^(\d{2}):(\d{2})(?::\d{2})?$/.exec(saat ?? '')
  if (!m) return null
  const s = Number(m[1])
  const d = Number(m[2])
  return s < 24 && d < 60 ? s * 60 + d : null
}

/** The latest instant at or before `simdi` whose Istanbul clock reads `bitis`. */
export function sonBitis(simdi: Date, bitis: string | null | undefined): Date | null {
  const dk = dakika(bitis)
  if (dk === null) return null
  const yerel = simdi.getTime() + IST_MS
  const gunBasi = yerel - (((yerel % 86_400_000) + 86_400_000) % 86_400_000)
  let an = gunBasi + dk * 60_000 - IST_MS
  if (an > simdi.getTime()) an -= 86_400_000
  return new Date(an)
}

/**
 * True when the current worker's end time has passed since the open shift
 * began, less than 3 hours ago.
 */
export function devirHatirlatmasi(
  acilisAt: string,
  simdi: Date,
  bitis: string | null | undefined,
): boolean {
  const son = sonBitis(simdi, bitis)
  const acilis = Date.parse(acilisAt)
  if (!son || Number.isNaN(acilis)) return false
  return acilis < son.getTime() && simdi.getTime() - son.getTime() < PENCERE_MS
}

export interface SiraAdayi {
  id: string
  ad_soyad: string
  vardiya_baslangic: string | null
}

/** The worker whose start equals the current one's end (to the minute). */
export function siradakiPersonel<T extends SiraAdayi>(
  personeller: readonly T[],
  bitis: string | null | undefined,
  calisanId: string | null,
): T | null {
  const dk = dakika(bitis)
  if (dk === null) return null
  return personeller.find((p) => p.id !== calisanId && dakika(p.vardiya_baslangic) === dk) ?? null
}
