import { AuthLayout } from './AuthLayout'
import { Button } from '../../components/ui/primitives'
import { useAuth } from '../../app/providers/AuthProvider'

/** A DISABLED account keeps its session but loses every row at the next request. */
export default function AccountDisabled() {
  const { signOut } = useAuth()

  return (
    <AuthLayout title="Hesap kapalı" subtitle="Bu hesap devre dışı bırakılmış.">
      <div className="rounded-card bg-danger-soft p-4 text-body text-danger">
        Erişiminiz bir Yönetici tarafından kapatılmış. Yeniden açılması için
        otopark yöneticisiyle görüşün.
      </div>

      <div className="mt-6">
        <Button variant="secondary" size="lg" block onClick={() => void signOut()}>
          Çıkış Yap
        </Button>
      </div>
    </AuthLayout>
  )
}
