/**
 * kamera-eslestir — turns a short pairing code into a camera's own credential.
 *
 * WHY THIS EXISTS AT ALL: KAMERA_WEBHOOK_SECRET lives only in this function's
 * environment, and .env.example forbids it ever becoming a VITE_ variable. So
 * the browser cannot build a setup code containing a credential, and the
 * exchange has to happen here, server-side. The app only ever mints a short
 * code; the secret is created and handed over at this endpoint and nowhere
 * else.
 *
 * WHAT THE BRIDGE ENDS UP HOLDING is its OWN secret, not the shared one. Only
 * its SHA-256 is stored, so reading the database yields nothing usable, and
 * one camera can be revoked without touching the other.
 *
 * Security posture (OWASP 2025):
 *   A01  The code is the only credential accepted here, it belongs to ONE
 *        camera, and it expires in 15 minutes. kamera_eslestir is granted to
 *        service_role ONLY — a browser cannot reach it even with a valid code.
 *   A02  The minted secret is never stored in clear. Until the camera has
 *        connected once, the same code may be exchanged again (a response lost
 *        on the way would otherwise burn the code and strand a dead device);
 *        each exchange REPLACES the secret, so an earlier answer stops working.
 *        After the first heartbeat the code is dead.
 *   A03  Body is zod-validated and size-capped before the database is touched.
 *   A04  10 Crockford-base32 characters = 50 bits. Guessing one inside its
 *        15-minute life is not a realistic attack, so there is no counter to
 *        keep; failures still cost a fixed delay and are logged.
 *   A09  Every refusal is logged with its reason.
 *   A10  A refused code (400) and a fault of ours (500) are told apart; the
 *        fault's detail is logged and never sent to the unauthenticated caller.
 */
import { createClient } from 'npm:@supabase/supabase-js@2.112.3'
import { z } from 'npm:zod@4.4.3'
import { json } from '../_shared/http.ts'

const MAX_BODY_BYTES = 4 * 1024

/** A fixed cost on every failure, whatever its cause. */
const RED_GECIKME_MS = 300

/** SQLSTATE that 036's kamera_eslestir raises for every refusal of a code. */
const KOD_REDDI = 'KE001'

const GovdeSchema = z.object({
  kod: z.string().min(1).max(64),
})

Deno.serve(async (req: Request): Promise<Response> => {
  // No OPTIONS branch, matching kamera-webhook: the caller is the Python
  // installer, never a browser, so there is no preflight to answer.
  if (req.method !== 'POST') {
    return json({ hata: 'POST bekleniyor.' }, 405)
  }

  let kod: string
  try {
    const raw = new Uint8Array(await req.arrayBuffer())
    if (raw.length > MAX_BODY_BYTES) {
      return json({ hata: 'Gövde çok büyük.' }, 413)
    }
    kod = GovdeSchema.parse(JSON.parse(new TextDecoder().decode(raw))).kod
  } catch {
    return json({ hata: 'Geçersiz gövde.' }, 400)
  }

  const admin = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { auth: { persistSession: false } },
  )

  // Normalisation lives in the RPC too, so a code typed with spaces, lower
  // case or no dash works whichever side it arrives through.
  const { data, error } = await admin.rpc('kamera_eslestir', { p_kod: kod })

  if (error) {
    await new Promise((r) => setTimeout(r, RED_GECIKME_MS))

    // KE001 is the RPC saying "I refused THIS CODE" — wrong, expired or spent.
    // Only those messages are meant for the person at the installer, so only
    // those leave the function. "Geçersiz" covers both "wrong length" and "no
    // such code" on purpose; "expired" and "already used" are told apart
    // because the installer needs to know which, and at 50 bits confirming
    // that a guessed code once existed is not worth hiding.
    if (error.code === KOD_REDDI) {
      console.warn('kamera-eslestir: reddedildi —', error.message)
      return json({ hata: error.message }, 400)
    }

    // Anything else is OUR fault, not the code's — a missing grant, a database
    // that is down. The caller is unauthenticated, so it gets no detail, and
    // it gets a 500 so the installer does not tell someone their code is bad.
    console.error('kamera-eslestir: eşleştirme başarısız —', error.code, error.message)
    return json({ hata: 'Eşleştirme şu anda yapılamıyor. Birkaç dakika sonra tekrar deneyin.' }, 500)
  }

  const sonuc = data as { cihaz: string; gizli: string; yon: string; ad: string }

  // Derived, never hardcoded: SUPABASE_URL is injected into every Edge
  // Function, so the bridge is told the address of the project it just paired
  // with rather than one the installer had to be told separately.
  const webhookUrl = `${Deno.env.get('SUPABASE_URL')}/functions/v1/kamera-webhook`

  console.log(`kamera-eslestir: ${sonuc.yon} şeridi eşleştirildi (${sonuc.cihaz})`)

  return json(
    {
      webhook_url: webhookUrl,
      gizli: sonuc.gizli,
      yon: sonuc.yon,
      cihaz: sonuc.cihaz,
      ad: sonuc.ad,
    },
    200,
  )
})
