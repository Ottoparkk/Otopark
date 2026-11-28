/**
 * personel-olustur — the Yönetici adds a worker with only a name and a PIN.
 *
 * Workers on the shared terminal never see an email or a password (084).
 * Behind the scenes they still need an auth account — that is what keeps
 * RLS, "who did what" and the own-shift rules working — so this function
 * creates one with a synthetic address that can never receive mail, then
 * calls personel_pin_olustur to make it an ACTIVE Personel with that PIN.
 *
 * Security posture (OWASP 2025):
 *   A01  JWT on (config.toml) PLUS an explicit ACTIVE Yönetici check here,
 *        and the RPC re-checks the caller id again. Creating accounts is the
 *        most sensitive thing the app does, so the boundary is doubled.
 *   A02  The service key never leaves this function. The account gets no
 *        password; the only way in is the terminal PIN (or a Yönetici-set
 *        email later).
 *   A04  The new account starts PENDING; the RPC activates it in the same
 *        call. If the RPC fails, the half-made auth user is deleted again so
 *        no orphan PENDING account is left behind.
 */
import { createClient } from 'npm:@supabase/supabase-js@2.112.3'
import { z } from 'npm:zod@4.6.7'
import { corsHeaders, json } from '../_shared/http.ts'

/** Reserved TLD (RFC 2606): mail to it can never be delivered. */
const SENTETIK_ALAN = 'personel.otopark.invalid'

const GovdeSchema = z.object({
  ad_soyad: z.string().trim().min(2).max(80),
  pin: z.string().regex(/^[0-9]{4}$/),
})

Deno.serve(async (req: Request): Promise<Response> => {
  const origin = req.headers.get('origin')
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders(origin) })
  if (req.method !== 'POST') return json({ hata: 'POST bekleniyor.' }, 405, origin)

  const authHeader = req.headers.get('Authorization') ?? ''
  if (!authHeader.startsWith('Bearer ')) return json({ hata: 'Oturum gerekli.' }, 401, origin)

  const admin = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { auth: { persistSession: false } },
  )

  const { data: userData, error: userErr } = await admin.auth.getUser(
    authHeader.replace('Bearer ', ''),
  )
  if (userErr || !userData.user) return json({ hata: 'Oturum geçersiz.' }, 401, origin)
  const cagiran = userData.user.id

  const { data: profil } = await admin
    .from('profiles')
    .select('rol, durum')
    .eq('id', cagiran)
    .single()
  if (!profil || profil.rol !== 'YONETICI' || profil.durum !== 'ACTIVE') {
    return json({ hata: 'Yalnızca Yönetici personel ekleyebilir.' }, 403, origin)
  }

  const istek = GovdeSchema.safeParse(await req.json().catch(() => null))
  if (!istek.success) return json({ hata: 'Ad (en az 2 harf) ve 4 haneli PIN gerekli.' }, 400, origin)

  const { data: yeni, error: olusturHata } = await admin.auth.admin.createUser({
    email: `p-${crypto.randomUUID()}@${SENTETIK_ALAN}`,
    email_confirm: true,
    // app_metadata only service_role can write: handle_new_user (084) skips
    // the "Yeni kayıt isteği" notice for these accounts.
    app_metadata: { pin_personel: true },
    user_metadata: { ad_soyad: istek.data.ad_soyad },
  })
  if (olusturHata || !yeni.user) {
    console.error('personel-olustur: hesap açılamadı —', olusturHata?.message)
    return json({ hata: 'Hesap açılamadı.' }, 500, origin)
  }

  const { error: rpcHata } = await admin.rpc('personel_pin_olustur', {
    p_id: yeni.user.id,
    p_pin: istek.data.pin,
    p_olusturan: cagiran,
  })
  if (rpcHata) {
    console.error('personel-olustur: etkinleştirilemedi —', rpcHata.code, rpcHata.message)
    await admin.auth.admin.deleteUser(yeni.user.id)
    return json({ hata: 'Personel eklenemedi.' }, 500, origin)
  }

  return json({ id: yeni.user.id }, 200, origin)
})
