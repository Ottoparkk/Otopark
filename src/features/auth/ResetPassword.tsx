import { useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router'
import { AuthLayout } from './AuthLayout'
import { Button, Input } from '../../components/ui/primitives'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { supabase } from '../../lib/supabase'
import { rpcErrorText } from '../../lib/errors'

/**
 * Reached from the e-mailed recovery link, which Supabase turns into a
 * session before this screen renders. Two fields with a match check — a typo
 * in a password you cannot see locks you out of your own account.
 */
export default function ResetPassword() {
  const navigate = useNavigate()
  const [sifre, setSifre] = useState('')
  const [sifre2, setSifre2] = useState('')
  const [hata, setHata] = useState<string | null>(null)
  const [yukleniyor, setYukleniyor] = useState(false)
  const [tamamAcik, setTamamAcik] = useState(false)

  async function kaydet(e: FormEvent) {
    e.preventDefault()
    setHata(null)

    if (sifre !== sifre2) {
      setHata('Şifreler eşleşmiyor.')
      return
    }
    if (sifre.length < 8) {
      setHata('Şifre en az 8 karakter olmalı.')
      return
    }

    setYukleniyor(true)
    const { error } = await supabase.auth.updateUser({ password: sifre })
    setYukleniyor(false)

    if (error) {
      setHata(rpcErrorText(error, 'Şifre değiştirilemedi. Bağlantı süresi dolmuş olabilir.'))
      return
    }
    setTamamAcik(true)
  }

  async function bitir() {
    // Sign out so the new password is actually used on the next login,
    // rather than leaving the recovery session silently in place.
    await supabase.auth.signOut()
    navigate('/giris', { replace: true })
  }

  return (
    <AuthLayout title="Yeni Şifre" subtitle="Hesabınız için yeni bir şifre belirleyin.">
      <form onSubmit={kaydet} className="space-y-4">
        <Input
          label="Yeni şifre"
          name="password"
          type="password"
          autoComplete="new-password"
          hint="En az 8 karakter"
          value={sifre}
          onChange={(e) => setSifre(e.target.value)}
          required
        />
        <Input
          label="Şifreyi doğrula"
          name="password2"
          type="password"
          autoComplete="new-password"
          value={sifre2}
          onChange={(e) => setSifre2(e.target.value)}
          required
        />

        {hata && (
          <p role="alert" className="rounded-field bg-danger-soft px-3 py-2.5 text-body text-danger">
            {hata}
          </p>
        )}

        <Button type="submit" size="lg" block loading={yukleniyor}>
          Şifreyi Değiştir
        </Button>
      </form>

      <ConfirmDialog
        open={tamamAcik}
        onOpenChange={() => void bitir()}
        title="Şifreniz değiştirildi"
        description="Yeni şifrenizle giriş yapabilirsiniz."
        confirmLabel="Tamam"
        cancelLabel="Tamam"
        onConfirm={() => void bitir()}
      />
    </AuthLayout>
  )
}
