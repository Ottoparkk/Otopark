import { useState } from 'react'
import { Card, Input, LoadError, ScreenHeader } from '../../components/ui/primitives'
import { FormModal } from '../../components/ui/FormModal'
import { Spinner } from '../../components/ui/Spinner'
import { useAktifTarifeler } from '../gise/api'
import { useTarifeGuncelle } from './api'
import { formatTL, kurusToInput, parseTLToKurus, digitsOnly } from '../../lib/money'
import { rpcErrorText } from '../../lib/errors'
import { ARAC_TIPI_ETIKET, type Tarife } from '../../lib/types'

export default function Tarifeler() {
  const { data: tarifeler = [], isPending, error, refetch } = useAktifTarifeler()
  const guncelle = useTarifeGuncelle()

  const [duzenlenen, setDuzenlenen] = useState<Tarife | null>(null)
  const [ucretsiz, setUcretsiz] = useState('')
  const [ilk, setIlk] = useState('')
  const [sonraki, setSonraki] = useState('')
  const [tavan, setTavan] = useState('')
  const [kayip, setKayip] = useState('')
  const [hata, setHata] = useState<string | null>(null)

  function ac(t: Tarife) {
    setDuzenlenen(t)
    setUcretsiz(String(t.ucretsiz_dakika))
    setIlk(kurusToInput(t.ilk_saat_kurus))
    setSonraki(kurusToInput(t.sonraki_saat_kurus))
    setTavan(kurusToInput(t.gunluk_tavan_kurus))
    setKayip(kurusToInput(t.kayip_bilet_kurus))
    setHata(null)
  }

  return (
    <div>
      <ScreenHeader title="Tarifeler" back="/yonetim" subtitle="Değişiklik yeni sürüm oluşturur" />

      <div className="space-y-3 px-5">
        <p className="rounded-card bg-accent-soft px-4 py-3 text-label text-accent">
          Fiyat değiştirdiğinizde eski tarife kapatılır ve yenisi açılır.
          <strong className="font-semibold"> İçeride bekleyen araçlar girdikleri fiyatı korur.</strong>
        </p>

        {error ? (
          <LoadError error={error} onRetry={() => void refetch()} />
        ) : isPending ? (
          <div className="py-14">
            <Spinner label="Yükleniyor" />
          </div>
        ) : (
          tarifeler.map((t) => (
            <Card key={t.id}>
              <button type="button" onClick={() => ac(t)} className="w-full text-left">
                <div className="flex items-baseline justify-between gap-3">
                  <span className="text-lead font-medium text-ink">
                    {ARAC_TIPI_ETIKET[t.arac_tipi]}
                  </span>
                  <span className="text-lead font-semibold text-ink tnum">
                    {formatTL(t.ilk_saat_kurus)}
                  </span>
                </div>
                <dl className="mt-3 space-y-1.5">
                  <Satir k="İlk saat" v={formatTL(t.ilk_saat_kurus)} />
                  <Satir k="Sonraki her saat" v={formatTL(t.sonraki_saat_kurus)} />
                  <Satir
                    k="Günlük tavan"
                    v={t.gunluk_tavan_kurus > 0 ? formatTL(t.gunluk_tavan_kurus) : 'yok'}
                  />
                  <Satir k="Ücretsiz süre" v={`${t.ucretsiz_dakika} dk`} />
                  <Satir
                    k="Kayıp bilet"
                    v={t.kayip_bilet_kurus > 0 ? formatTL(t.kayip_bilet_kurus) : 'tanımsız'}
                  />
                </dl>
              </button>
            </Card>
          ))
        )}
      </div>

      <FormModal
        open={duzenlenen !== null}
        onOpenChange={() => setDuzenlenen(null)}
        title={duzenlenen ? `${ARAC_TIPI_ETIKET[duzenlenen.arac_tipi]} tarifesi` : ''}
        submitLabel="Yeni sürümü kaydet"
        loading={guncelle.isPending}
        error={hata}
        onSubmit={() => {
          if (!duzenlenen) return
          const ilkK = parseTLToKurus(ilk)
          const sonK = parseTLToKurus(sonraki)
          const tavK = parseTLToKurus(tavan || '0')
          const kayK = parseTLToKurus(kayip || '0')
          const ucD = Number(ucretsiz)

          if (ilkK === null || sonK === null || tavK === null || kayK === null) {
            setHata('Tutarları geçerli girin (örn. 60 ya da 60,50).')
            return
          }
          if (!Number.isFinite(ucD) || ucD < 0 || ucD > 1440) {
            setHata('Ücretsiz süre 0-1440 dakika arasında olmalı.')
            return
          }
          if (tavK > 0 && tavK < ilkK) {
            setHata('Günlük tavan ilk saat ücretinden düşük olamaz.')
            return
          }

          void guncelle
            .mutateAsync({
              arac_tipi: duzenlenen.arac_tipi,
              ucretsiz_dakika: ucD,
              ilk_saat_kurus: ilkK,
              sonraki_saat_kurus: sonK,
              gunluk_tavan_kurus: tavK,
              kayip_bilet_kurus: kayK,
            })
            .then(() => setDuzenlenen(null))
            .catch((e) => setHata(rpcErrorText(e, 'Tarife güncellenemedi.')))
        }}
      >
        <Input
          label="Ücretsiz süre (dakika)"
          value={ucretsiz}
          onChange={(e) => setUcretsiz(digitsOnly(e.target.value, 4))}
          inputMode="numeric"
          hint="Bu süreyi aşan araç ilk saat ücretini öder."
        />
        <Input
          label="İlk saat (₺)"
          value={ilk}
          onChange={(e) => setIlk(e.target.value)}
          inputMode="decimal"
        />
        <Input
          label="Sonraki her saat (₺)"
          value={sonraki}
          onChange={(e) => setSonraki(e.target.value)}
          inputMode="decimal"
        />
        <Input
          label="Günlük tavan (₺)"
          value={tavan}
          onChange={(e) => setTavan(e.target.value)}
          inputMode="decimal"
          hint="0 = tavan yok"
        />
        <Input
          label="Kayıp bilet ücreti (₺)"
          value={kayip}
          onChange={(e) => setKayip(e.target.value)}
          inputMode="decimal"
          hint="Girişi kaydedilmemiş araçtan alınır. 0 = kapalı"
        />
      </FormModal>
    </div>
  )
}

function Satir({ k, v }: { k: string; v: string }) {
  return (
    <div className="flex items-baseline justify-between gap-3">
      <dt className="text-body text-faint">{k}</dt>
      <dd className="text-body text-soft tnum">{v}</dd>
    </div>
  )
}
