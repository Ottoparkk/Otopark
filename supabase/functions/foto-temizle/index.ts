/**
 * foto-temizle — deletes expired photos through the Storage API (043).
 *
 * Called once a night by the database itself: run_gunluk_bakim (cron
 * `otopark-gunluk`) → foto_temizlik_tetikle() → pg_net POST here. Which photos
 * are expired is decided in SQL by foto_temizlik_listesi, from the app's own
 * retention setting (otopark_ayarlari.foto_saklama_gun, 1–30 days).
 *
 * Why it exists: the nightly job used to delete with SQL, which removes only
 * the metadata row; Supabase keeps the file, orphaned, counted against the
 * free 1 GB and kept past the retention (KVKK). Only the Storage API deletes
 * the file itself.
 *
 * Auth: x-temizlik-secret header vs FOTO_TEMIZLIK_SECRET. JWT verification is
 * OFF (pg_net presents none), so the shared secret is the whole boundary —
 * the send-push pattern. The worst a leaked secret allows is running the same
 * cleanup early: it can only delete what is already past retention.
 *
 * Never silent: a failure alerts the Yönetici (foto_temizlik_hata, at most
 * once a day). Logs counts only, never file names (they carry plates).
 */
import { createClient } from 'npm:@supabase/supabase-js@2.112.3'
import { json, safeEqual } from '../_shared/http.ts'
import { fotoTemizle } from '../_shared/temizlik.ts'

const KOVA = 'plaka-foto'

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') return json({ hata: 'Yalnızca POST.' }, 405)

  const expected = Deno.env.get('FOTO_TEMIZLIK_SECRET') ?? ''
  const given = req.headers.get('x-temizlik-secret') ?? ''
  if (expected.length < 16 || !safeEqual(given, expected)) {
    console.warn('foto-temizle: yetkisiz istek')
    return json({ hata: 'Yetkisiz.' }, 401)
  }

  const admin = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { auth: { persistSession: false } },
  )

  const sonuc = await fotoTemizle({
    listele: async (limit) => {
      const { data, error } = await admin.rpc('foto_temizlik_listesi', { p_limit: limit })
      if (error) throw new Error(`${error.code ?? ''} ${error.message}`.trim())
      return ((data ?? []) as unknown[]).filter((a): a is string => typeof a === 'string' && a !== '')
    },
    sil: async (adlar) => {
      const { data, error } = await admin.storage.from(KOVA).remove(adlar)
      if (error) throw new Error(error.message)
      return (data ?? []).length
    },
  })

  console.log(
    `foto-temizle: ${sonuc.silinen} dosya silindi, ${sonuc.tur} tur, ` +
      (sonuc.hata ? `HATA: ${sonuc.hata}` : sonuc.bitti ? 'bitti' : 'kalan yarın'),
  )

  if (sonuc.hata) {
    const { error } = await admin.rpc('foto_temizlik_hata', { p_mesaj: sonuc.hata })
    if (error) console.error('foto_temizlik_hata başarısız:', error.message)
    return json({ silinen: sonuc.silinen, tur: sonuc.tur, hata: sonuc.hata }, 500)
  }
  return json({ silinen: sonuc.silinen, tur: sonuc.tur, bitti: sonuc.bitti }, 200)
})
