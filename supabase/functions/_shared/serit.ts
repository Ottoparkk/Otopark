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

/**
 * Should an unreadable plate become an exception row (039 kamera_okunamadi)?
 *
 * Before 039 a car whose plate could not be read got a 422 and nothing else:
 * through an entrance camera it drove in with no ticket and nobody was told.
 *
 *   • GIRIS and ORTAK only. At a two-lane exit a person collects the money and
 *     sees the car; on the single gate the car may be arriving.
 *   • Only when a photo was actually read — a plate-string camera that sent no
 *     plate is a different fault.
 *   • NEVER when the model said there is no vehicle: the bridge photographs the
 *     empty lane after every departure, and each of those becoming "a car we
 *     could not read" would bury the real ones.
 */
export function okunamadiKaydedilir(yon: Serit, gorselOkundu: boolean, aracYok: boolean): boolean {
  return (yon === 'GIRIS' || yon === 'ORTAK') && gorselOkundu && !aracYok
}

/**
 * Is this the bridge's LAST attempt for the event (`x-kamera-son-gonderim`,
 * bridge 1.2.1+)? Exactly "1", like `x-kamera-deneme`.
 *
 * When the reading service fails the bridge retries the same islem_id. The
 * per-car exception is written only on the last try: written earlier, it would
 * make kamera_tek_kapi (037) answer "ISTISNA TEKRAR" to a later retry that
 * DID read the plate, and that car would never get its ticket.
 */
export function sonGonderimMi(baslik: string | null | undefined): boolean {
  return baslik === '1'
}

/**
 * The raw body as it is stored with an exception — without the photos.
 *
 * The bridge's JSON carries the JPEG as `foto_base64`, and since bridge 1.2.3
 * a compressed copy as `foto_kanit_base64` (042); stored in `ham_yanit` they
 * made every camera exception row tens to hundreds of KB, all downloaded by
 * the exceptions screen. A copy: the caller still needs the original.
 */
export function hamFotosuz(govde: Record<string, unknown>): Record<string, unknown> {
  const { foto_base64: _foto, foto_kanit_base64: _kanit, ...kalan } = govde
  return kalan
}

/* ------------------------------------------------ temporary database errors
 *
 * The bridge (tools/kamera-koprusu/kopru.py, `gonder`) retries 5xx and 429 and
 * treats every other 4xx as FINAL: the car is dropped and has to be entered by
 * hand. So a 4xx must mean "the answer will not change". A database timeout, a
 * lock, a dropped connection or a network blip is not that — answered as a
 * 4xx, the car was lost on a wobble. These three helpers decide which answers
 * are final and which are retried.
 *
 * Retrying is safe because the bridge sends the SAME islem_id on every try:
 * bilet_ac and kamera_tek_kapi return their first answer for a repeated
 * islem_id, kamera_cikis_bildir writes the same stamp again, and istisna_yaz
 * dedupes on islem_id. The cost: a retried car is read (paid) again, at most
 * four tries.
 */

/** Body of every 503 below. Says nothing about the cause on purpose. */
export const GECICI_HATA = 'Sunucu geçici olarak yanıt veremedi. Biraz sonra tekrar deneyin.'

/**
 * The status for an error from bilet_ac, kamera_cikis_bildir or
 * kamera_tek_kapi, from its SQLSTATE (`error.code`).
 *
 *   409  P0001 — every refusal in those three RPCs is a plain `raise
 *        exception` (bilet_ac 030, kamera_cikis_bildir 002, kamera_tek_kapi
 *        037; 038/039 change none of them). Class 22 (bad data) and 23
 *        (integrity — e.g. 23505, a second open ticket for a plate already
 *        inside). Asking again gets the same refusal.
 *   503  Everything else: timeouts (57014), locks (55P03), serialisation and
 *        deadlock (40xxx), connection (08xxx), PostgREST (PGRST…), and an
 *        empty or missing code — which is how supabase-js reports a network
 *        failure or a non-JSON error body.
 *
 * Only an exact five-character SQLSTATE counts. An unknown shape fails toward
 * a retry: a needless retry costs at most three extra reads, a wrong 409
 * loses the car.
 */
