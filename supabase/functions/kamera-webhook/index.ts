/**
 * kamera-webhook — the single entry point for camera hardware.
 *
 * ⚠ UNTESTED AGAINST REAL HARDWARE. No camera has been bought yet; this is
 * built now so the system is camera-ready at launch, and that is an accepted
 * trade. The contract tests cover the contract, not any vendor's quirks.
 *
 * It normalises every vendor shape to {plaka?, yon, zaman, islem_id, foto?}
 * and calls the SAME RPCs the phone uses, so the money logic has exactly one
 * implementation:
 *   • plate string in  (ANPR camera, Frigate, Plate Recognizer) → straight through
 *   • JPEG in          (thin bridge)                            → OCR, then through
 *
 * WHAT IT CANNOT DO — by construction, not by promise:
 *   Its whole RPC surface is bilet_ac, kamera_cikis_bildir, kamera_tek_kapi,
 *   kamera_okuma_bagla, kamera_kalp, kamera_kalp_cihaz, kamera_okunamadi,
 *   kamera_okuma_hatasi, kamera_okuma_siniri and kamera_foto_bagla. There is
 *   no path to tariffs, users, the kasa or subscriptions. And it can never
 *   close a ticket or take money: a camera reports, a human collects.
 *
 *   Its only Storage write (042) is the event's compressed photo, as
 *   `plaka-foto/kamera/<islem_id>.jpg`, never overwriting an existing object;
 *   kamera_foto_bagla attaches only that exact path, only where empty.
 *
 *   kamera_tek_kapi (037, the single-gate lane) adds no new power: it only
 *   CHOOSES between the first two, or declines to choose. The two 039 RPCs
 *   only write an exception row and an alert, so that a car whose plate could
 *   not be read — or that arrived while plate reading was down — is not lost
 *   without a trace.
 *
 * Security posture (OWASP 2025):
 *   A01  A credential is required and compared in constant time. Two kinds:
 *        the shared env secret, and (036) a per-camera secret of which only
 *        the SHA-256 is stored. Accepted three ways because some cameras
 *        (TP-Link VIGI) offer no auth field at all.
 *   A02  A per-camera secret is never stored in clear, so reading the database
 *        yields no working credential, and one camera can be revoked alone.
 *   A03  Body is zod-validated and size-capped before anything touches the DB.
 *   A04  Rate limit AND a daily cap: a leaked URL is a billing attack before
 *        it is anything else. Two of them: camera TICKETS, and (040) the PAID
 *        plate reads themselves — most reads open no ticket.
 *   A09  Every refusal is logged; every accepted event bumps the heartbeat.
 */
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2.112.3'
import { z } from 'npm:zod@4.6.7'
import { deriveIslemId, json, parseCameraTime, safeEqual } from '../_shared/http.ts'
import { aracYokMu, bytesToBase64, okumaGuvenilir, plakaOku, tidyPlaka } from '../_shared/ocr.ts'
import {
  GECICI_HATA,
  KAMERA_OKUMA_KAYNAGI,
  KANIT_FOTO_KOVA,
  SURE_DOLDU,
  cihazKimligi,
  fotoYuklemeTamam,
  hamFotosuz,
  kameraFotoYolu,
  kameraGirisiKarari,
  kameraOkumaLogu,
  kanitFotoCoz,
  okumaHatasiKaydedilir,
  okumaSiniriKarari,
  okunamadiKaydedilir,
  rpcHataDurumu,
  seritKarari,
  sonGonderimMi,
  sureSinirli,
  tekKapiCevabi,
  tekKapiFotoGerekli,
} from '../_shared/serit.ts'

const MAX_BODY_BYTES = 8 * 1024 * 1024
// Camera TICKETS. The paid reads have their own, lower cap (040):
// OKUMA_DAKIKA_SINIRI / OKUMA_GUN_SINIRI in _shared/serit.ts.
const DAKIKA_LIMIT = 30 // camera-opened tickets per minute
const GUN_LIMIT = 2000 // ...and per day

/* ------------------------------------------------------------------- auth */

/**
 * Three ways in, because the hardware decides what it can do:
 *   1. `x-kamera-secret` header      — preferred
 *   2. HTTP Basic                    — Milesight, Axis
 *   3. a URL path segment            — TP-Link VIGI, which has NO auth field
 *
 * The path form is the weakest (URLs land in proxy and server logs), which is
 * why SETUP.md tells the operator to rotate it on a shorter cycle.
 *
 * KAMERA_WEBHOOK_SECRET_ESKI lets a rotation overlap: set the new secret,
 * move the old one to _ESKI, reconfigure the camera, then drop _ESKI. Without
 * it, rotating means a window where the camera is silently rejected.
 */
