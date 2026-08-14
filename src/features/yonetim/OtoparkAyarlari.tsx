import { useEffect, useState } from 'react'
import { Button, Card, Input, LoadError, ScreenHeader } from '../../components/ui/primitives'
import { SegmentedControl } from '../../components/ui/primitives'
import { Toggle } from '../../components/ui/Toggle'
import { Spinner } from '../../components/ui/Spinner'
import { AracTipiSecici } from '../gise/components'
import { useAyarlar } from '../gise/api'
import { useAyarGuncelle, usePuanKurali, usePuanKuralGuncelle } from './api'
import { digitsOnly, formatTL, kurusToInput, parseTLToKurus } from '../../lib/money'
import { rpcErrorText } from '../../lib/errors'
import type { AracTipi, PlakaSaglayici } from '../../lib/types'

export default function OtoparkAyarlari() {
  const { data: ayar, isPending, error, refetch } = useAyarlar()
  const guncelle = useAyarGuncelle()
  const { data: kural } = usePuanKurali()
  const kuralGuncelle = usePuanKuralGuncelle()

  const [ad, setAd] = useState('')
  const [kapasite, setKapasite] = useState('')
  const [saklama, setSaklama] = useState('')
  const [terk, setTerk] = useState('')
  const [dolulukUyari, setDolulukUyari] = useState('')
  const [saglayici, setSaglayici] = useState<PlakaSaglayici>('KAPALI')
  const [model, setModel] = useState('')
  const [kameraAktif, setKameraAktif] = useState(false)
  const [kameraTip, setKameraTip] = useState<AracTipi>('OTOMOBIL')
  const [gecikme, setGecikme] = useState('')
  const [puanAktif, setPuanAktif] = useState(false)
  const [kazanim, setKazanim] = useState('')
  const [puanDeger, setPuanDeger] = useState('')
  const [bekleme, setBekleme] = useState('')
  const [hata, setHata] = useState<string | null>(null)
  const [kaydedildi, setKaydedildi] = useState(false)

  // Hydrate once the row arrives. The early return below guarantees the form
  // is never drawn before this runs.
  useEffect(() => {
    if (!ayar) return
    setAd(ayar.ad)
    setKapasite(String(ayar.kapasite))
    setSaklama(String(ayar.foto_saklama_gun))
    setTerk(String(ayar.terk_esik_saat))
    setDolulukUyari(String(ayar.doluluk_uyari_yuzde))
    setSaglayici(ayar.plaka_saglayici)
    setModel(ayar.plaka_model ?? '')
    setKameraAktif(ayar.kamera_aktif)
    setKameraTip(ayar.kamera_varsayilan_arac_tipi)
    setGecikme(String(ayar.kamera_gecikme_limiti_dk))
    setPuanAktif(ayar.puan_aktif)
  }, [ayar])

  useEffect(() => {
    if (!kural) return
    setKazanim(String(kural.kazanim_puan))
    setPuanDeger(kurusToInput(kural.kurus_per_puan))
    setBekleme(String(kural.bekleme_saat))
  }, [kural])

  /**
   * ⚠ Never render the form over a failed load.
   *
   * If the query errors and we draw the inputs at their empty defaults, the
   * first Save silently overwrites real settings with blanks — and the user,
   * seeing an empty form, reasonably concludes the data was deleted. Fail
   * loudly instead.
   */
  if (isPending) {
    return (
      <div className="py-20">
        <Spinner label="Ayarlar yükleniyor" />
      </div>
    )
  }
  if (error || !ayar) {
    return (
      <div className="px-5">
        <ScreenHeader title="Otopark Ayarları" back="/yonetim" />
        <LoadError error={error} onRetry={() => void refetch()} />
      </div>
    )
  }

  async function kaydet() {
    setHata(null)
    const kap = Number(kapasite)
    if (!Number.isFinite(kap) || kap < 1) {
      setHata('Kapasite en az 1 olmalı.')
      return
    }
    try {
      await guncelle.mutateAsync({
        ad: ad.trim() || 'Otopark',
        kapasite: kap,
        foto_saklama_gun: Number(saklama) || 0,
        terk_esik_saat: Number(terk) || 48,
        doluluk_uyari_yuzde: Number(dolulukUyari) || 90,
        plaka_saglayici: saglayici,
        plaka_model: model.trim() || null,
        kamera_aktif: kameraAktif,
        kamera_varsayilan_arac_tipi: kameraTip,
        kamera_gecikme_limiti_dk: Number(gecikme) || 720,
        puan_aktif: puanAktif,
      })
      setKaydedildi(true)
      setTimeout(() => setKaydedildi(false), 2500)
    } catch (err) {
      setHata(rpcErrorText(err, 'Ayarlar kaydedilemedi.'))
    }
  }

  async function puanKaydet() {
    setHata(null)
    const deger = parseTLToKurus(puanDeger || '0')
    if (deger === null) {
      setHata('Puan değerini geçerli girin.')
      return
    }
    try {
      await kuralGuncelle.mutateAsync({
        kazanim_puan: Number(kazanim) || 0,
        kurus_per_puan: deger,
        bekleme_saat: Number(bekleme) || 0,
        puan_gecerlilik_gun: kural?.puan_gecerlilik_gun ?? 0,
      })
      setKaydedildi(true)
      setTimeout(() => setKaydedildi(false), 2500)
    } catch (err) {
      setHata(rpcErrorText(err, 'Puan kuralı kaydedilemedi.'))
    }
  }

  return (
    <div>
      <ScreenHeader title="Otopark Ayarları" back="/yonetim" />

      <div className="space-y-4 px-5">
        <Card className="space-y-4">
          <p className="text-label font-medium tracking-wide text-faint uppercase">Otopark</p>
          <Input label="Ad" value={ad} onChange={(e) => setAd(e.target.value)} maxLength={80} />
          <Input
            label="Kapasite"
            value={kapasite}
            onChange={(e) => setKapasite(digitsOnly(e.target.value, 5))}
            inputMode="numeric"
          />
          <Input
            label="Doluluk uyarısı (%)"
            value={dolulukUyari}
            onChange={(e) => setDolulukUyari(digitsOnly(e.target.value, 3))}
            inputMode="numeric"
            hint="Bu orana ulaşınca bildirim gönderilir."
          />
          <Input
            label="Terk edilmiş sayılma süresi (saat)"
            value={terk}
            onChange={(e) => setTerk(digitsOnly(e.target.value, 3))}
            inputMode="numeric"
          />
        </Card>

        <Card className="space-y-4">
          <p className="text-label font-medium tracking-wide text-faint uppercase">
            Fotoğraf saklama (KVKK)
          </p>
          <Input
            label="Saklama süresi (gün)"
            value={saklama}
            onChange={(e) => setSaklama(digitsOnly(e.target.value, 4))}
            inputMode="numeric"
            hint="Plaka fotoğrafları bu süre sonunda gece işiyle silinir. 0 = silme kapalı."
          />
        </Card>

        <Card className="space-y-4">
          <p className="text-label font-medium tracking-wide text-faint uppercase">Plaka okuma</p>
          <SegmentedControl
            label="Sağlayıcı"
            value={saglayici}
            onChange={(v) => setSaglayici(v)}
            options={[
              { value: 'KAPALI', label: 'Kapalı' },
              { value: 'VLM', label: 'Claude' },
              { value: 'ALPR', label: 'ALPR' },
            ]}
          />
          {saglayici !== 'KAPALI' && (
            <Input
              label="Model"
              value={model}
              onChange={(e) => setModel(e.target.value)}
              placeholder="claude-haiku-4-5"
              hint="Tanınmayan bir değer varsayılana düşer; adres her zaman sabittir."
            />
          )}
          <p className="text-label text-faint">
            Okuma her zaman bir <strong className="text-soft">öneridir</strong> — operatör
            onaylamadan hiçbir kayıt oluşmaz.
          </p>
        </Card>

        <Card className="space-y-4">
          <p className="text-label font-medium tracking-wide text-faint uppercase">Kamera</p>
          <Toggle
            checked={kameraAktif}
            onChange={setKameraAktif}
            label="Kamera girişi açık"
            hint="Kapalıyken webhook hiçbir olayı kabul etmez."
          />
          {kameraAktif && (
            <>
              <AracTipiSecici
                label="Kameradan gelen araçların varsayılan tipi"
                value={kameraTip}
                onChange={setKameraTip}
              />
              <Input
                label="Gecikme sınırı (dakika)"
                value={gecikme}
                onChange={(e) => setGecikme(digitsOnly(e.target.value, 5))}
                inputMode="numeric"
                hint="Bundan eski kamera olayı bilete dönüşmez, istisna olarak işaretlenir."
              />
              <p className="rounded-field bg-warn-soft px-3 py-2.5 text-label text-warn">
                Kameranın saatini NTP'ye bağlayın. Bir saat kaymış kamera her aracı
                sessizce yanlış ücretlendirir.
              </p>
            </>
          )}
        </Card>

        <Card className="space-y-4">
          <p className="text-label font-medium tracking-wide text-faint uppercase">Puan</p>
          <Toggle
            checked={puanAktif}
            onChange={setPuanAktif}
            label="Puan sistemi açık"
            hint="Kapalıyken hiçbir puan kazanılmaz ve kullanılamaz."
          />
          {puanAktif && (
            <>
              <Input
                label="Giriş başına kazanım (puan)"
                value={kazanim}
                onChange={(e) => setKazanim(digitsOnly(e.target.value, 5))}
                inputMode="numeric"
              />
              <Input
                label="1 puanın değeri (₺)"
                value={puanDeger}
                onChange={(e) => setPuanDeger(e.target.value)}
                inputMode="decimal"
              />
              <Input
                label="Aynı plaka için bekleme (saat)"
                value={bekleme}
                onChange={(e) => setBekleme(digitsOnly(e.target.value, 3))}
                inputMode="numeric"
                hint="Girip çıkarak puan biriktirmeyi engeller."
              />
              {kazanim && puanDeger && (
                <p className="text-label text-faint">
                  Her giriş yaklaşık{' '}
                  <strong className="text-soft">
                    {formatTL((Number(kazanim) || 0) * (parseTLToKurus(puanDeger) ?? 0))}
                  </strong>{' '}
                  değerinde borç yaratır.
                </p>
              )}
              <Button variant="secondary" onClick={() => void puanKaydet()} loading={kuralGuncelle.isPending}>
                Puan kuralını kaydet
              </Button>
            </>
          )}
        </Card>

        {hata && (
          <p role="alert" className="rounded-card bg-danger-soft px-4 py-3 text-body text-danger">
            {hata}
          </p>
        )}

        <div className="safe-bottom flex items-center gap-3 pt-2">
          <Button size="lg" block onClick={() => void kaydet()} loading={guncelle.isPending}>
            Kaydet
          </Button>
        </div>
        {kaydedildi && <p className="pb-4 text-center text-label text-success">Kaydedildi</p>}
      </div>
    </div>
  )
}
