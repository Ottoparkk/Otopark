/**
 * plaka-oku — reads a plate from a photo and returns a SUGGESTION.
 *
 * It never writes a ticket. It returns {plaka, guven, log_id}, which the client
 * uses to prefill a focused input the operator must confirm. That rule is what
 * keeps a hallucinated plate from ever becoming a wrong charge.
 *
 * Security posture (OWASP 2025):
 *   A01  JWT verification ON (config.toml) PLUS an explicit active-staff
 *        check — a valid token from a PENDING or DISABLED account is refused.
 *   A02  The API key lives in function secrets, never in the client bundle.
 *   A04  Rate limited per user. An image-analysis endpoint is a
 *        cost-amplification target; unmetered it is a billing DoS.
 *   A10  Request hosts are hardcoded in _shared/ocr.ts. The database supplies
 *        which model to use, never where to send it.
 */
import { createClient } from 'npm:@supabase/supabase-js@2.112.3'
import { z } from 'npm:zod@4.4.3'
import { corsHeaders, json } from '../_shared/http.ts'
import { normalizeImage, okumaGuvenilir, plakaOku, tidyPlaka } from '../_shared/ocr.ts'

const DAKIKA_LIMIT = 20 // reads per user per minute
const GUN_LIMIT = 500 // reads per user per day
const MAX_BYTES = 5 * 1024 * 1024

const IstekSchema = z.object({
  // data: URL or bare base64.
  foto_base64: z.string().min(64).max(12_000_000),
  media_type: z.enum(['image/jpeg', 'image/png', 'image/webp']).default('image/jpeg'),
})

Deno.serve(async (req: Request) => {
  const origin = req.headers.get('origin')
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders(origin) })
  if (req.method !== 'POST') return json({ hata: 'Yalnızca POST.' }, 405, origin)

  const started = Date.now()

  // Hoisted so the catch can still write to the log. A read that FAILS has to
  // leave a trace: without one, an expired key, an empty credit balance or an
  // Anthropic outage looks exactly like "nobody pressed the camera button" —
  // operators just type plates, which is what they would do anyway, so the
  // failure is invisible to everyone including the query that measures
  // accuracy. Same class of silent failure the camera heartbeat exists for.
  let admin: ReturnType<typeof createClient> | null = null
  let saglayiciAdi: string | null = null
  let userId: string | null = null

  try {
    const authHeader = req.headers.get('Authorization') ?? ''
    if (!authHeader.startsWith('Bearer ')) {
      return json({ hata: 'Oturum gerekli.' }, 401, origin)
    }

    admin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
      { auth: { persistSession: false } },
    )

    const { data: userData, error: userErr } = await admin.auth.getUser(
      authHeader.replace('Bearer ', ''),
    )
    if (userErr || !userData.user) return json({ hata: 'Oturum geçersiz.' }, 401, origin)
    userId = userData.user.id

    // A valid JWT is not enough — the account must be approved and active.
    const { data: profile } = await admin
      .from('profiles')
      .select('rol, durum')
      .eq('id', userId)
      .single()
    if (!profile || profile.rol === null || profile.durum !== 'ACTIVE') {
      return json({ hata: 'Yetkiniz yok.' }, 403, origin)
    }

    // The read log doubles as the rate-limit counter, so the audit trail and
    // the throttle are the same rows and cannot disagree.
    const birDakika = new Date(Date.now() - 60_000).toISOString()
    const birGun = new Date(Date.now() - 86_400_000).toISOString()
    const [dakika, gun] = await Promise.all([
      admin
        .from('plaka_okuma_log')
        .select('id', { count: 'exact', head: true })
        .eq('operator_id', userId)
        .gte('created_at', birDakika),
      admin
        .from('plaka_okuma_log')
        .select('id', { count: 'exact', head: true })
        .eq('operator_id', userId)
        .gte('created_at', birGun),
    ])
    if ((dakika.count ?? 0) >= DAKIKA_LIMIT || (gun.count ?? 0) >= GUN_LIMIT) {
      return json({ hata: 'Çok fazla okuma isteği. Biraz bekleyin.' }, 429, origin)
    }

    const istek = IstekSchema.safeParse(await req.json())
    if (!istek.success) return json({ hata: 'Geçersiz istek gövdesi.' }, 400, origin)

    const { data: image, bytes } = normalizeImage(istek.data.foto_base64)
    if (bytes > MAX_BYTES) return json({ hata: 'Görsel çok büyük.' }, 413, origin)

    const { data: ayar } = await admin
      .from('otopark_ayarlari')
      .select('plaka_saglayici, plaka_model')
      .eq('id', 1)
      .single()

    if ((ayar?.plaka_saglayici ?? 'KAPALI') === 'KAPALI') {
      return json({ hata: 'Plaka okuma kapalı.', kapali: true }, 409, origin)
    }

    // From here on a throw is a PROVIDER failure worth logging. Before this
    // point the refusals are ours (401/403/429/400) and already returned.
    saglayiciAdi = ayar!.plaka_model ?? ayar!.plaka_saglayici
    const sonuc = await plakaOku(
      ayar!.plaka_saglayici,
      ayar!.plaka_model,
      image,
      istek.data.media_type,
    )

    const temiz = tidyPlaka(sonuc.parsed.plaka)
    // One shared judgement, so the phone and the camera cannot rate the same
    // photo differently. A read that does not look like a Turkish plate has
    // to be much more confident to be offered at all.
    const guvenilir = okumaGuvenilir(temiz, sonuc.parsed.guven, sonuc.parsed.okunamadi)

    const { data: log } = await admin
      .from('plaka_okuma_log')
      .insert({
        saglayici: sonuc.saglayici,
        ham_yanit: sonuc.raw as Record<string, unknown>,
        guven: sonuc.parsed.guven,
        onerilen: temiz || null,
        operator_id: userId,
        gecen_ms: Date.now() - started,
      })
      .select('id')
      .single()

    return json(
      {
        // Null on a weak read. Prefilling a guess the operator might not check
        // is the one failure mode that turns into a wrong charge.
        plaka: guvenilir ? temiz : null,
        guven: sonuc.parsed.guven,
        saglayici: sonuc.saglayici,
        log_id: log?.id ?? null,
        dusuk_guven: !guvenilir,
      },
      200,
      origin,
    )
  } catch (err) {
    console.error('plaka-oku hatası:', err)

    // Best effort, and deliberately not awaited into the failure path: if the
    // log write itself fails the operator must still get an answer.
    //
    // The row counts toward the rate limit like any other, which is correct —
    // the limit counts ATTEMPTS. A provider that is down should not be
    // hammered on the operator's behalf.
    //
    // `guven` stays null rather than 0: there was no confidence, not zero
    // confidence, and a null keeps it out of every accuracy average.
    if (admin && saglayiciAdi) {
      try {
        await admin.from('plaka_okuma_log').insert({
          saglayici: saglayiciAdi,
          ham_yanit: { hata: String(err).slice(0, 500) },
          guven: null,
          onerilen: null,
          operator_id: userId ?? null,
          gecen_ms: Date.now() - started,
        })
      } catch (logErr) {
        console.error('plaka-oku log yazılamadı:', logErr)
      }
    }

    return json({ hata: 'Plaka okunamadı. Elle girin.' }, 502, origin)
  }
})
