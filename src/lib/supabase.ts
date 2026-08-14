import { createClient } from '@supabase/supabase-js'
import { safeStorage } from './storage'

const url = import.meta.env.VITE_SUPABASE_URL
const key = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY

if (!url || !key) {
  throw new Error(
    'Supabase ortam değişkenleri eksik: VITE_SUPABASE_URL / VITE_SUPABASE_PUBLISHABLE_KEY',
  )
}

/**
 * The publishable key is public by design — it is compiled into the bundle
 * and RLS is the security boundary, not this string.
 *
 * safeStorage: sessions persist normally; in storage-restricted contexts auth
 * degrades to in-memory instead of crashing the app.
 */
export const supabase = createClient(url, key, {
  auth: { storage: safeStorage },
})

export const SUPABASE_URL = url
