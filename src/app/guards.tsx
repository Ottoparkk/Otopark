import type { ReactNode } from 'react'
import { Navigate, useLocation } from 'react-router'
import { useAuth } from './providers/AuthProvider'
import { ANA_SAYFA, isDisabled, isPending, isStaff, isYonetici } from '../lib/rbac'
import { Spinner } from '../components/ui/Spinner'
import { Button } from '../components/ui/primitives'
import { AuthLayout } from '../features/auth/AuthLayout'
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

/**
 * The profile could not be loaded and there is nothing cached to fall back on.
 *
 * RENDERED IN PLACE, never navigated to, and that is the whole point: a
 * redirect would survive the recovery. This screen disappears by itself the
 * moment the profile arrives.
 */
function ProfilHatasi() {
  const { refreshProfile, signOut } = useAuth()

  return (
    <AuthLayout
      title="Bağlantı sorunu"
      subtitle="Hesap bilgileriniz alınamadı. Bu bir yetki sorunu değil."
    >
      <div className="rounded-card bg-warn-soft p-4 text-body text-warn">
        İnternet bağlantınızı kontrol edip tekrar deneyin. Sorun sürerse
        çıkış yapıp yeniden giriş yapın.
      </div>

      <div className="mt-6 space-y-3">
        <Button size="lg" block onClick={() => void refreshProfile()}>
          Tekrar Dene
        </Button>
        <Button variant="secondary" size="lg" block onClick={() => void signOut()}>
          Çıkış Yap
        </Button>
      </div>
    </AuthLayout>
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
  const { profile, loading, profilHatasi } = useAuth()

  if (loading) return <Bekle />
  // Before any verdict: a failed fetch is not an answer about the account.
  // This used to fall through to the pending screen, which told an approved
  // Yönetici their account was awaiting activation.
  if (profilHatasi && !profile) return <ProfilHatasi />
  if (isDisabled(profile)) return <Navigate to="/hesap-kapali" replace />
  if (isPending(profile)) return <Navigate to="/onay-bekliyor" replace />
  if (!isStaff(profile)) return <Navigate to="/onay-bekliyor" replace />
  return <>{children}</>
}

export function RequireRole({ roles, children }: { roles: Rol[]; children: ReactNode }) {
  const { profile, loading } = useAuth()

  if (loading) return <Bekle />
  if (!profile?.rol || !roles.includes(profile.rol)) {
    return <Navigate to={ANA_SAYFA} replace />
  }
  return <>{children}</>
}

/**
 * The gate screens must let go.
 *
 * `/onay-bekliyor` and `/hesap-kapali` are only ever reached by a redirect, and
 * nothing sent an account back once its profile turned out to be fine — so a
 * Yönetici bounced there by one failed request STAYED there, and "Durumu
 * Yenile" looked broken because refreshing the profile changed no route.
 */
export function RedirectIfActive({ children }: { children: ReactNode }) {
  const { profile, loading } = useAuth()

  if (loading) return <Bekle />
  if (isStaff(profile)) return <Navigate to={ANA_SAYFA} replace />
  return <>{children}</>
}

/** "/" sends everyone to the gate — see ANA_SAYFA. */
export function HomeRedirect() {
  const { session, profile, loading, profilHatasi } = useAuth()

  if (loading) return <Bekle />
  if (!session) return <Navigate to="/giris" replace />
  if (profilHatasi && !profile) return <ProfilHatasi />
  if (isPending(profile)) return <Navigate to="/onay-bekliyor" replace />
  if (isDisabled(profile)) return <Navigate to="/hesap-kapali" replace />
  return <Navigate to={ANA_SAYFA} replace />
}

/** Already signed in? An auth page should not be reachable. */
export function RedirectIfAuthed({ children }: { children: ReactNode }) {
  const { session, profile, loading } = useAuth()
  if (loading) return <Bekle />
  if (session && isStaff(profile)) return <Navigate to={ANA_SAYFA} replace />
  return <>{children}</>
}

export { isYonetici }
