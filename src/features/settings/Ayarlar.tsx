import { useEffect, useState } from 'react'
import { Button, Card, Input, ScreenHeader } from '../../components/ui/primitives'
import { Toggle } from '../../components/ui/Toggle'
import { Link } from 'react-router'
import { useOkunmamisSayisi, useProfilGuncelle } from './api'
import { useAuth } from '../../app/providers/AuthProvider'
import { isDarkMode, setDarkMode } from '../../lib/theme'
import { disablePush, enablePush, getPushSubscription, pushSupported } from '../../lib/push'
import { isYonetici } from '../../lib/rbac'
import { rpcErrorText } from '../../lib/errors'
import { BILDIRIM_ETIKET, type BildirimTur } from '../../lib/types'
import { IconAy, IconGunes, IconIleri, IconZil } from '../../components/ui/icons'

/** Every type is Yönetici-only today, so Personel see no preference switches. */
const TERCIH_TURLERI: BildirimTur[] = [
  'YENI_UYELIK',
  'VARDIYA_FARK',
  'VARDIYA_KAPATMA',
  'VARDIYA_ACIK',
  'ONAY_BEKLIYOR',
  'UCRET_DEGISIKLIGI',
  'BILET_IPTAL',
  'ABONMAN_BITIYOR',
  'TERK_EDILMIS',
  'DOLULUK',
  'ISTISNA',
  'KAMERA',
  'KAMERA_HAREKET',
  'PUAN_KULLANIM',
]

