import { useState } from 'react'
import { useParams } from 'react-router'
import { Button, Card, LoadError, ScreenHeader } from '../../components/ui/primitives'
import { Spinner } from '../../components/ui/Spinner'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { Input } from '../../components/ui/primitives'
import { AracTipiSecici } from './components'
import { useAracTipiDuzelt, useBilet, useBiletIptal, useFotoUrl } from './api'
import { formatPlaka } from '../../lib/plaka'
import { formatGoreceli, formatTam } from '../../lib/dates'
import { sureMetni } from '../../lib/sure'
import { formatTL } from '../../lib/money'
import { rpcErrorText } from '../../lib/errors'
import { ARAC_TIPI_ETIKET, ODEME_CHIP, ODEME_ETIKET, type AracTipi } from '../../lib/types'

/** Full history of one ticket. Yönetici-facing; Personel go straight to Çıkış. */
export default function BiletDetay() {
  const { id } = useParams()
  const { data: bilet, isPending, error, refetch } = useBilet(id)
  const iptal = useBiletIptal()
  const tipDuzelt = useAracTipiDuzelt()

  const [iptalAcik, setIptalAcik] = useState(false)
  const [sebep, setSebep] = useState('')
  const [iptalHata, setIptalHata] = useState<string | null>(null)

  const { data: girisFoto } = useFotoUrl(bilet?.giris_foto)
  const { data: cikisFoto } = useFotoUrl(bilet?.cikis_foto)

  if (isPending) {
    return (
      <div className="py-20">
        <Spinner label="Bilet yükleniyor" />
      </div>
    )
  }
  if (error || !bilet) {
    return (
      <div className="px-5 pt-4">
        <ScreenHeader title="Bilet" back />
        <LoadError error={error} onRetry={() => void refetch()} />
      </div>
    )
  }

  const acik = bilet.durum === 'ACIK'

  return (
    <div>
      <ScreenHeader title={formatPlaka(bilet.plaka)} back subtitle={ARAC_TIPI_ETIKET[bilet.arac_tipi]} />

      <div className="space-y-4 px-5">
        <Card>
          <div className="flex items-baseline justify-between gap-3">
            <span className="text-title font-semibold text-ink tnum">
              {bilet.durum === 'IPTAL' ? '—' : formatTL(bilet.tahsil_kurus)}
            </span>
            <DurumRozeti durum={bilet.durum} />
          </div>

          <dl className="mt-4 space-y-2.5">
            <Satir k="Giriş" v={formatTam(bilet.giris_at)} />
            {bilet.cikis_at && <Satir k="Çıkış" v={formatTam(bilet.cikis_at)} />}
            <Satir k="Süre" v={sureMetni(bilet.giris_at, bilet.cikis_at)} />
            {bilet.ucret_kurus > 0 && <Satir k="Ücret" v={formatTL(bilet.ucret_kurus)} />}
            {bilet.indirim_kurus > 0 && (
              <Satir
                k="Puan indirimi"
                v={`−${formatTL(bilet.indirim_kurus)} (${bilet.puan_kullanilan} puan)`}
              />
            )}
            {bilet.odeme_yontemi && (
              <div className="flex items-center justify-between gap-3">
                <dt className="text-body text-faint">Ödeme</dt>
                <dd>
                  <span
                    className={`rounded-chip px-2.5 py-1 text-label font-medium ${ODEME_CHIP[bilet.odeme_yontemi]}`}
                  >
                    {ODEME_ETIKET[bilet.odeme_yontemi]}
                  </span>
                </dd>
              </div>
            )}
            <Satir k="Kaynak" v={bilet.giris_kaynak === 'KAMERA' ? 'Kamera' : 'Elle'} />
            {bilet.gecikmeli_kayit && bilet.kaynak_zaman && (
              <Satir
                k="Kameradan gelme"
                v={`${formatGoreceli(bilet.kaynak_zaman)} olayı, sonradan işlendi`}
              />
            )}
            {bilet.abonman_id && <Satir k="Abonman" v="Ücretsiz giriş" />}
            {bilet.kayip_bilet && <Satir k="Kayıp bilet" v="Evet" />}
          </dl>
        </Card>

        {bilet.ucret_degistirildi && (
          <div className="rounded-card bg-warn-soft px-4 py-3">
            <p className="text-body font-medium text-warn">Ücret elle değiştirilmiş</p>
            {bilet.ucret_sebep && (
              <p className="mt-1 text-label text-warn opacity-90">{bilet.ucret_sebep}</p>
            )}
          </div>
        )}

        {bilet.durum === 'IPTAL' && bilet.iptal_sebep && (
          <div className="rounded-card bg-danger-soft px-4 py-3">
            <p className="text-body font-medium text-danger">İptal edildi</p>
            <p className="mt-1 text-label text-danger opacity-90">{bilet.iptal_sebep}</p>
          </div>
        )}

        {(girisFoto || cikisFoto) && (
          <div className="grid grid-cols-2 gap-3">
            {girisFoto && <Foto url={girisFoto} etiket="Giriş" />}
            {cikisFoto && <Foto url={cikisFoto} etiket="Çıkış" />}
          </div>
        )}

        {/* Correcting the type re-snapshots the tariff, so it is only offered
            while the ticket is open and no money has moved. */}
        {acik && (
          <Card>
            <p className="mb-3 text-label font-medium tracking-wide text-faint uppercase">
              Araç tipini düzelt
            </p>
            <AracTipiSecici
              label={null}
              value={bilet.arac_tipi}
              onChange={(t: AracTipi) =>
                void tipDuzelt.mutateAsync({ bilet_id: bilet.id, arac_tipi: t })
              }
            />
            <p className="mt-2 text-label text-faint">
              Tarife yeniden seçilir; ücret buna göre hesaplanır.
            </p>
          </Card>
        )}

        <Button
          variant="danger"
          size="lg"
          block
          onClick={() => {
            setSebep('')
            setIptalHata(null)
            setIptalAcik(true)
          }}
        >
          Bileti İptal Et
        </Button>
      </div>

      <ConfirmDialog
        open={iptalAcik}
        onOpenChange={setIptalAcik}
        tone="danger"
        title="Bileti iptal et"
        description={
          bilet.durum === 'KAPALI'
            ? 'Tahsil edilen tutar için ters kayıt yazılır. İşlem geri alınamaz ve Yöneticiye bildirilir.'
            : 'Bu bilet iptal edilecek. İşlem geri alınamaz ve Yöneticiye bildirilir.'
        }
        confirmLabel="İptal Et"
        cancelLabel="Vazgeç"
        loading={iptal.isPending}
        error={iptalHata}
        onConfirm={() => {
          if (!sebep.trim()) {
            setIptalHata('İptal sebebi zorunludur.')
            return
          }
          void iptal
            .mutateAsync({ bilet_id: bilet.id, sebep: sebep.trim() })
            .then(() => setIptalAcik(false))
            .catch((e) => setIptalHata(rpcErrorText(e, 'Bilet iptal edilemedi.')))
        }}
      >
        <Input
          label="İptal sebebi"
          value={sebep}
          onChange={(e) => setSebep(e.target.value)}
          placeholder="Örn. yanlış plaka girildi"
          maxLength={200}
        />
      </ConfirmDialog>
    </div>
  )
}

function Satir({ k, v }: { k: string; v: string }) {
  return (
    <div className="flex items-baseline justify-between gap-3">
      <dt className="shrink-0 text-body text-faint">{k}</dt>
      <dd className="text-right text-body text-ink">{v}</dd>
    </div>
  )
}

function DurumRozeti({ durum }: { durum: 'ACIK' | 'KAPALI' | 'IPTAL' }) {
  const map = {
    ACIK: { t: 'İçeride', c: 'bg-accent-soft text-accent' },
    KAPALI: { t: 'Çıktı', c: 'bg-success-soft text-success' },
    IPTAL: { t: 'İptal', c: 'bg-danger-soft text-danger' },
  }
  const { t, c } = map[durum]
  return <span className={`rounded-chip px-2.5 py-1 text-label font-medium ${c}`}>{t}</span>
}

function Foto({ url, etiket }: { url: string; etiket: string }) {
  return (
    <figure>
      <img src={url} alt={`${etiket} fotoğrafı`} className="w-full rounded-card object-cover" />
      <figcaption className="mt-1.5 text-label text-faint">{etiket}</figcaption>
    </figure>
  )
}
