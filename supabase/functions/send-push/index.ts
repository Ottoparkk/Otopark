/**
 * send-push — delivers a Web Push for one notifications row.
 *
 * Driven by a Supabase database webhook on INSERT into public.notifications,
 * so nothing in the app has to remember to call it.
 *
 * Auth: x-push-secret header. JWT verification is OFF (a database webhook
 * cannot present one), which makes the shared secret the whole boundary —
 * see SETUP.md for generating and rotating it.
 */
import { createClient } from 'npm:@supabase/supabase-js@2.112.3'
import webpush from 'npm:web-push@3.6.7'
import { json, safeEqual } from '../_shared/http.ts'

interface Kayit {
  id: string
  profile_id: string
  tur: string
  baslik: string
  govde: string
  link: string | null
}

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') return json({ hata: 'Yalnızca POST.' }, 405)

  const expected = Deno.env.get('PUSH_SECRET') ?? ''
  const given = req.headers.get('x-push-secret') ?? ''
  if (expected.length < 16 || !safeEqual(given, expected)) {
    console.warn('send-push: yetkisiz istek')
    return json({ hata: 'Yetkisiz.' }, 401)
  }

  const publicKey = Deno.env.get('VAPID_PUBLIC_KEY') ?? ''
  const privateKey = Deno.env.get('VAPID_PRIVATE_KEY') ?? ''
  const subject = Deno.env.get('VAPID_SUBJECT') ?? 'mailto:destek@example.com'
  if (!publicKey || !privateKey) {
    return json({ hata: 'VAPID anahtarları eksik.' }, 500)
  }
  webpush.setVapidDetails(subject, publicKey, privateKey)

  try {
    const payload = await req.json()
    const kayit = (payload?.record ?? payload) as Kayit
    if (!kayit?.profile_id || !kayit?.baslik) {
      return json({ hata: 'Geçersiz kayıt.' }, 400)
    }

    const admin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
      { auth: { persistSession: false } },
    )

    // Mirror the RLS policy at send time. A notification generated while
    // someone was Yönetici must not reach their phone after a demotion —
    // otherwise push becomes a side channel around the role check.
    const { data: profile } = await admin
      .from('profiles')
      .select('rol, durum, notif_prefs')
      .eq('id', kayit.profile_id)
      .single()

    if (!profile || profile.durum !== 'ACTIVE') {
      return json({ ok: true, atlandi: 'pasif hesap' }, 200)
    }

    const { data: yoneticiTuru } = await admin.rpc('bildirim_yonetici_turu', { p_tur: kayit.tur })
    if (yoneticiTuru && profile.rol !== 'YONETICI') {
      return json({ ok: true, atlandi: 'rol uyuşmuyor' }, 200)
    }

    const prefs = (profile.notif_prefs ?? {}) as Record<string, unknown>
    if (String(prefs[kayit.tur] ?? 'true') === 'false') {
      return json({ ok: true, atlandi: 'tercih kapalı' }, 200)
    }

    const { data: subs } = await admin
      .from('push_subscriptions')
      .select('endpoint, p256dh, auth')
      .eq('profile_id', kayit.profile_id)

    if (!subs?.length) return json({ ok: true, gonderilen: 0 }, 200)

    const body = JSON.stringify({
      title: kayit.baslik,
      body: kayit.govde,
      link: kayit.link ?? '/',
      // Same-type notices collapse instead of stacking up on the lock screen.
      tag: kayit.tur,
    })

    let sent = 0
    const stale: string[] = []

    await Promise.all(
      subs.map(async (s) => {
        try {
          await webpush.sendNotification(
            { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
            body,
          )
          sent++
        } catch (err) {
          const code = (err as { statusCode?: number }).statusCode
          // 404/410 mean the browser threw the subscription away. Pruning here
          // is what stops a dead phone from being retried forever.
          if (code === 404 || code === 410) stale.push(s.endpoint)
          else console.error('push hatası:', code, (err as Error).message)
        }
      }),
    )

    if (stale.length) {
      await admin.from('push_subscriptions').delete().in('endpoint', stale)
    }

    return json({ ok: true, gonderilen: sent, temizlenen: stale.length }, 200)
  } catch (err) {
    console.error('send-push hatası:', err)
    return json({ hata: 'Gönderilemedi.' }, 500)
  }
})
