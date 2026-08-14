import { useEffect, useRef, useState } from 'react'
import { ScreenHeader, Button, FloatingBar } from '../../components/ui/primitives'
import { PlakaInput } from '../../components/ui/PlakaInput'
import { PlakaKamera } from '../plaka/PlakaKamera'
import { usePlakaKabul } from '../plaka/api'
import { AracTipiSecici, DolulukRozeti, FotoOnizleme } from './components'
import { fotoYukle, useAbonmanKontrol, useAyarlar, useBiletAc, useGunlukOzet, usePuanDurumu } from './api'
import { formatPlaka, normalizePlaka, plakaGecerli } from '../../lib/plaka'
import { formatTarih } from '../../lib/dates'
import { formatTL } from '../../lib/money'
import { rpcErrorText } from '../../lib/errors'
import { IconTik, IconUyari } from '../../components/ui/icons'
import type { AracTipi } from '../../lib/types'

export default function Giris() {
  const [plaka, setPlaka] = useState('')
  const [aracTipi, setAracTipi] = useState<AracTipi>('OTOMOBIL')
  const [foto, setFoto] = useState<File | null>(null)
  const [fotoUrl, setFotoUrl] = useState<string | null>(null)
  const [ocrLogId, setOcrLogId] = useState<string | null>(null)

  const [hata, setHata] = useState<string | null>(null)
  const [uyari, setUyari] = useState<string | null>(null)
  const [basari, setBasari] = useState<string | null>(null)

  /**
   * ONE idempotency key per form session, deliberately not per attempt.
   *
   * It survives retry-on-blip AND a double-tap: the server returns the
   * original ticket instead of opening a second one. Regenerating it on each
   * attempt would silently defeat the whole guard.
   */
  const islemIdRef = useRef<string>(crypto.randomUUID())

  const { data: ayarlar } = useAyarlar()
  const { data: ozet } = useGunlukOzet()
  const biletAc = useBiletAc()
  const plakaKabul = usePlakaKabul()

  const normalize = normalizePlaka(plaka)
  const gecerli = plakaGecerli(normalize)

  const { data: abonman } = useAbonmanKontrol(normalize, gecerli)
  const { data: puan } = usePuanDurumu(normalize, gecerli && Boolean(ayarlar?.puan_aktif))

  // Object URLs leak if they are not revoked; a gate phone stays open all day.
  useEffect(() => {
    if (!foto) {
      setFotoUrl(null)
      return
    }
    const url = URL.createObjectURL(foto)
    setFotoUrl(url)
    return () => URL.revokeObjectURL(url)
  }, [foto])

  useEffect(() => {
    if (!basari) return
    const t = setTimeout(() => setBasari(null), 5000)
    return () => clearTimeout(t)
  }, [basari])

  function sifirla() {
    setPlaka('')
    setFoto(null)
    setOcrLogId(null)
    setAracTipi('OTOMOBIL')
    islemIdRef.current = crypto.randomUUID()
  }

  async function kaydet() {
    setHata(null)
    setUyari(null)

    if (!gecerli) {
      setHata('Geçerli bir plaka girin.')
      return
    }

    // The photo is evidence, not a precondition. A failed upload is REPORTED
    // and the ticket still opens — at a barrier the record of the car matters
    // more than the picture of it.
    let fotoPath: string | null = null
    if (foto) {
      const sonuc = await fotoYukle(foto, 'giris', normalize)
      fotoPath = sonuc.path
      if (sonuc.hata) setUyari(sonuc.hata)
    }

    try {
      const id = await biletAc.mutateAsync({
        plaka: normalize,
        arac_tipi: aracTipi,
        islem_id: islemIdRef.current,
        foto: fotoPath,
      })
      if (!id) {
        setHata('Kayıt oluşturulamadı. Tekrar deneyin.')
        return
      }
      // Fire-and-forget: the accuracy log must never block a ticket.
      if (ocrLogId) plakaKabul.mutate({ log_id: ocrLogId, kabul: normalize })
      setBasari(formatPlaka(normalize))
      sifirla()
    } catch (err) {
      setHata(
        rpcErrorText(
          err,
          'Giriş kaydedilemedi. Bağlantınızı kontrol edip tekrar deneyin; sorun sürerse plakayı kâğıda not edin.',
        ),
      )
    }
  }

  return (
    <div className="flex min-h-dvh flex-col md:min-h-0">
      <ScreenHeader
        title="Araç Girişi"
        right={ozet ? <DolulukRozeti dolu={ozet.doluluk} kapasite={ozet.kapasite} /> : null}
      />

      <div className="flex-1 space-y-5 px-5">
        {basari && (
          <p className="flex items-center gap-2 rounded-card bg-success-soft px-4 py-3 text-body font-medium text-success">
            <IconTik size={18} />
            {basari} girişi kaydedildi
          </p>
        )}

        {/* No label: a giant tracked uppercase field with a plate-shaped
            placeholder already says what it is. */}
        <PlakaInput
          value={plaka}
          onChange={setPlaka}
          hideLabel
          autoFocus
          onEnter={() => void kaydet()}
        />

        {/* Knowing this BEFORE the ticket opens is the point — the operator
            should not wave a subscriber through wondering if it was free. */}
        {abonman?.gecerli && (
          <p className="rounded-card bg-success-soft px-4 py-3 text-body text-success">
            <strong className="font-semibold">Abonman geçerli</strong>
            {abonman.musteri_ad ? ` · ${abonman.musteri_ad}` : ''}
            {abonman.bitis_tarihi ? ` · ${formatTarih(abonman.bitis_tarihi)} tarihine kadar` : ''}
            <span className="mt-0.5 block text-label opacity-80">Bu araç ücretsiz girer.</span>
          </p>
        )}

        {puan?.hesap_var && !abonman?.gecerli && (
          <p className="rounded-card bg-accent-soft px-4 py-3 text-body text-accent">
            <strong className="font-semibold">{puan.hesap_adi}</strong> · {puan.bakiye} puan
            {puan.karsiligi_kurus > 0 && ` (${formatTL(puan.karsiligi_kurus)})`}
          </p>
        )}

        <AracTipiSecici value={aracTipi} onChange={setAracTipi} label={null} />

        <PlakaKamera
          aktif={(ayarlar?.plaka_saglayici ?? 'KAPALI') !== 'KAPALI'}
          onFoto={setFoto}
          onPlaka={(p, logId) => {
            setPlaka(p)
            setOcrLogId(logId)
          }}
        />

        {fotoUrl && <FotoOnizleme url={fotoUrl} onKaldir={() => setFoto(null)} />}

        {uyari && (
          <p className="flex items-start gap-2 rounded-card bg-warn-soft px-4 py-3 text-body text-warn">
            <IconUyari size={18} className="mt-0.5 shrink-0" />
            {uyari}
          </p>
        )}

        {hata && (
          <p
            role="alert"
            className="rounded-card bg-danger-soft px-4 py-3 text-body text-danger"
          >
            {hata}
          </p>
        )}
      </div>

      <FloatingBar>
        <Button
          size="lg"
          block
          loading={biletAc.isPending}
          disabled={!gecerli}
          onClick={() => void kaydet()}
        >
          {biletAc.isPending ? 'Kaydediliyor…' : 'Girişi Kaydet'}
        </Button>
      </FloatingBar>
    </div>
  )
}
