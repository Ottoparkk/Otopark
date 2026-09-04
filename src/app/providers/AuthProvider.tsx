import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
  type ReactNode,
} from 'react'
import type { Session } from '@supabase/supabase-js'
import { supabase } from '../../lib/supabase'
import type { Profile } from '../../lib/types'

interface AuthContextValue {
  session: Session | null
  profile: Profile | null
  /** True until the FIRST session check resolves. Guards must wait on this —
   *  acting on `session === null` while still hydrating bounces a signed-in
   *  operator to the login screen on every cold app launch. */
  loading: boolean
  /**
   * The last profile fetch FAILED — a network error, a paused project, a
   * refused request. This is deliberately separate from `profile === null`,
   * which means "there is no such row".
   *
   * Collapsing the two is what put an approved Yönetici on the "Onay
   * bekleniyor" screen: every guard reads a null profile as not-staff, so one
   * failed request read as a verdict on the account.
   */
  profilHatasi: boolean
  refreshProfile: () => Promise<void>
  signOut: () => Promise<void>
}

const AuthContext = createContext<AuthContextValue | null>(null)

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null)
  const [profile, setProfile] = useState<Profile | null>(null)
  const [loading, setLoading] = useState(true)
  const [profilHatasi, setProfilHatasi] = useState(false)

  /**
   * Monotonic id of the newest profile request. Any response that is not the
   * newest is discarded.
   *
   * Without this the LAST RESPONSE TO ARRIVE wins, whichever user it was for:
   * a slow fetch for the account that just signed out can land after the fetch
   * for the account that just signed in and overwrite it. The app then shows
   * another person's profile — including their role and their approval state.
   */
  const istekRef = useRef(0)
  /** Which user the profile in state belongs to, for identity-change checks. */
  const kullaniciRef = useRef<string | null>(null)

  const loadProfile = useCallback(async (userId: string) => {
    const istek = ++istekRef.current
    const { data, error } = await supabase
      .from('profiles')
      // Explicit columns, not '*': 018 takes SELECT off the salary columns, and
      // a star would ask for them and be refused outright.
      .select('id,ad_soyad,rol,durum,notif_prefs,created_at')
      .eq('id', userId)
      .maybeSingle()

    if (istek !== istekRef.current) return

    if (error) {
      // Keep whatever profile we already had. A request that did not complete
      // says nothing about the account, and an operator mid-shift must not be
      // thrown out of the app by one bad response. RLS is the real boundary,
      // so a briefly stale role client-side cannot leak anything.
      setProfilHatasi(true)
      return
    }
    setProfilHatasi(false)
    setProfile((data as Profile | null) ?? null)
  }, [])

  useEffect(() => {
    let cancelled = false

    void supabase.auth
      .getSession()
      .then(async ({ data }) => {
        if (cancelled) return
        setSession(data.session)
        if (data.session) {
          kullaniciRef.current = data.session.user.id
          await loadProfile(data.session.user.id)
        }
        if (!cancelled) setLoading(false)
      })
      .catch(() => {
        // Never leave the app on the boot spinner. Without this a rejected
        // getSession() is a permanent "Yükleniyor".
        if (cancelled) return
        setProfilHatasi(true)
        setLoading(false)
      })

    const { data: sub } = supabase.auth.onAuthStateChange((event, newSession) => {
      setSession(newSession)
      const yeniId = newSession?.user.id ?? null

      if (!yeniId) {
        // Bump the request id so a fetch still in flight for the user who just
        // signed out cannot repopulate the profile afterwards.
        istekRef.current++
        kullaniciRef.current = null
        setProfile(null)
        setProfilHatasi(false)
        return
      }

      // getSession() above owns the first load, and the `loading` flag with it.
      if (event === 'INITIAL_SESSION') {
        kullaniciRef.current = yeniId
        return
      }

      // Reload only when the identity actually changed, or when the user record
      // itself was updated. TOKEN_REFRESHED fires roughly hourly and again when
      // a phone wakes, and supabase-js re-emits SIGNED_IN on tab focus; each of
      // those was a fresh chance for one failed request to look like a
      // deactivated account.
      const kimlikDegisti = yeniId !== kullaniciRef.current
      kullaniciRef.current = yeniId
      if (!kimlikDegisti && event !== 'USER_UPDATED') return

      // setTimeout is not cosmetic: awaiting a supabase call inside
      // onAuthStateChange deadlocks against the auth lock in supabase-js.
      setTimeout(() => void loadProfile(yeniId), 0)
    })

    return () => {
      cancelled = true
      sub.subscription.unsubscribe()
    }
  }, [loadProfile])

  const refreshProfile = useCallback(async () => {
    if (session) await loadProfile(session.user.id)
  }, [session, loadProfile])

  const signOut = useCallback(async () => {
    await supabase.auth.signOut()
  }, [])

  return (
    <AuthContext.Provider
      value={{ session, profile, loading, profilHatasi, refreshProfile, signOut }}
    >
      {children}
    </AuthContext.Provider>
  )
}

export function useAuth(): AuthContextValue {
  const ctx = useContext(AuthContext)
  if (!ctx) throw new Error('useAuth, AuthProvider içinde kullanılmalı')
  return ctx
}
