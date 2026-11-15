import type { Bilet, UcretsizSebep } from './types'

// Free exit (065, owner 2026-11-15): a car that only asked the price, the
// police, an ambulance, a staff car — let out at 0 ₺ with a reason and a
// REQUIRED note. Any role; the Yönetici is notified, no approval step.
//
// The labels must match 065's `ucretsiz_etiket` exactly (the server builds the
// notification and `ucret_sebep` from it). Type-only imports:
// `node tests/ucretsiz.check.mjs` runs this file directly.

export const UCRETSIZ_SEBEPLER: { value: UcretsizSebep; label: string }[] = [
  { value: 'FIYAT_SORDU', label: 'Fiyat sordu' },
  { value: 'POLIS', label: 'Polis / resmi araç' },
  { value: 'ACIL', label: 'Ambulans / itfaiye' },
  { value: 'PERSONEL', label: 'Personel / sahip aracı' },
  { value: 'DIGER', label: 'Diğer' },
]

/** The Turkish label; null for no reason (or a row from before 065). */
export function ucretsizEtiket(sebep: UcretsizSebep | null | undefined): string | null {
  if (!sebep) return null
  return UCRETSIZ_SEBEPLER.find((s) => s.value === sebep)?.label ?? null
}

/** Not longer than the server's limit (065: 1–200 characters, trimmed). */
export const UCRETSIZ_NOT_MAX = 200

/**
 * May a ticket that already left — the camera (054) or "Çıkış Ver" (027) closed
 * it owing — still be made free (066)? The same ticket the server's KAPALI
 * branch accepts: closed, a debt, nothing collected, no points, not already
 * free. `borc` comes from `biletBorcu` (lib/bilet.ts), passed in so this file
 * keeps only type imports. Who may do it (own shift / Yönetici) is the
 * server's check, as for "Ödeme topla".
 */
export function sonradanUcretsizMi(
  b: Pick<Bilet, 'durum' | 'tahsil_kurus' | 'indirim_kurus' | 'ucretsiz_sebep'>,
  borc: number,
): boolean {
  return (
    b.durum === 'KAPALI' &&
    borc > 0 &&
    b.tahsil_kurus === 0 &&
    b.indirim_kurus === 0 &&
    !b.ucretsiz_sebep
  )
}

/** The form's refusal, in the server's own words; null when it may be sent. */
export function ucretsizHatasi(sebep: UcretsizSebep | null, not: string): string | null {
  if (!sebep) return 'Sebep seçin.'
  const t = not.trim()
  if (t === '') return 'Not zorunludur.'
  if (t.length > UCRETSIZ_NOT_MAX) return 'Not en fazla 200 karakter olabilir.'
  return null
}
