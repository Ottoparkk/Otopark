/**
 * "Değiştir" — the rules behind the ticket correction form (plate, entry time,
 * fee, reason). Pure, so `node tests/degistir.check.mjs` runs the real thing.
 *
 * No runtime imports on purpose: Node cannot resolve the extensionless paths
 * the app uses, so the plate and money helpers come in as `araclar`. The
 * component passes the real ones from lib/plaka and lib/money, and so does the
 * test — there is one implementation of each, not a copy here.
 *
 * The server is the boundary (bilet_plaka_duzelt, bilet_giris_duzelt,
 * bilet_kapat re-check everything). This decides what to SEND, which matters
 * as much: a form that sends untouched fields turns "I only fixed the plate"
 * into an audited time change and a Yönetici notification.
 */

export interface DegistirAraclari {
  normalizePlaka: (raw: string) => string
  plakaGecerli: (plaka: string) => boolean
  parseTLToKurus: (input: string) => number | null
  kurusToInput: (kurus: number) => string
}

/** What the form starts from. `ucretKurus`/`ucretMetni` null = fee not editable here. */
export interface DegistirBaslangic {
  plaka: string
  /** Entry time as the field shows it: Istanbul, minute precision. */
  girisYerel: string
  ucretKurus: number | null
  ucretMetni: string | null
  indirimKurus: number
}

export interface DegistirTaslak {
  plaka: string
  girisYerel: string
  ucretMetni: string
  sebep: string
}

export type DegistirAlan = 'plaka' | 'giris' | 'ucret' | 'sebep'

/** Either one error for one field, or exactly what changed (null = unchanged). */
export type DegistirSonuc =
  | { hata: string; alan: DegistirAlan }
  | {
      hata: null
      /** Nothing changed at all — close the form, call nothing. */
      bos: boolean
      plaka: string | null
      girisISO: string | null
      ucretKurus: number | null
      /** Trimmed; only when the time or the fee changed. */
      sebep: string | null
    }

/*
 * Istanbul is a fixed UTC+3 (no DST since 2016 — the cron schedule relies on
 * the same fact). Doing the shift by hand rather than through the device's
 * clock is the point: everything else in the app is shown in Istanbul time
 * (lib/dates.ts), so a phone set to another zone must not see — or save — a
 * different hour in this one field.
 */
const OFFSET_MS = 3 * 60 * 60 * 1000

/** ISO instant → "YYYY-MM-DDTHH:mm" in Istanbul, for a datetime-local field. */
export function istanbulYerel(iso: string | Date): string {
  const t = (iso instanceof Date ? iso : new Date(iso)).getTime()
  return new Date(t + OFFSET_MS).toISOString().slice(0, 16)
}

/**
 * "YYYY-MM-DDTHH:mm" (Istanbul) → ISO instant, or null when it is not a real
 * minute. The round trip catches what the Date constructor would silently
 * roll over (30 Şubat → 2 Mart).
 */
export function yereldenISO(yerel: string): string | null {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(yerel)) return null
  const d = new Date(`${yerel}:00+03:00`)
  if (Number.isNaN(d.getTime())) return null
  if (istanbulYerel(d) !== yerel) return null
  return d.toISOString()
}

/** One calendar year back — the same `now() - interval '1 year'` the server uses. */
export function birYilOnce(now: Date): Date {
  const d = new Date(now.getTime())
  d.setUTCFullYear(d.getUTCFullYear() - 1)
  return d
}

/**
 * The form's starting values.
 *
 * `ucretKurus` is the GROSS fee — the override if one is set, otherwise the
 * computed one — because that is what bilet_kapat's override replaces. The
 * old fee modal pre-filled the NET (after points) and saved it as gross, so
 * confirming it unchanged on a ticket with points charged the discount twice.
 */
export function degistirBaslangic(
  bilet: { plaka: string; giris_at: string; indirim_kurus: number },
  ucretKurus: number | null,
  araclar: DegistirAraclari,
): DegistirBaslangic {
  return {
    plaka: araclar.normalizePlaka(bilet.plaka),
    girisYerel: istanbulYerel(bilet.giris_at),
    ucretKurus,
    ucretMetni: ucretKurus === null ? null : araclar.kurusToInput(ucretKurus),
    indirimKurus: bilet.indirim_kurus,
  }
}

/** Validates the draft and returns only what changed. First error wins, top to bottom. */
export function degisiklikler(
  bas: DegistirBaslangic,
  taslak: DegistirTaslak,
  now: Date,
  araclar: DegistirAraclari,
): DegistirSonuc {
  // ---- plate
  const yeniPlaka = araclar.normalizePlaka(taslak.plaka)
  const plakaDegisti = yeniPlaka !== bas.plaka
  if (plakaDegisti && !araclar.plakaGecerli(yeniPlaka)) {
    return { hata: 'Geçerli bir plaka girin.', alan: 'plaka' }
  }

  // ---- entry time: compared as the field's own text, so an untouched field
  // never differs from the stored seconds and never counts as a change.
  let girisISO: string | null = null
  if (taslak.girisYerel !== bas.girisYerel) {
    girisISO = yereldenISO(taslak.girisYerel)
    if (girisISO === null) return { hata: 'Geçerli bir tarih ve saat girin.', alan: 'giris' }
    const t = new Date(girisISO).getTime()
    if (t > now.getTime()) return { hata: 'Giriş saati ileri bir zaman olamaz.', alan: 'giris' }
    if (t < birYilOnce(now).getTime()) {
      return { hata: 'Giriş saati bir yıldan eski olamaz.', alan: 'giris' }
    }
  }

  // ---- fee: compared as kuruş, so "200,00" and "200" are the same fee.
  let ucretKurus: number | null = null
  if (bas.ucretKurus !== null) {
    const kurus = araclar.parseTLToKurus(taslak.ucretMetni.trim())
    if (kurus !== bas.ucretKurus) {
      if (kurus === null) {
        return { hata: 'Geçerli bir tutar girin (örn. 250 ya da 250,50).', alan: 'ucret' }
      }
      if (kurus < bas.indirimKurus) {
        return { hata: 'Yeni ücret kullanılan puandan düşük olamaz.', alan: 'ucret' }
      }
      ucretKurus = kurus
    }
  }

  // ---- reason: a plate fix needs none (as before); time and fee move money.
  const paraDegisti = girisISO !== null || ucretKurus !== null
  const sebep = taslak.sebep.trim()
  if (paraDegisti && !sebep) {
    return {
      hata: 'Giriş saati ya da ücret değiştiyse sebep yazın — denetim kaydına geçer.',
      alan: 'sebep',
    }
  }

  return {
    hata: null,
    bos: !plakaDegisti && !paraDegisti,
    plaka: plakaDegisti ? yeniPlaka : null,
    girisISO,
    ucretKurus,
    sebep: paraDegisti ? sebep : null,
  }
}