async function sha256Hex(s: string): Promise<string> {
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)))
  return Array.from(d, (x) => x.toString(16).padStart(2, '0')).join('')
}

/**
 * Two kinds of credential, and the order matters.
 *
 * The ENV path is evaluated first and is byte-for-byte what it always was, so
 * a bridge set up by hand keeps working and pays no database round trip.
 *
 * The DEVICE path is new (036): each paired camera has its own secret, only
 * its SHA-256 is stored, and `cihazId` tells the caller which camera reported
 * — which is what makes a per-camera heartbeat possible. Before this, one live
 * bridge kept the single global heartbeat fresh and a dead exit camera raised
 * no alarm at all.
 *
 * Returns the device id and ITS lane, or nulls for a valid env-secret caller.
 * The lane is read here, in the same query that proves the credential, so it
 * cannot be a different row's lane.
 *
 * `gecici` marks a refusal caused by a FAILED LOOKUP rather than by the key;
 * the caller answers it 503 so the bridge retries.
 */
async function kimlik(
  req: Request,
  pathSecret: string | null,
  admin: SupabaseClient,
): Promise<{ ok: boolean; gecici?: boolean; cihazId: string | null; cihazYon: string | null }> {
  const RED = { ok: false, cihazId: null, cihazYon: null }
  const candidates: string[] = []

  const header = req.headers.get('x-kamera-secret')
  if (header) candidates.push(header)

  const auth = req.headers.get('authorization') ?? ''
  if (auth.toLowerCase().startsWith('basic ')) {
    try {
      const decoded = atob(auth.slice(6))
      const idx = decoded.indexOf(':')
      candidates.push(idx >= 0 ? decoded.slice(idx + 1) : decoded)
    } catch {
      /* malformed Basic header — just not a candidate */
    }
  }

  if (pathSecret) candidates.push(pathSecret)
  if (candidates.length === 0) return RED

  // 1. Shared env secret — UNCHANGED. The `< 16` refusal is scoped to this
  //    branch now, so an install that only ever uses per-camera credentials
  //    and has no env secret still works.
  const current = Deno.env.get('KAMERA_WEBHOOK_SECRET') ?? ''
  const previous = Deno.env.get('KAMERA_WEBHOOK_SECRET_ESKI') ?? ''
  if (current.length >= 16) {
    // Evaluate every candidate against both secrets without early exit.
    let ok = false
    for (const c of candidates) {
      if (safeEqual(c, current)) ok = true
      if (previous.length >= 16 && safeEqual(c, previous)) ok = true
    }
    if (ok) return { ok: true, cihazId: null, cihazYon: null }
  }

  // 2. Per-camera credential. Only exactly-shaped candidates reach the
  //    database — a minted secret is 64 hex characters — so a probe with a
  //    junk header never costs a query.
  //
  //    ⚠ THE SHAPE AND THE CASE FOLD BELONG TO 036's kamera_eslestir. It
  //    builds the secret from two uuid::text values, which Postgres renders
  //    LOWERCASE hex, and hashes that exact string. Lowercasing here is a
  //    no-op for a real secret and only forgives a hand-retyped one; if the
  //    secret format ever stops being hex, this filter AND this fold have to
  //    change with it, or every camera silently starts getting 401.
  const adaylar = candidates.filter((c) => /^[0-9a-f]{64}$/i.test(c))
  if (adaylar.length === 0) return RED

  // Fail CLOSED: a database wobble must never be mistaken for a valid
  // credential. But a failed lookup is no longer answered like a wrong key.
  // As a 401 it was final for the bridge — the car was dropped and its log
  // said the camera may have been removed in the app. It is 503 now
  // (`gecici`), so the same event is retried; a key that is simply wrong is
  // still 401. See cihazKimligi in _shared/serit.ts.
  try {
    const hashes = await Promise.all(adaylar.map((c) => sha256Hex(c.toLowerCase())))
    const { data, error } = await admin
      .from('kamera_cihazlari')
      .select('id, yon')
      .in('gizli_hash', hashes)
      .eq('aktif', true)
      .limit(1)
    const sonuc = cihazKimligi(data, error)
    if (sonuc.ok) {
      return { ok: true, cihazId: sonuc.cihazId, cihazYon: sonuc.cihazYon }
    }
    if (sonuc.durum === 503) {
      console.warn(
        `kamera-webhook: cihaz kimliği okunamadı (${error?.code || 'kod yok'}) —`,
        error?.message,
      )
      return { ...RED, gecici: true }
    }
  } catch (e) {
    console.warn('kamera-webhook: cihaz kimliği okunamadı —', e)
    return { ...RED, gecici: true }
  }
  return RED
}

/* --------------------------------------------------------- payload shapes */