export function rpcHataDurumu(kod: string | null | undefined): 409 | 503 {
  return /^(P0001|2[23][0-9A-Z]{3})$/.test(kod ?? '') ? 409 : 503
}

export type KameraGirisiKarari<T> =
  | { ok: true; ayar: T }
  | { ok: false; durum: 403 | 503; hata: string }

/**
 * May the camera event go on, given the settings read (`otopark_ayarlari`)?
 *
 * The read's error used to be ignored: a failed read left the row null and
 * the webhook answered 403 "Kamera girişi kapalı." — so the bridge dropped
 * the car AND logged that camera input was switched off, and `durum` showed
 * KAMERA GİRİŞİ KAPALI until the next accepted request. Now 403 means only
 * what it says: a SUCCESSFUL read with `kamera_aktif` off. A failed read is
 * 503 whatever the data says.
 *
 * Returns the row on success so the caller keeps a non-null type.
 */
export function kameraGirisiKarari<T extends { kamera_aktif?: unknown }>(
  ayar: T | null | undefined,
  hata: unknown,
): KameraGirisiKarari<T> {
  if (hata) return { ok: false, durum: 503, hata: GECICI_HATA }
  if (!ayar?.kamera_aktif) return { ok: false, durum: 403, hata: 'Kamera girişi kapalı.' }
  return { ok: true, ayar }
}

export type CihazKimligi =
  | { ok: true; cihazId: string; cihazYon: string }
  | { ok: false; durum: 401 | 503 }

/**
 * A paired camera's credential lookup (036, `kamera_cihazlari` by hash), from
 * the query's rows and error.
 *
 * This is the FIRST database query of every request a paired camera sends. A
 * failed lookup used to be answered 401 like a wrong key: the bridge dropped
 * the car and logged that the camera may have been removed in the app.
 *
 * 503 still fails CLOSED — nothing is granted. It is answered only when a
 * correctly shaped candidate reached the database AND the query failed; a
 * wrong or junk key still gets 401, so a prober learns nothing beyond "the
 * database is failing right now".
 *
 * The row extraction is the webhook's own, unchanged: the first row with an
 * id, its lane as text ('' when missing — seritKarari then refuses closed).
 */
export function cihazKimligi(satirlar: unknown, hata: unknown): CihazKimligi {
  if (hata) return { ok: false, durum: 503 }
  const satir: unknown = Array.isArray(satirlar) ? satirlar[0] : undefined
  if (satir !== null && typeof satir === 'object') {
    const s = satir as Record<string, unknown>
    if (s.id) return { ok: true, cihazId: s.id as string, cihazYon: String(s.yon ?? '') }
  }
  return { ok: false, durum: 401 }
}

/* ------------------------------------------------------ paid plate-read cap
 *
 * Every photo kamera-webhook reads is a paid model call (a borderline read a
 * second one). The flood guard in front of it counts TICKETS, and most reads
 * open none: an empty lane, an unreadable plate, a failed read, every exit,
 * every retry. So reads were unlimited, and a misbehaving bridge or a leaked
 * camera key could run up the bill.
 *
 * Now every camera read is a `plaka_okuma_log` row tagged `kaynak = 'KAMERA'`
 * (040), and before each read the webhook counts those rows in the last
 * minute and the last 24 hours — all lanes together. Above the cap it answers
 * 429 (the bridge retries a 429, then drops the car) and the Yönetici gets an
 * hourly alert (040 kamera_okuma_siniri). Phone reads (plaka-oku) are not
 * tagged and never count.
 */

/** The owner's numbers (2026-10-24). Pinned in tests/serit.check.mjs. */
export const OKUMA_DAKIKA_SINIRI = 20
export const OKUMA_GUN_SINIRI = 1500

/**
 * The `kaynak` enum value (001) a camera read is tagged with — and filtered
 * on when counting. One constant for both, so the tag and the count cannot
 * drift apart.
 */
export const KAMERA_OKUMA_KAYNAGI = 'KAMERA'

/** Body of the 429. */
export const OKUMA_SINIRI_HATA = 'Kamera okuma sınırı aşıldı.'

