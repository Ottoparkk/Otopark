import { useState, type FormEvent } from 'react'
import { Link } from 'react-router'
import { AuthLayout } from './AuthLayout'
import { Button, Input } from '../../components/ui/primitives'
import { supabase } from '../../lib/supabase'
import { rpcErrorText } from '../../lib/errors'

export default function SignUp() {
  const [ad, setAd] = useState('')
  const [email, setEmail] = useState('')
  const [sifre, setSifre] = useState('')
  const [sifre2, setSifre2] = useState('')
  const [hata, setHata] = useState<string | null>(null)
  const [tamam, setTamam] = useState(false)
  const [yukleniyor, setYukleniyor] = useState(false)

  async function kayitOl(e: FormEvent) {
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
    const { error } = await supabase.auth.signUp({
      email: email.trim(),
      password: sifre,
      // Read by the handle_new_user trigger to seed profiles.ad_soyad.
      options: { data: { ad_soyad: ad.trim() } },
    })
    setYukleniyor(false)

    if (error) {
      setHata(rpcErrorText(error, 'Kayıt oluşturulamadı.'))
      return
    }
    setTamam(true)
  }

  if (tamam) {
    return (
      <AuthLayout
        title="Kaydınız alındı"
        subtitle="Hesabınız bir Yönetici onayladıktan sonra kullanıma açılacak."
        footer={
          <Link to="/giris" className="text-body font-medium text-accent">
            Giriş ekranına dön
          </Link>
        }
      >
        <div className="rounded-card bg-success-soft p-4 text-body text-success">
          E-posta adresinize doğrulama bağlantısı gönderildiyse önce onu onaylayın.
          Ardından Yönetici hesabınıza rol atayana kadar uygulamada herhangi bir
          kayıt görünmez — bu beklenen davranıştır.
        </div>
      </AuthLayout>
    )
  }

  return (
    <AuthLayout
      title="Kayıt Ol"
      subtitle="Hesabınız Yönetici onayından sonra aktifleşir."
      footer={
        <p className="text-body text-soft">
          Zaten hesabınız var mı?{' '}
          <Link to="/giris" className="font-medium text-accent">
            Giriş yapın
          </Link>
        </p>
      }
    >
      <form onSubmit={kayitOl} className="space-y-4">
        <Input
          label="Ad Soyad"
          name="ad"
          autoComplete="name"
          value={ad}
          onChange={(e) => setAd(e.target.value)}
          required
          maxLength={80}
        />
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
          autoComplete="new-password"
          hint="En az 8 karakter"
          value={sifre}
          onChange={(e) => setSifre(e.target.value)}
          required
        />
        <Input
          label="Şifre (tekrar)"
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
          Kayıt Ol
        </Button>
      </form>
    </AuthLayout>
  )
}