const OlaySchema = z.object({
  plaka: z.string().max(32).nullable().optional(),
  yon: z.string().max(10).nullable().optional(),
  zaman: z.union([z.string(), z.number()]).nullable().optional(),
  islem_id: z.string().uuid().nullable().optional(),
  cihaz: z.string().max(120).nullable().optional(),
  foto_base64: z.string().max(12_000_000).nullable().optional(),
  // Bridge 1.2.3: the compressed copy that is STORED (042). Deliberately as
  // loose as foto_base64: an oversized copy must cost only the photo
  // (kanitFotoCoz says no), never the car — a schema refusal here is a 400.
  foto_kanit_base64: z.string().max(12_000_000).nullable().optional(),
})

interface Olay {
  plaka: string | null
  yon: string | null
  zaman: string | null
  islemId: string | null
  cihaz: string | null
  image: { data: string; mediaType: string } | null
  // The photo to store (042): only the bridge's compressed JPEG, already
  // checked. Vendor image bodies carry no compressed copy → no stored photo.
  kanit: Uint8Array | null
  ham: Record<string, unknown>
}

/** Pulls the fields we need out of whatever the vendor decided to send. */
function fromJson(body: Record<string, unknown>): Omit<Olay, 'image' | 'kanit'> {
  const ev = (body.event_list ?? {}) as Record<string, unknown>
  const lpr = (body.license_plate_result ?? body.result ?? {}) as Record<string, unknown>

  const plaka =
    (body.plaka as string) ??
    (body.plate as string) ??
    (body.license_plate_number as string) ??
    (lpr.license_plate_number as string) ??
    (ev.plate as string) ??
    null

  const zamanRaw =
    body.zaman ??
    body.timestamp ??
    body.snapshot_timestamp ??
    ev.dateTime ??
    lpr.snapshot_timestamp ??
    null

  return {
    plaka: plaka ? String(plaka) : null,
    yon: body.yon ? String(body.yon) : null,
    zaman: parseCameraTime(zamanRaw),
    islemId: typeof body.islem_id === 'string' ? body.islem_id : null,
    cihaz:
      (body.cihaz as string) ??
      (body.device_name as string) ??
      (body.mac as string) ??
      (body.ip as string) ??
      null,
    // Without the photo: this is what gets stored with an exception (039).
    ham: hamFotosuz(body),
  }
}

/**
 * Manual multipart fallback. Deno's formData() requires every part to carry a
 * `name`, and TP-Link VIGI's ReportEventBoundary payload does not reliably do
 * so — a spec-compliant parser rejecting a real camera is exactly the kind of
 * failure that would only show up on installation day.
 */
function splitMultipart(
  raw: Uint8Array,
  boundary: string,
): { headers: string; body: Uint8Array }[] {
  const enc = new TextEncoder()
  const delim = enc.encode(`--${boundary}`)
  const parts: { headers: string; body: Uint8Array }[] = []

  const indices: number[] = []
  outer: for (let i = 0; i <= raw.length - delim.length; i++) {
    for (let j = 0; j < delim.length; j++) {
      if (raw[i + j] !== delim[j]) continue outer
    }
    indices.push(i)
  }

  for (let k = 0; k < indices.length - 1; k++) {
    const start = indices[k]! + delim.length
    const end = indices[k + 1]!
    const chunk = raw.subarray(start, end)

    // Locate the blank line separating part headers from part body.
    let sep = -1
    for (let i = 0; i < chunk.length - 3; i++) {
      if (chunk[i] === 13 && chunk[i + 1] === 10 && chunk[i + 2] === 13 && chunk[i + 3] === 10) {
        sep = i
        break
      }
    }
    if (sep < 0) continue

    const headers = new TextDecoder().decode(chunk.subarray(0, sep))
    let bodyEnd = end - indices[k]! - delim.length
    // Trim the CRLF that precedes the next boundary.
    if (chunk[bodyEnd - 2] === 13 && chunk[bodyEnd - 1] === 10) bodyEnd -= 2
    parts.push({ headers, body: chunk.subarray(sep + 4, bodyEnd) })
  }
  return parts
}

