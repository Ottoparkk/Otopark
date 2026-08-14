import {
  createContext,
  useCallback,
  useContext,
  useEffect,
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
  refreshProfile: () => Promise<void>
  signOut: () => Promise<void>
}

const AuthContext = createContext<AuthContextValue | null>(null)

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null)
  const [profile, setProfile] = useState<Profile | null>(null)
  const [loading, setLoading] = useState(true)

  const loadProfile = useCallback(async (userId: string) => {
    const { data, error } = await supabase
      .from('profiles')
      .select('*')
      .eq('id', userId)
      .maybeSingle()
    setProfile(error || !data ? null : (data as Profile))
  }, [])

  useEffect(() => {
    let cancelled = false

    void supabase.auth.getSession().then(async ({ data }) => {
      if (cancelled) return
      setSession(data.session)
      if (data.session) await loadProfile(data.session.user.id)
      if (!cancelled) setLoading(false)
    })

    const { data: sub } = supabase.auth.onAuthStateChange((_event, newSession) => {
      setSession(newSession)
      if (newSession) {
        // setTimeout is not cosmetic: awaiting a supabase call inside
        // onAuthStateChange deadlocks against the auth lock in supabase-js.
        setTimeout(() => void loadProfile(newSession.user.id), 0)
      } else {
        setProfile(null)
      }
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
    <AuthContext.Provider value={{ session, profile, loading, refreshProfile, signOut }}>
      {children}
    </AuthContext.Provider>
  )
}

export function useAuth(): AuthContextValue {
  const ctx = useContext(AuthContext)
  if (!ctx) throw new Error('useAuth, AuthProvider içinde kullanılmalı')
  return ctx
}
