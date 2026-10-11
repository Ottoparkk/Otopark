/**
 * Which lane does this camera event belong to?
 *
 * No imports on purpose: this is the one rule in kamera-webhook that decides
 * whether a ticket is OPENED or an exit is FLAGGED, so it is kept pure and is
 * checked from Node (tests/serit.check.mjs) — there is no Deno on the
 * development machine.
 *
 * Two kinds of caller:
 *
 *   • Shared env secret (`cihazYon === null`): the lane comes from the request
 *     — URL path, query string or body — exactly as it did before 036. It is
 *     never defaulted.
 *
 *   • Paired camera (036): the lane was chosen by the Yönetici when the code
 *     was minted and lives on the camera's own row. THAT is the lane. A
 *     request naming a different one is refused rather than obeyed: otherwise
 *     "the lane is never guessed" would hold only inside the installer, and an
 *     exit camera with an edited config file would open tickets for departing
 *     cars while the screen still called it the exit lane.
 *
 * ORTAK (037) is a THIRD lane, not "either": one gate that cars both enter and
 * leave through. This file only says the event belongs to that lane; whether
 * it is an arrival or a departure is decided in Postgres from the ticket state
 * (kamera_tek_kapi). A camera paired as ORTAK that names GIRIS is refused like
 * any other mismatch — obeying it would open a ticket for every departing car.
 */
export type Serit = 'GIRIS' | 'CIKIS' | 'ORTAK'

export type SeritKarari =
  | { ok: true; yon: Serit }
  | { ok: false; durum: 400 | 409; hata: string; kod?: 'SERIT_UYUSMAZ' }

const YON_GEREKLI = 'yon belirtilmeli: GIRIS, CIKIS veya ORTAK.'

function gecerli(y: string): y is Serit {
  return y === 'GIRIS' || y === 'CIKIS' || y === 'ORTAK'
}

export function seritKarari(
  cihazYon: string | null,
  istekYon: string | null | undefined,
): SeritKarari {
  const istek = (istekYon ?? '').trim().toUpperCase()

  // Garbage is refused for both kinds of caller: a paired camera sending a
  // lane nobody recognises is misconfigured, and saying so beats ignoring it.
  if (istek !== '' && !gecerli(istek)) {
    return { ok: false, durum: 400, hata: YON_GEREKLI }
  }

  if (cihazYon === null) {
    if (istek === '') {
      return { ok: false, durum: 400, hata: YON_GEREKLI }
    }
    return { ok: true, yon: istek as Serit }
  }

  // The row is constrained to the three lanes by a CHECK. If it ever reads as
  // anything else, fail closed — falling back to the request would be a guess.
  if (!gecerli(cihazYon)) {
    return { ok: false, durum: 409, hata: 'Bu kameranın şeridi tanımsız.' }
  }

  if (istek !== '' && istek !== cihazYon) {
    // `kod` is for the bridge, not for people: kamera-webhook also answers 409
    // for ordinary refusals (a second ticket for a plate already inside), and
    // those are not a fault. This one drops EVERY vehicle, so the bridge logs
    // it as its own line and the status tool reports the lane as wrong.
    // tools/kamera-koprusu/kopru.py looks for this exact string.
    return {
      ok: false,
      durum: 409,
      hata: `Bu kamera ${cihazYon} şeridine eşleştirilmiş; ${istek} olayı kabul edilmez.`,
      kod: 'SERIT_UYUSMAZ',
    }
  }
  return { ok: true, yon: cihazYon }
}

/**
 * What kamera_tek_kapi (037) answered, or the fact that it answered nothing
 * we recognise.
 *
 * Here for the same reason as the rule above — pure, so Node can check it —
 * and it matters more than its size suggests: the webhook turns this into a
 * 200, and a 200 is the bridge's signal that the vehicle is DEALT WITH and
 * need not be sent again. Passing an empty or unknown answer through as
 * success would lose that car with no ticket, no exception row and no retry.
 * So anything outside the four decisions is a fault, the webhook answers 500,
 * and the bridge retries with the same islem_id (the RPC is replay-safe).
 *
 * GIRIS and CIKIS must point at a ticket: one was opened, the other stamped.
 */
export type TekKapiKarar = 'GIRIS' | 'CIKIS' | 'YOKSAY' | 'ISTISNA'

export type TekKapiCevabi =
  | { ok: true; karar: TekKapiKarar; sebep: string | null; biletId: string | null }
  | { ok: false }

const TEK_KAPI_KARARLARI: readonly string[] = ['GIRIS', 'CIKIS', 'YOKSAY', 'ISTISNA']

export function tekKapiCevabi(veri: unknown): TekKapiCevabi {
  if (veri === null || typeof veri !== 'object' || Array.isArray(veri)) {
    return { ok: false }
  }
  const v = veri as Record<string, unknown>
  if (typeof v.karar !== 'string' || !TEK_KAPI_KARARLARI.includes(v.karar)) {
    return { ok: false }
  }
  const karar = v.karar as TekKapiKarar

  const ham = v.bilet_id ?? null
  if (ham !== null && typeof ham !== 'string') return { ok: false }
  if ((karar === 'GIRIS' || karar === 'CIKIS') && !ham) return { ok: false }

  return {
    ok: true,
    karar,
    sebep: typeof v.sebep === 'string' ? v.sebep : null,
    biletId: ham || null,
  }
}
