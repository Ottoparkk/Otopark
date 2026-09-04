import { AuthLayout } from './AuthLayout'
import { Button } from '../../components/ui/primitives'
import { useAuth } from '../../app/providers/AuthProvider'

/**
 * Where a signed-in but unapproved account lands.
 *
 * This screen exists because the gate is real: a PENDING profile has
 * `rol = NULL`, which RLS reads as zero rows on every table. Without this,
 * the operator would see a working app that is inexplicably empty.
 */
export default function PendingApproval() {
  const { signOut, refreshProfile, profile, profilHatasi } = useAuth()

  return (
    <AuthLayout
      title="Onay bekleniyor"
      subtitle={
        profile?.ad_soyad
          ? `Merhaba ${profile.ad_soyad}, hesabınız henüz etkinleştirilmedi.`
          : 'Hesabınız henüz etkinleştirilmedi.'
      }
    >
      <div className="rounded-card bg-warn-soft p-4 text-body text-warn">
        Bir Yönetici hesabınıza rol atadıktan sonra otomatik olarak
        giriş yapabileceksiniz. Onaylandığınızı düşünüyorsanız aşağıdaki
        düğmeyle durumunuzu yenileyin.
      </div>

      <div className="mt-6 space-y-3">
        <Button size="lg" block onClick={() => void refreshProfile()}>
          Durumu Yenile
        </Button>
        {/* Without this the button is silent on failure: the profile fetch
            fails, nothing on screen changes, and the operator taps forever
            believing they have not been approved yet. */}
        {profilHatasi && (
          <p className="text-center text-label text-danger">
            Durum alınamadı — bağlantınızı kontrol edip tekrar deneyin.
          </p>
        )}
        <Button variant="secondary" size="lg" block onClick={() => void signOut()}>
          Çıkış Yap
        </Button>
      </div>
    </AuthLayout>
  )
}
