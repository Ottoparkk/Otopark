import type { ReactNode } from 'react'
import { Navigate, useLocation } from 'react-router'
import { useAuth } from './providers/AuthProvider'
import { anaSayfa, isDisabled, isPending, isStaff, isYonetici } from '../lib/rbac'
import { Spinner } from '../components/ui/Spinner'
import type { Rol } from '../lib/types'

/**
 * Route guards. These mirror RLS for the sake of UX — a Personel should get a
 * redirect, not a screen full of empty lists and permission errors.
 *
 * ⚠ They are NOT the security boundary. Every Yönetici-only read is refused by
 * RLS and every Yönetici-only write by the RPC. If a guard were removed
 * tomorrow, nothing would leak; the screens would just look broken.
 */

function Bekle() {
  return (
    <div className="flex min-h-dvh items-center justify-center bg-bg">
      <Spinner label="Yükleniyor" />
    </div>
  )
}

export function RequireAuth({ children }: { children: ReactNode }) {
  const { session, loading } = useAuth()
  const location = useLocation()

  // Waiting on `loading` is what stops a cold PWA launch from flashing the
  // login screen at an already-signed-in operator.
  if (loading) return <Bekle />
  if (!session) return <Navigate to="/giris" replace state={{ from: location.pathname }} />
  return <>{children}</>
}

/** Signed in, approved, and not disabled. */
export function RequireActive({ children }: { children: ReactNode }) {
  const { profile, loading } = useAuth()

  if (loading) return <Bekle />
  if (isDisabled(profile)) return <Navigate to="/hesap-kapali" replace />
  if (isPending(profile)) return <Navigate to="/onay-bekliyor" replace />
  if (!isStaff(profile)) return <Navigate to="/onay-bekliyor" replace />
  return <>{children}</>
}

export function RequireRole({ roles, children }: { roles: Rol[]; children: ReactNode }) {
  const { profile, loading } = useAuth()

  if (loading) return <Bekle />
  if (!profile?.rol || !roles.includes(profile.rol)) {
    return <Navigate to={anaSayfa(profile)} replace />
  }
  return <>{children}</>
}

/** "/" sends Yönetici to the panel and Personel to the gate. */
export function HomeRedirect() {
  const { session, profile, loading } = useAuth()

  if (loading) return <Bekle />
  if (!session) return <Navigate to="/giris" replace />
  if (isPending(profile)) return <Navigate to="/onay-bekliyor" replace />
  if (isDisabled(profile)) return <Navigate to="/hesap-kapali" replace />
  return <Navigate to={anaSayfa(profile)} replace />
}

/** Already signed in? An auth page should not be reachable. */
export function RedirectIfAuthed({ children }: { children: ReactNode }) {
  const { session, profile, loading } = useAuth()
  if (loading) return <Bekle />
  if (session && isStaff(profile)) return <Navigate to={anaSayfa(profile)} replace />
  return <>{children}</>
}

export { isYonetici }