async function readEvent(req: Request, raw: Uint8Array): Promise<Olay> {
  const ctype = (req.headers.get('content-type') ?? '').toLowerCase()

  if (ctype.includes('multipart/form-data')) {
    const boundary = /boundary=("?)([^";]+)\1/i.exec(ctype)?.[2] ?? ''
    let meta: Omit<Olay, 'image' | 'kanit'> = {
      plaka: null,
      yon: null,
      zaman: null,
      islemId: null,
      cihaz: null,
      ham: {},
    }
    let image: Olay['image'] = null

    if (boundary) {
      for (const part of splitMultipart(raw, boundary)) {
        const partType = /content-type:\s*([^\r\n;]+)/i.exec(part.headers)?.[1]?.trim() ?? ''
        if (partType.startsWith('image/')) {
          image = { data: bytesToBase64(part.body), mediaType: partType }
        } else {
          try {
            const parsed = JSON.parse(new TextDecoder().decode(part.body))
            if (parsed && typeof parsed === 'object') meta = fromJson(parsed)
          } catch {
            /* a non-JSON text part is not interesting to us */
          }
        }
      }
    }
    return { ...meta, image, kanit: null }
  }

  if (ctype.startsWith('image/')) {
    return {
      plaka: null,
      yon: null,
      zaman: null,
      islemId: null,
      cihaz: null,
      ham: {},
      image: { data: bytesToBase64(raw), mediaType: ctype.split(';')[0]!.trim() },
      kanit: null,
    }
  }

  // JSON (or something claiming to be).
  const text = new TextDecoder().decode(raw)
  const body = JSON.parse(text) as Record<string, unknown>
  const validated = OlaySchema.safeParse(body)
  if (!validated.success) throw new Error('şema')

  const meta = fromJson(body)
  const inline = validated.data.foto_base64
  return {
    ...meta,
    image: inline ? { data: inline.replace(/^data:[^,]+,/, ''), mediaType: 'image/jpeg' } : null,
    kanit: kanitFotoCoz(validated.data.foto_kanit_base64),
  }
}

/* ------------------------------------------------------------ camera photo */

// Upload time limit. The bridge waits 30 s for the whole answer, and the read
// before this may already have used up to OKUMA_BUTCE_MS (20 s, vlm.ts); a
// photo must never be the reason a reply is lost.
const FOTO_YUKLEME_MS = 5_000

/**
 * Stores this event's compressed photo and attaches it to what the decision
 * wrote (042) — called only AFTER a decision that wrote something, so ignored
 * or refused events never leave a file in the bucket.
 *
 * `kamera/<islem_id>.jpg`, never overwritten (`upsert: false`): a retry of the
 * same event finds its file there and just attaches it; a camera cannot
 * replace another event's photo. `kamera_foto_bagla` then writes the path only
 * where it is still empty, only on this event's ticket / stamp / exception.
 *
 * Best effort: every failure is logged and swallowed — the car's record and
 * the bridge's answer never depend on the picture. An upload that outlives the
 * limit may still land; unattached, the nightly purge removes it (025).
 */
async function kanitFotosunuBagla(
  admin: SupabaseClient,
  kanit: Uint8Array | null,
  islemId: string,
  biletId: string | null,
  zaman: string | null,
): Promise<void> {
  const yol = kameraFotoYolu(islemId)
  if (!kanit || !yol) return
  try {
    const yukleme = await sureSinirli(
      admin.storage
        .from(KANIT_FOTO_KOVA)
        .upload(yol, kanit, { contentType: 'image/jpeg', upsert: false }),
      FOTO_YUKLEME_MS,
    )
    if (yukleme === SURE_DOLDU) {
      console.warn(`kamera fotoğrafı ${FOTO_YUKLEME_MS} ms içinde yüklenemedi — fotoğrafsız`)
      return
    }
    if (!fotoYuklemeTamam(yukleme.error)) {
      console.error('kamera fotoğrafı yüklenemedi:', yukleme.error?.message)
      return
    }
    const { error } = await admin.rpc('kamera_foto_bagla', {
      p_islem_id: islemId,
      p_bilet_id: biletId,
      p_zaman: zaman,
      p_foto: yol,
    })
    if (error) console.error('kamera_foto_bagla başarısız:', error.message)
  } catch (e) {
    console.error('kamera fotoğrafı bağlanamadı:', e)
  }
}

/* -------------------------------------------------------------- RPC errors */

/**
 * An error from bilet_ac, kamera_cikis_bildir or kamera_tek_kapi, answered so
 * the bridge does the right thing with the car (rpcHataDurumu,
 * _shared/serit.ts):
 *   409  the database REFUSED — a business rule or bad data. Final: the
 *        bridge drops the event. The body is the RPC's own Turkish sentence,
 *        which the bridge prints, exactly as before.
 *   503  anything else — timeout, lock, connection, PostgREST, network. The
 *        bridge retries with the same islem_id, which all three treat as a
 *        replay. The raw text stays in our log, not in the response.
 */
function rpcHatasi(rpc: string, error: { code?: string | null; message: string }): Response {
  if (rpcHataDurumu(error.code) === 409) {
    console.error(`${rpc} reddetti:`, error.message)
    return json({ hata: error.message }, 409)
  }
  console.error(`${rpc} geçici hata (${error.code || 'kod yok'}):`, error.message)
  return json({ hata: GECICI_HATA }, 503)
}