/** One head-count query's answer: `{ count, error }` as supabase-js gives it. */
export interface OkumaSayimi {
  count?: number | null
  error?: unknown
}

export type OkumaSiniriKarari =
  | { ok: true; sayilamadi: boolean }
  | { ok: false; durum: 429; hata: string }

/**
 * May the webhook pay for this read, given the camera reads already counted
 * in the last minute and the last 24 hours?
 *
 * A count AT the cap refuses: "1500 a day" allows 1500 reads, not 1501.
 *
 * A count that failed — or came back without a number — is unknown, not zero.
 * If the other count is already at its cap that is enough to refuse. Otherwise
 * the read goes ahead and `sayilamadi` tells the caller to log it (owner's
 * choice, 2026-10-27). The alternative, 503, would drop EVERY camera car for
 * as long as counting fails — e.g. a webhook deployed before 040 — with no
 * alert. The ticket guard has always behaved this way.
 */
export function okumaSiniriKarari(dakika: OkumaSayimi, gun: OkumaSayimi): OkumaSiniriKarari {
  const sayi = (s: OkumaSayimi): number | null =>
    !s.error && typeof s.count === 'number' ? s.count : null

  const dk = sayi(dakika)
  const gn = sayi(gun)
  if ((dk !== null && dk >= OKUMA_DAKIKA_SINIRI) || (gn !== null && gn >= OKUMA_GUN_SINIRI)) {
    return { ok: false, durum: 429, hata: OKUMA_SINIRI_HATA }
  }
  return { ok: true, sayilamadi: dk === null || gn === null }
}

/**
 * A `plaka_okuma_log` row as the webhook writes it: tagged as a camera read.
 * The tag is written LAST so a field in the input cannot override it; the
 * input is not changed. Every log insert in kamera-webhook goes through this
 * — an untagged row would be a read the cap never sees (tests/serit.check.mjs
 * checks the webhook's source for it).
 */
export function kameraOkumaLogu<T extends object>(
  satir: T,
): Omit<T, 'kaynak'> & { kaynak: typeof KAMERA_OKUMA_KAYNAGI } {
  return { ...satir, kaynak: KAMERA_OKUMA_KAYNAGI }
}

/* ------------------------------------------------------------ camera photo
 *
 * Until 042 no camera photo was stored: every RPC got `p_foto: null`, so a
 * camera ticket, a "Kapıda" stamp and every camera exception had nothing for
 * staff to look at. Bridge 1.2.3 now also sends a COMPRESSED copy of the plate
 * crop it read (`foto_kanit_base64`) — the phone's model: the device
 * compresses, the server only stores. The reading copy (`foto_base64`) is
 * untouched; heavy compression would hurt the read.
 *
 * The webhook decides FIRST and stores after: a photo is uploaded only when
 * the decision wrote something to attach it to, so an ignored or refused
 * event leaves no file behind. It is uploaded as `kamera/<islem_id>.jpg`
 * without overwriting and attached with `kamera_foto_bagla`, which accepts
 * only that exact path for that event. Best effort throughout: a photo that
 * fails is logged and never changes what the bridge is told.
 */

/**
 * Most bytes a stored camera photo may have: 100 KB. The SAME number as the
 * bridge's `KANIT_EN_COK_BAYT` (tools/kamera-koprusu/kopru.py), which
 * compresses to fit it — owner's choice after measuring (2026-10-28: plate
 * crops 13–56 KB, a whole frame 69–82 KB, pure noise squeezed to fit). It
 * bounds abuse too: at most 1500 photos a day (the paid-read cap) × 100 KB.
 */
export const KANIT_FOTO_EN_COK_BAYT = 102_400

/** The private bucket the phone photos already use (003); same nightly purge. */
export const KANIT_FOTO_KOVA = 'plaka-foto'

const UUID_DESENI = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

/**
 * Where an event's photo is stored: `kamera/<islem_id>.jpg`, lower case —
 * exactly what `kamera_foto_bagla` compares with (`p_islem_id::text` is lower
 * case). Anything that is not a UUID gets no path, so nothing from a request
 * can steer the upload into another folder.
 */
