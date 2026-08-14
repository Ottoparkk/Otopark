import { useState, type FormEvent } from 'react'
import { Link } from 'react-router'
import { AuthLayout } from './AuthLayout'
import { Button, Input } from '../../components/ui/primitives'
import { supabase } from '../../lib/supabase'
import { rpcErrorText } from '../../lib/errors'

export default function SignIn() {
  const [email, setEmail] = useState('')
  const [sifre, setSifre] = useState('')
  const [hata, setHata] = useState<string | null>(null)
  const [bilgi, setBilgi] = useState<string | null>(null)
  const [yukleniyor, setYukleniyor] = useState(false)
  // Guards the reset link against a second tap: requesting twice invalidates
  // the first e-mail, so an impatient double-tap sends the user a dead link.
  const [sifirlamaGonderildi, setSifirlamaGonderildi] = useState(false)

  async function girisYap(e: FormEvent) {
    e.preventDefault()
    setHata(null)
    setBilgi(null)
    setYukleniyor(true)
    const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password: sifre })
    setYukleniyor(false)
    if (error) {
      setHata(
        /invalid login/i.test(error.message)
          ? 'E-posta veya şifre hatalı.'
          : rpcErrorText(error, 'Giriş yapılamadı.'),
      )
    }
    // On success AuthProvider swaps the route out from under us.
  }

  async function sifremiUnuttum() {
    if (!email.trim()) {
      setHata('Önce e-posta adresinizi yazın.')
      return
    }
    if (sifirlamaGonderildi) return
    setHata(null)
    setSifirlamaGonderildi(true)
    const { error } = await supabase.auth.resetPasswordForEmail(email.trim(), {
      redirectTo: `${window.location.origin}/Otopark/sifre-sifirla`,
    })
    if (error) {
      setSifirlamaGonderildi(false)
      setHata(rpcErrorText(error, 'Sıfırlama bağlantısı gönderilemedi.'))
    } else {
      setBilgi('Sıfırlama bağlantısı e-postanıza gönderildi.')
    }
  }

  return (
    <AuthLayout
      title="Giriş Yap"
      subtitle="Otopark yönetim sistemine hoş geldiniz."
      footer={
        <p className="text-body text-soft">
          Hesabınız yok mu?{' '}
          <Link to="/kayit" className="font-medium text-accent">
            Kayıt olun
          </Link>
        </p>
      }
    >
      <form onSubmit={girisYap} className="space-y-4">
        <Input
          label="E-posta"
          name="email"
          type="email"
          inputMode="email"
          autoComplete="email"
          autoCapitalize="off"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          required
        />
        <Input
          label="Şifre"
          name="password"
          type="password"
          autoComplete="current-password"
          value={sifre}
          onChange={(e) => setSifre(e.target.value)}
          required
        />

        {hata && (
          <p role="alert" className="rounded-field bg-danger-soft px-3 py-2.5 text-body text-danger">
            {hata}
          </p>
        )}
        {bilgi && (
          <p className="rounded-field bg-success-soft px-3 py-2.5 text-body text-success">
            {bilgi}
          </p>
        )}

        <Button type="submit" size="lg" block loading={yukleniyor}>
          Giriş Yap
        </Button>

        <button
          type="button"
          onClick={() => void sifremiUnuttum()}
          disabled={sifirlamaGonderildi}
          className="min-h-[44px] w-full text-body text-soft disabled:opacity-45"
        >
          {sifirlamaGonderildi ? 'Bağlantı gönderildi' : 'Şifremi unuttum'}
        </button>
      </form>
    </AuthLayout>
  )
}
