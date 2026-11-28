/**
 * The two till-shift settings (açılış nakdi, kapanma eşiği), edited from the
 * Vardiya screen's settings icon. Since 085 there is no automatic opening
 * hour: a shift is always open, the PIN hand-over changes it, and each
 * worker's hours live on their profile. The old column stays, unused, and
 * this form never writes it.
 *
 * No runtime imports on purpose: Node cannot resolve the app's extensionless
 * paths, so the money helpers come in as `araclar` — the component passes the
 * real ones from lib/money, and so does `tests/vardiyaAyar.check.mjs`.
 *
 * The database is the boundary (025's CHECK on the threshold; only a Yönetici
 * may update `otopark_ayarlari`, 003). This decides what to SEND: exactly
 * these two keys, so this form can never overwrite another setting.
 */

export interface VardiyaAyarAraclari {
  parseTLToKurus: (input: string) => number | null
  kurusToInput: (kurus: number) => string
}

/** The form's own state: what the operator sees and types. */
export interface VardiyaAyarTaslak {
  acilisNakit: string
  esik: string
}

/** The settings row as it arrives (columns may be missing on an old database). */
export interface VardiyaAyarSatiri {
  vardiya_acilis_nakit_kurus?: number | null
  vardiya_esik_saat?: number | null
}

export interface VardiyaAyarYamasi {
  vardiya_acilis_nakit_kurus: number
  vardiya_esik_saat: number
}

/**
 * Half-hour slots for picking an hour (085: each worker's shift hours on the
 * Personel screen). Picked rather than typed — a free-text time is one typo
 * away from 18:00 instead of 08:00.
 */
export const SAAT_SECENEKLERI: string[] = Array.from({ length: 48 }, (_, i) => {
  const s = Math.floor(i / 2)
  return `${String(s).padStart(2, '0')}:${i % 2 ? '30' : '00'}`
})

/** Mirrors the CHECK in 025: below 4 h a normal shift would be closed under a working operator. */
const ESIK_MIN = 4
const ESIK_MAX = 72
const ESIK_VARSAYILAN = 16

export function vardiyaAyarBaslangic(
  satir: VardiyaAyarSatiri,
  araclar: VardiyaAyarAraclari,
): VardiyaAyarTaslak {
  return {
    // kurusToInput, NOT formatTL: grouped thousands are refused by
    // parseTLToKurus, so the field would reject the value it was filled with.
    acilisNakit: araclar.kurusToInput(satir.vardiya_acilis_nakit_kurus ?? 0),
    esik: String(satir.vardiya_esik_saat ?? ESIK_VARSAYILAN),
  }
}

/** The single validation site; null = fine to save. */
export function vardiyaAyarHatasi(
  t: VardiyaAyarTaslak,
  araclar: VardiyaAyarAraclari,
): string | null {
  // Unparseable would silently become 0, and a wrong opening float is a
  // false discrepancy on every single close. Empty means 0 ₺.
  if (t.acilisNakit.trim() !== '' && araclar.parseTLToKurus(t.acilisNakit) === null) {
    return 'Açılış nakdi için geçerli bir tutar girin.'
  }
  const esik = /^\d+$/.test(t.esik.trim()) ? Number(t.esik.trim()) : NaN
  if (!(esik >= ESIK_MIN && esik <= ESIK_MAX)) {
    return `Vardiya kapanma eşiği ${ESIK_MIN}-${ESIK_MAX} saat arasında olmalı.`
  }
  return null
}

/** Exactly the two keys this form owns. Call only after vardiyaAyarHatasi() returned null. */
export function vardiyaAyarYamasi(
  t: VardiyaAyarTaslak,
  araclar: VardiyaAyarAraclari,
): VardiyaAyarYamasi {
  return {
    vardiya_acilis_nakit_kurus:
      t.acilisNakit.trim() === '' ? 0 : (araclar.parseTLToKurus(t.acilisNakit) ?? 0),
    vardiya_esik_saat: Number(t.esik.trim()),
  }
}
