/**
 * terminal-giris — name + 4-digit PIN sign-in on the shared handheld (084).
 *
 * The gate's one handheld is shared by the day and the night worker. Nobody
 * types an email or a password there: the incoming worker picks their name,
 * enters their PIN, and the app switches the session to their account. That
 * moment is also the shift handover (vardiya_devret, inside the RPC).
 *
 *   {islem:'liste', gizli}                    → { personel: [{id, ad_soyad}] }
 *   {islem:'giris', gizli, profile_id, pin}   → { token_hash }
 *
 * The client exchanges token_hash with supabase.auth.verifyOtp({ token_hash,
 * type: 'email' }) for a real session — the same account, RLS and audit as an
 * email sign-in, so every rule downstream is unchanged.
 *
 * Security posture (OWASP 2025):
 *   A01  The terminal's own secret (64 hex, 244 bits, minted once by a
 *        Yönetici) is the credential; only its SHA-256 is stored. A PIN is
 *        useless without the device that holds that secret.
 *   A04  5 wrong PINs lock that person for 15 minutes and alert the Yönetici
 *        (in the RPC, so the counter cannot be bypassed from here). Every
 *        refusal also costs a fixed delay.
 *   A07  The magic-link token is single-use and short-lived; it is handed
 *        only to the caller that proved terminal + PIN in this same request.
 *   A10  A refusal (400, message for the person at the terminal) and a fault
 *        of ours (500, no detail) are told apart.
 */
import { createClient } from 'npm:@supabase/supabase-js@2.112.3'
import { z } from 'npm:zod@4.6.7'
import { corsHeaders, json } from '../_shared/http.ts'

const MAX_BODY_BYTES = 4 * 1024
const RED_GECIKME_MS = 300
/** SQLSTATE 084 raises when the terminal secret is not recognised. */
const TERMINAL_REDDI = 'TG001'

const Gizli = z.string().regex(/^[0-9a-f]{64}$/)
const GovdeSchema = z.discriminatedUnion('islem', [
  z.object({ islem: z.literal('liste'), gizli: Gizli }),
  z.object({
    islem: z.literal('giris'),
    gizli: Gizli,
    profile_id: z.string().uuid(),
    pin: z.string().regex(/^[0-9]{4}$/),
  }),
])

async function sha256Hex(metin: string): Promise<string> {
  const ozet = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(metin))
  return Array.from(new Uint8Array(ozet), (b) => b.toString(16).padStart(2, '0')).join('')
}

const bekle = () => new Promise((r) => setTimeout(r, RED_GECIKME_MS))

Deno.serve(async (req: Request): Promise<Response> => {
  const origin = req.headers.get('origin')
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders(origin) })
  if (req.method !== 'POST') return json({ hata: 'POST bekleniyor.' }, 405, origin)

  let govde: z.infer<typeof GovdeSchema>
  try {
    const raw = new Uint8Array(await req.arrayBuffer())
    if (raw.length > MAX_BODY_BYTES) return json({ hata: 'Gövde çok büyük.' }, 413, origin)
    govde = GovdeSchema.parse(JSON.parse(new TextDecoder().decode(raw)))
  } catch {
    await bekle()
    return json({ hata: 'Geçersiz istek.' }, 400, origin)
  }

  const admin = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { auth: { persistSession: false } },
  )
  const hash = await sha256Hex(govde.gizli)

  if (govde.islem === 'liste') {
    const { data, error } = await admin.rpc('terminal_personel_listesi', { p_gizli_hash: hash })
    if (error) {
      await bekle()
      if (error.code === TERMINAL_REDDI) return json({ hata: error.message }, 400, origin)
      console.error('terminal-giris: liste başarısız —', error.code, error.message)
      return json({ hata: 'Liste şu anda alınamıyor.' }, 500, origin)
    }
    return json({ personel: data ?? [] }, 200, origin)
  }

  const { data, error } = await admin.rpc('terminal_pin_dogrula', {
    p_gizli_hash: hash,
    p_profile_id: govde.profile_id,
    p_pin: govde.pin,
  })
  if (error) {
    await bekle()
    console.error('terminal-giris: doğrulama başarısız —', error.code, error.message)
    return json({ hata: 'Giriş şu anda yapılamıyor.' }, 500, origin)
  }

  const sonuc = data as { ok: boolean; mesaj?: string; email?: string }
  if (!sonuc.ok || !sonuc.email) {
    await bekle()
    console.warn('terminal-giris: reddedildi —', sonuc.mesaj)
    return json({ hata: sonuc.mesaj ?? 'Giriş reddedildi.' }, 400, origin)
  }

  // Generating a link sends NO email; it only mints the one-time token.
  const { data: link, error: linkErr } = await admin.auth.admin.generateLink({
    type: 'magiclink',
    email: sonuc.email,
  })
  if (linkErr || !link.properties?.hashed_token) {
    console.error('terminal-giris: oturum anahtarı üretilemedi —', linkErr?.message)
    return json({ hata: 'Giriş şu anda yapılamıyor.' }, 500, origin)
  }

  console.log(`terminal-giris: devir ${govde.profile_id}`)
  return json({ token_hash: link.properties.hashed_token }, 200, origin)
})