export default function Ayarlar() {
  const { profile, refreshProfile, signOut } = useAuth()
  const guncelle = useProfilGuncelle()
  const yonetici = isYonetici(profile)
  const { data: okunmamis = 0 } = useOkunmamisSayisi(yonetici)

  const [ad, setAd] = useState(profile?.ad_soyad ?? '')
  const [karanlik, setKaranlik] = useState(isDarkMode())
  const [pushAcik, setPushAcik] = useState(false)
  const [pushMesaj, setPushMesaj] = useState<string | null>(null)
  const [hata, setHata] = useState<string | null>(null)
  const [kaydedildi, setKaydedildi] = useState(false)

  useEffect(() => {
    setAd(profile?.ad_soyad ?? '')
  }, [profile?.ad_soyad])

  useEffect(() => {
    void getPushSubscription().then((s) => setPushAcik(Boolean(s)))
  }, [])

  const prefs = (profile?.notif_prefs ?? {}) as Record<string, boolean>

  async function adKaydet() {
    setHata(null)
    try {
      await guncelle.mutateAsync({ ad_soyad: ad.trim() })
      await refreshProfile()
      setKaydedildi(true)
      setTimeout(() => setKaydedildi(false), 2500)
    } catch (err) {
      setHata(rpcErrorText(err, 'Kaydedilemedi.'))
    }
  }

  async function tercihDegistir(tur: BildirimTur, acik: boolean) {
    setHata(null)
    try {
      await guncelle.mutateAsync({ notif_prefs: { ...prefs, [tur]: acik } })
      await refreshProfile()
    } catch (err) {
      setHata(rpcErrorText(err, 'Tercih kaydedilemedi.'))
    }
  }

  async function pushDegistir(acik: boolean) {
    setPushMesaj(null)
    if (!acik) {
      await disablePush()
      setPushAcik(false)
      return
    }
    const sonuc = await enablePush()
    if (sonuc === 'ok') {
      setPushAcik(true)
    } else if (sonuc === 'denied') {
      setPushMesaj('Bildirim izni reddedildi. Tarayıcı ayarlarından açabilirsiniz.')
    } else {
      setPushMesaj(
        'Bu cihaz anlık bildirimi desteklemiyor. iOS için 16.4+ ve uygulamanın ana ekrana eklenmiş olması gerekir.',
      )
    }
  }

  return (
    <div>
      {/* "Profil", not "Ayarlar": the car park's own settings are a
          different screen (/yonetim/ayarlar), and two things called Ayarlar
          is how someone ends up changing capacity when they meant to change
          their name. Back goes where the screen was entered from — a
          Yönetici arrives from the Yönetim menu, a Personel from Gişe. */}
      <ScreenHeader title="Profil" back={yonetici ? '/yonetim' : '/gise'} />

      <div className="space-y-4 px-5">
        {/* ---- profile ------------------------------------------------ */}
        <Card>
          <p className="mb-3 text-label font-medium tracking-wide text-faint uppercase">Profil</p>
          <Input label="Ad Soyad" value={ad} onChange={(e) => setAd(e.target.value)} maxLength={80} />
          <div className="mt-3 flex items-center gap-3">
            <Button
              variant="secondary"
              onClick={() => void adKaydet()}
              loading={guncelle.isPending}
              disabled={ad.trim() === (profile?.ad_soyad ?? '')}
            >
              Kaydet
            </Button>
            {kaydedildi && <span className="text-label text-success">Kaydedildi</span>}
          </div>
          <p className="mt-3 text-label text-faint">
            Rolünüz: {profile?.rol === 'YONETICI' ? 'Yönetici' : 'Personel'}
          </p>
        </Card>

        {/* ---- appearance --------------------------------------------- */}
        <Card>
          <p className="mb-1 text-label font-medium tracking-wide text-faint uppercase">Görünüm</p>
          <Toggle
            checked={karanlik}
            onChange={(v) => {
              setDarkMode(v)
              setKaranlik(v)
            }}
            label="Koyu mod"
            hint="Gece vardiyasında gözü yormaz."
          />
          <p className="mt-1 flex items-center gap-1.5 text-label text-faint">
            {karanlik ? <IconAy size={14} /> : <IconGunes size={14} />}
            {karanlik ? 'Koyu tema açık' : 'Açık tema'}
          </p>
        </Card>

        {/* ---- push ---------------------------------------------------- */}
        {yonetici && (
          <Card>
            <p className="mb-1 text-label font-medium tracking-wide text-faint uppercase">
              Bildirimler
            </p>
            <Toggle
              checked={pushAcik}
              onChange={(v) => void pushDegistir(v)}
              label="Anlık bildirim"
              hint="Vardiya farkı ve ücret değişikliği telefona düşer."
              disabled={!pushSupported()}
            />
            {pushMesaj && <p className="mt-1 text-label text-warn">{pushMesaj}</p>}

            <div className="mt-3 space-y-0.5 border-t border-divider pt-2">
              {TERCIH_TURLERI.map((t) => (
                <Toggle
                  key={t}
                  checked={prefs[t] !== false}
                  onChange={(v) => void tercihDegistir(t, v)}
                  label={BILDIRIM_ETIKET[t]}
                />
              ))}
            </div>

            {/* The feed itself, one tap from the switches that decide what
                lands in it. It keeps its own screen — the bell in the desktop
                bar still goes straight there — but it no longer needs a menu
                row of its own. */}
            <Link
              to="/bildirimler"
              className="mt-3 flex min-h-[44px] items-center gap-3 rounded-field bg-field px-3.5"
            >
              <IconZil size={18} className="shrink-0 text-soft" />
              <span className="flex-1 text-body font-medium text-ink">Gelen bildirimler</span>
              {okunmamis > 0 && (
                <span className="rounded-chip bg-accent px-2 py-0.5 text-micro font-semibold text-accent-ink tnum">
                  {okunmamis}
                </span>
              )}
              <IconIleri size={16} className="shrink-0 text-faint" />
            </Link>
          </Card>
        )}

        {hata && (
          <p role="alert" className="rounded-card bg-danger-soft px-4 py-3 text-body text-danger">
            {hata}
          </p>
        )}

        <div className="safe-bottom pt-2">
          <Button variant="secondary" size="lg" block onClick={() => void signOut()}>
            Çıkış Yap
          </Button>
        </div>
      </div>
    </div>
  )
}