/* -------------------------------------------------------------------- main */

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') return json({ hata: 'Yalnızca POST.' }, 405)

  // /functions/v1/kamera-webhook/<secret>/<yon>  — both segments optional
  const url = new URL(req.url)
  const segments = url.pathname.split('/').filter(Boolean)
  const at = segments.indexOf('kamera-webhook')
  const pathSecret = at >= 0 ? (segments[at + 1] ?? null) : null
  const pathYon = at >= 0 ? (segments[at + 2] ?? null) : null

  // Created BEFORE the credential check, because a per-camera credential is
  // verified against the database. Constructing the client does no I/O, so an
  // unauthenticated request still costs nothing.
  const admin = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { auth: { persistSession: false } },
  )

  const { ok: yetkili, gecici, cihazId, cihazYon } = await kimlik(req, pathSecret, admin)
  if (!yetkili) {
    // The lookup failed, not the key (already logged in kimlik): retried.
    if (gecici) return json({ hata: GECICI_HATA }, 503)
    // No detail in the body: a probe learns nothing about which half was wrong.
    console.warn('kamera-webhook: reddedilen istek')
    return json({ hata: 'Yetkisiz.' }, 401)
  }

  try {
    const raw = new Uint8Array(await req.arrayBuffer())
    if (raw.length > MAX_BODY_BYTES) return json({ hata: 'Gövde çok büyük.' }, 413)

    // A failed READ is not "switched off" (kameraGirisiKarari): answered 403,
    // the bridge dropped the car and reported camera input as off.
    const okunan = await admin
      .from('otopark_ayarlari')
      .select('kamera_aktif, plaka_saglayici, plaka_model')
      .eq('id', 1)
      .single()
    const giris = kameraGirisiKarari(okunan.data, okunan.error)
    if (!giris.ok) {
      if (giris.durum === 503) {
        console.error(
          `kamera-webhook: ayarlar okunamadı (${okunan.error?.code || 'kod yok'}):`,
          okunan.error?.message,
        )
      }
      return json({ hata: giris.hata }, giris.durum)
    }
    const ayar = giris.ayar

    // The heartbeat is bumped for any AUTHENTICATED request, even one that
    // ends as an exception — "the camera is alive" and "the event was usable"
    // are different facts, and the watchdog only cares about the first.
    //
    // A paired camera stamps ITS OWN row and nothing else; an env-secret
    // bridge has no row and stamps the global one, exactly as before. They are
    // kept apart on purpose: if a paired camera also refreshed the global
    // stamp, a live exit camera would hide a dead hand-installed entrance
    // bridge — the very gap 036 exists to close.
    //
    // EXCEPT a request the installer marks as a trial (`x-kamera-deneme: 1`,
    // sent by its connection test and by its "is the stored credential still
    // good" probe). That request proves the credential and nothing more: the
    // bridge is not running yet. Stamping it would show the camera as working
    // in the app while the wizard is still at step two, and would close the
    // window in which the same setup code can be exchanged again (open until
    // the camera's FIRST heartbeat — see 036 kamera_eslestir). The header can
    // only withhold a heartbeat, never forge one, so honouring it is safe.
    const deneme = req.headers.get('x-kamera-deneme') === '1'
    if (deneme) {
      /* credential checked above; nothing to stamp */
    } else if (cihazId) {
      await admin.rpc('kamera_kalp_cihaz', { p_cihaz_id: cihazId })
    } else {
      await admin.rpc('kamera_kalp')
    }

    // Cheap flood guard on the tickets the webhook can create. It does NOT
    // limit the paid reads — that cap sits right before the read, below.
    const birDakika = new Date(Date.now() - 60_000).toISOString()
    const birGun = new Date(Date.now() - 86_400_000).toISOString()
    const [dk, gn] = await Promise.all([
      admin
        .from('biletler')
        .select('id', { count: 'exact', head: true })
        .eq('giris_kaynak', 'KAMERA')
        .gte('created_at', birDakika),
      admin
        .from('biletler')
        .select('id', { count: 'exact', head: true })
        .eq('giris_kaynak', 'KAMERA')
        .gte('created_at', birGun),
    ])
    if ((dk.count ?? 0) >= DAKIKA_LIMIT || (gn.count ?? 0) >= GUN_LIMIT) {
      console.warn('kamera-webhook: hız sınırı aşıldı')
      return json({ hata: 'Hız sınırı.' }, 429)
    }

    let olay: Olay
    try {
      olay = await readEvent(req, raw)
    } catch {
      return json({ hata: 'Geçersiz gövde.' }, 400)
    }

    // Direction is never guessed. One camera watches one lane, so it comes
    // from configuration; defaulting it would let a misconfigured exit camera
    // silently open tickets. For a PAIRED camera the configuration is the
    // server's own row, and a request that disagrees with it is refused — see
    // _shared/serit.ts.
    const serit = seritKarari(cihazYon, pathYon ?? url.searchParams.get('yon') ?? olay.yon)
    if (!serit.ok) {
      if (serit.durum === 409) {
        console.warn(`kamera-webhook: şerit uyuşmazlığı (${cihazId}) — ${serit.hata}`)
      }
      return json(serit.kod ? { hata: serit.hata, kod: serit.kod } : { hata: serit.hata }, serit.durum)
    }
    const yon = serit.yon

    // A camera event with no timestamp is refused outright — billing it from
    // now() is how a buffered 14:00 arrival becomes a 30-minute charge.
    if (!olay.zaman) {
      return json({ hata: 'Zaman damgası olmadan kabul edilmez.' }, 400)
    }

    let plaka = olay.plaka ? tidyPlaka(olay.plaka) : ''
    let guven: number | null = null
    // Kept so the ticket can be linked to the read that produced it below.
    let okumaId: string | null = null
    // "The model saw no vehicle at all" — told to the bridge on a 422 so it can
    // learn what the empty gate looks like and stop paying to send it. False
    // whenever there was no read, so only a real model answer can teach it.
    let aracYok = false
    // Whether a photo was actually read here, and the model's best guess even
    // when it was not good enough to use — both go into the exception row an
    // unreadable entrance plate now produces (039).
    let okundu = false
    let tahmin = ''

    // No plate text but a picture? That is the thin-bridge topology: the JPEG
    // is all the model needs, so camera OCR was never required.
    if (!plaka && olay.image) {
      if ((ayar.plaka_saglayici ?? 'KAPALI') === 'KAPALI') {
        return json({ hata: 'Görsel geldi ama plaka okuma kapalı.' }, 409)
      }

      // The PAID read is capped here, right before it is made (040). The
      // ticket guard above cannot do it: most reads open no ticket — an empty
      // lane, an unreadable plate, a failed read, every exit, every retry.
      // Counted: this webhook's own tagged log rows, all lanes together.
      // Placed here so only requests that really pay are counted; a plate-
      // string camera, a heartbeat or a trial never reaches it.
      //
      // At the cap: 429, which the bridge retries and then drops the car, and
      // an hourly Yönetici alert. No exception row per car — a flood through a
      // leaked key would fill that list with fake cars. If counting fails the
      // car is still read (okumaSiniriKarari, owner's choice): a 503 here would
      // drop every camera car for as long as counting fails, silently.
      const [okumaDk, okumaGn] = await Promise.all([
        admin
          .from('plaka_okuma_log')
          .select('id', { count: 'exact', head: true })
          .eq('kaynak', KAMERA_OKUMA_KAYNAGI)
          .gte('created_at', birDakika),
        admin
          .from('plaka_okuma_log')
          .select('id', { count: 'exact', head: true })
          .eq('kaynak', KAMERA_OKUMA_KAYNAGI)
          .gte('created_at', birGun),
      ])
      const sinir = okumaSiniriKarari(okumaDk, okumaGn)
      if (!sinir.ok) {
        console.warn(
          `kamera-webhook: okuma sınırı aşıldı (1 dk: ${okumaDk.count ?? '?'}, 24 sa: ${okumaGn.count ?? '?'})`,
        )
        const { error: sinirErr } = await admin.rpc('kamera_okuma_siniri')
        if (sinirErr) console.error('kamera_okuma_siniri başarısız:', sinirErr.message)
        return json({ hata: sinir.hata }, sinir.durum)
      }
      if (sinir.sayilamadi) {
        const e = okumaDk.error ?? okumaGn.error
        console.error(
          `kamera-webhook: okumalar sayılamadı (${e?.code || 'kod yok'}) — sınır bu okumada uygulanmadı:`,
          e?.message,
        )
      }

      // A THROW HERE HAS TO LEAVE A TRACE. Without this the outer catch
      // returns 500 and writes nothing: an expired key or an empty credit
      // balance makes every camera event fail silently, the bridge retries
      // four times and gives up, and entries simply stop being recorded —
      // with no operator present to notice. This is the unattended half of
      // the gap already closed in plaka-oku. A HUNG provider lands here too:
      // plakaOku ends within OKUMA_BUTCE_MS by throwing OkumaSuresiDoldu
      // (before that, a hang never threw and this branch never ran).
      let sonuc
      try {
        sonuc = await plakaOku(
          ayar.plaka_saglayici,
          ayar.plaka_model,
          olay.image.data,
          olay.image.mediaType,
        )
      } catch (okuErr) {
        console.error('kamera plaka okuma hatası:', okuErr)
        // Tagged like every camera read: a failed call may still have been
        // paid for, and it is what a retrying outage multiplies.
        await admin.from('plaka_okuma_log').insert(
          kameraOkumaLogu({
            saglayici: ayar.plaka_model ?? ayar.plaka_saglayici,
            ham_yanit: { hata: String(okuErr).slice(0, 500) },
            guven: null,
            onerilen: null,
          }),
        )
        // The log row alone left a total outage invisible: with the credit
        // used up EVERY camera car failed here while heartbeats kept the
        // watchdog quiet. Now the Yönetici is alerted (at most hourly), and on
        // the bridge's LAST attempt the car becomes an exception row. Never
        // earlier — see sonGonderimMi. Still 502, so the bridge retries as
        // before; a failure here must not change what the bridge sees.
        const hataIslemId =
          olay.islemId ?? (await deriveIslemId([olay.cihaz, yon, olay.zaman, 'OKUMA_HATASI']))
        const sonGonderim = sonGonderimMi(req.headers.get('x-kamera-son-gonderim'))
        const { error: hataErr } = await admin.rpc('kamera_okuma_hatasi', {
          p_yon: yon,
          p_islem_id: hataIslemId,
          p_zaman: olay.zaman,
          p_hata: String(okuErr).slice(0, 300),
          p_son_gonderim: sonGonderim,
          p_ham: olay.ham,
        })
        if (hataErr) console.error('kamera_okuma_hatasi başarısız:', hataErr.message)
        // The row exists only on the last try (and not on the exit lane);
        // there the photo is the ONLY clue which car it was (042).
        else if (okumaHatasiKaydedilir(yon, sonGonderim)) {
          await kanitFotosunuBagla(admin, olay.kanit, hataIslemId, null, olay.zaman)
        }
        return json({ hata: 'Plaka okunamadı.' }, 502)
      }

      okundu = true
      guven = sonuc.parsed.guven
      aracYok = aracYokMu(sonuc.parsed)
      const temiz = tidyPlaka(sonuc.parsed.plaka)
      tahmin = temiz
      // Same judgement as the phone, from the same helper — a camera that
      // read a shape no Turkish plate has is not evidence, it is noise.
      if (okumaGuvenilir(temiz, sonuc.parsed.guven, sonuc.parsed.okunamadi)) {
        plaka = temiz
      }
      const { data: log } = await admin
        .from('plaka_okuma_log')
        .insert(
          kameraOkumaLogu({
            saglayici: sonuc.saglayici,
            ham_yanit: sonuc.raw as Record<string, unknown>,
            guven: sonuc.parsed.guven,
            onerilen: temiz || null,
          }),
        )
        .select('id')
        .single()
      okumaId = log?.id ?? null
    }

    if (!plaka) {
      // A car the model saw but could not read used to vanish here: no ticket,
      // no exception, nobody told. On the entrance and single-gate lanes it is
      // now an exception row with the usual Yönetici notification (039). The
      // bridge does not retry a 422 it receives, but if this reply is lost (a
      // slow read past its 30 s timeout, a Wi-Fi drop) it retries the same
      // islem_id, and that retry may read the plate. The RPC deduplicates on
      // islem_id and writes nothing if a faster retry already opened the
      // ticket; on the single gate, kamera_tek_kapi closes this row when a
      // retry handles the car (041).
      let istisna = false
      if (okunamadiKaydedilir(yon, okundu, aracYok)) {
        const okIslemId =
          olay.islemId ?? (await deriveIslemId([olay.cihaz, yon, olay.zaman, tahmin]))
        const { data: okId, error: okErr } = await admin.rpc('kamera_okunamadi', {
          p_yon: yon,
          p_islem_id: okIslemId,
          p_zaman: olay.zaman,
          p_tahmin: tahmin || null,
          p_guven: guven,
          p_ham: olay.ham,
        })
        if (okErr) console.error('kamera_okunamadi başarısız:', okErr.message)
        else {
          istisna = true
          // NULL = a faster retry already handled the car and no row was
          // written (041); that retry attached its own photo.
          if (okId) await kanitFotosunuBagla(admin, olay.kanit, okIslemId, null, olay.zaman)
        }
      }
      // `arac_yok` and `istisna` are additive: older bridges ignore them.
      return json({ hata: 'Plaka okunamadı.', guven, arac_yok: aracYok, istisna }, 422)
    }

    // Cameras do not send UUIDs, and bilet_ac requires an idempotency key, so
    // derive a stable one from the event itself. A retry of the same event
    // hashes identically and becomes a no-op; a different car at the same
    // second does not.
    const islemId =
      olay.islemId ?? (await deriveIslemId([olay.cihaz, yon, olay.zaman, plaka]))

    // One gate for both directions: the lane cannot say whether this car is
    // arriving or leaving, so the database decides from the ticket state and
    // refuses to guess when it cannot tell (037 kamera_tek_kapi). Kept as its
    // own branch, ABOVE the two-lane code, so that code stays byte-for-byte
    // what it was.
    if (yon === 'ORTAK') {
      const { data, error } = await admin.rpc('kamera_tek_kapi', {
        p_plaka: plaka,
        p_islem_id: islemId,
        p_zaman: olay.zaman,
        p_foto: null,
        p_ham: olay.ham,
      })
      if (error) return rpcHatasi('kamera_tek_kapi', error)
      // An answer that is not one of the four decisions is OUR fault, not a
      // decision: say 500 so the bridge retries (same islem_id, replay-safe)
      // instead of 200, which would tell it the car has been dealt with.
      const sonuc = tekKapiCevabi(data)
      if (!sonuc.ok) {
        console.error('kamera_tek_kapi tanınmayan cevap:', JSON.stringify(data))
        return json({ hata: 'İşlenemedi.' }, 500)
      }
      const biletId = sonuc.biletId

      // Same reason as the entrance lane below: nobody looked at this plate.
      // Only when a ticket was OPENED — flagging an exit creates no read to
      // vouch for, the ticket's plate was set when the car came in.
      if (sonuc.karar === 'GIRIS' && biletId && okumaId) {
        const { error: bagErr } = await admin.rpc('kamera_okuma_bagla', {
          p_bilet_id: biletId,
          p_okuma_id: okumaId,
        })
        if (bagErr) console.error('kamera_okuma_bagla başarısız:', bagErr.message)
      }

      // The photo goes where the decision wrote: the new ticket (GIRIS), the
      // stamped one (CIKIS: bilet + this event's time) or the exception row.
      // YOKSAY wrote nothing, so nothing is uploaded (042).
      if (tekKapiFotoGerekli(sonuc.karar)) {
        await kanitFotosunuBagla(admin, olay.kanit, islemId, biletId, olay.zaman)
      }

      // 200 for every decision, including "ignored" and "left for a person":
      // the event WAS handled, and a retry must not hammer. `karar` and
      // `sebep` are in the body on purpose — the bridge prints the response,
      // so each decision can be read in its log on site.
      return json(
        {
          ok: true,
          karar: sonuc.karar,
          sebep: sonuc.sebep,
          bilet_id: biletId,
          islem_id: islemId,
          istisna: sonuc.karar === 'ISTISNA',
        },
        200,
      )
    }

    if (yon === 'GIRIS') {
      const { data, error } = await admin.rpc('bilet_ac', {
        p_plaka: plaka,
        p_islem_id: islemId,
        p_kaynak: 'KAMERA',
        p_zaman: olay.zaman,
        p_foto: null,
        p_park_yeri_id: null,
        p_ham_yanit: olay.ham,
      })
      if (error) return rpcHatasi('bilet_ac', error)
      // Flag a shaky read on the ticket. THIS is the path that needs it:
      // on a phone an operator looked at the plate and confirmed it, here
      // nobody did. Deliberately after the ticket exists and deliberately
      // not fatal — failing costs a badge, never an entry.
      if (data && okumaId) {
        const { error: bagErr } = await admin.rpc('kamera_okuma_bagla', {
          p_bilet_id: data,
          p_okuma_id: okumaId,
        })
        if (bagErr) console.error('kamera_okuma_bagla başarısız:', bagErr.message)
      }
      // On the ticket, or on the exception written instead of one (042).
      await kanitFotosunuBagla(admin, olay.kanit, islemId, data ?? null, olay.zaman)

      // null = the RPC logged an exception instead of opening a ticket
      // (too old, or dated in the future). That is a success for the webhook:
      // the event was handled, deliberately, and a retry must not hammer.
      return json({ ok: true, bilet_id: data, islem_id: islemId, istisna: data === null }, 200)
    }

    const { data, error } = await admin.rpc('kamera_cikis_bildir', {
      p_plaka: plaka,
      p_islem_id: islemId,
      p_zaman: olay.zaman,
      p_foto: null,
      p_ham: olay.ham,
    })
    if (error) return rpcHatasi('kamera_cikis_bildir', error)
    // On the stamp this event wrote (bilet + time), or on the exception (042).
    await kanitFotosunuBagla(admin, olay.kanit, islemId, data ?? null, olay.zaman)
    return json({ ok: true, bilet_id: data, islem_id: islemId, istisna: data === null }, 200)
  } catch (err) {
    console.error('kamera-webhook hatası:', err)
    return json({ hata: 'İşlenemedi.' }, 500)
  }
})
