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
 */
export type SeritKarari =
  | { ok: true; yon: 'GIRIS' | 'CIKIS' }
  | { ok: false; durum: 400 | 409; hata: string; kod?: 'SERIT_UYUSMAZ' }

function gecerli(y: string): y is 'GIRIS' | 'CIKIS' {
  return y === 'GIRIS' || y === 'CIKIS'
}

export function seritKarari(
  cihazYon: string | null,
  istekYon: string | null | undefined,
): SeritKarari {
  const istek = (istekYon ?? '').trim().toUpperCase()

  // Garbage is refused for both kinds of caller: a paired camera sending a
  // lane nobody recognises is misconfigured, and saying so beats ignoring it.
  if (istek !== '' && !gecerli(istek)) {
    return { ok: false, durum: 400, hata: 'yon belirtilmeli: GIRIS veya CIKIS.' }
  }

  if (cihazYon === null) {
    if (istek === '') {
      return { ok: false, durum: 400, hata: 'yon belirtilmeli: GIRIS veya CIKIS.' }
    }
    return { ok: true, yon: istek as 'GIRIS' | 'CIKIS' }
  }

  // The row is constrained to GIRIS/CIKIS by a CHECK. If it ever reads as
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