export function kameraFotoYolu(islemId: string | null | undefined): string | null {
  if (typeof islemId !== 'string') return null
  const id = islemId.trim().toLowerCase()
  return UUID_DESENI.test(id) ? `kamera/${id}.jpg` : null
}

/**
 * The bridge's compressed copy as bytes — or null, and then simply no photo.
 * Accepted only if it is clean base64 (an optional `data:` prefix is
 * stripped), decodes to at most `KANIT_FOTO_EN_COK_BAYT` and starts like a
 * JPEG (FF D8 FF). Too big is checked before decoding, from the length. Never
 * throws: a bad photo must not cost the car its ticket.
 */
export function kanitFotoCoz(b64: unknown): Uint8Array | null {
  if (typeof b64 !== 'string' || b64 === '') return null
  const temiz = b64.replace(/^data:[^,]*,/, '')
  if (temiz.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(temiz)) return null
  const dolgu = temiz.endsWith('==') ? 2 : temiz.endsWith('=') ? 1 : 0
  if ((temiz.length / 4) * 3 - dolgu > KANIT_FOTO_EN_COK_BAYT) return null

  let ikili: string
  try {
    ikili = atob(temiz)
  } catch {
    return null
  }
  if (ikili.length < 3 || ikili.length > KANIT_FOTO_EN_COK_BAYT) return null
  const bayt = new Uint8Array(ikili.length)
  for (let i = 0; i < ikili.length; i++) bayt[i] = ikili.charCodeAt(i)
  if (bayt[0] !== 0xff || bayt[1] !== 0xd8 || bayt[2] !== 0xff) return null
  return bayt
}

/**
 * Did `kamera_okuma_hatasi` write a per-car row for this failed read? Only on
 * the bridge's last try and only on the entrance / single-gate lanes — the
 * same rule as the function itself (039). No row, nothing to attach a photo to.
 */
export function okumaHatasiKaydedilir(yon: Serit, sonGonderim: boolean): boolean {
  return (yon === 'GIRIS' || yon === 'ORTAK') && sonGonderim
}

/**
 * Does a single-gate decision leave something to attach a photo to? Every one
 * except "ignored": GIRIS opens a ticket, CIKIS stamps one, ISTISNA writes (or
 * already has) an exception row. YOKSAY writes nothing, so its photo is never
 * uploaded.
 */
export function tekKapiFotoGerekli(karar: string): boolean {
  return karar !== 'YOKSAY'
}

/**
 * Is the photo in storage after this upload? Yes on success, and yes when the
 * object already exists: the same event retried (same islem_id, same path),
 * and with `upsert: false` the first file stays. The installed storage-js
 * reports that as a StorageApiError whose `statusCode` is '409' (the older API
 * answers HTTP 400 with that in the body, the newer one 409) and, on newer
 * servers, `code: 'Duplicate'`. Everything else is a failure.
 */
export function fotoYuklemeTamam(hata: unknown): boolean {
  if (hata === null || hata === undefined) return true
  if (typeof hata !== 'object') return false
  const h = hata as { status?: unknown; statusCode?: unknown; code?: unknown }
  return h.status === 409 || String(h.statusCode ?? '') === '409' || h.code === 'Duplicate'
}

/** What `sureSinirli` answers when the time ran out first. */
export const SURE_DOLDU: unique symbol = Symbol('SURE_DOLDU')

/**
 * The promise's own result, or `SURE_DOLDU` after `ms`. A rejection passes
 * through. The timer is cleared either way, so nothing lingers after the
 * request. Used for the photo upload: slow storage must not delay the
 * bridge's answer (it waits 30 s, then retries).
 */
export async function sureSinirli<T>(is: Promise<T>, ms: number): Promise<T | typeof SURE_DOLDU> {
  let zamanlayici: ReturnType<typeof setTimeout> | undefined
  const sure = new Promise<typeof SURE_DOLDU>((coz) => {
    zamanlayici = setTimeout(() => coz(SURE_DOLDU), ms)
  })
  try {
    return await Promise.race([is, sure])
  } finally {
    clearTimeout(zamanlayici)
  }
}
