import { useState } from 'react'
import { useNavigate, useParams } from 'react-router'
import { Button, Card, LoadError, ScreenHeader } from '../../components/ui/primitives'
import { Spinner } from '../../components/ui/Spinner'
import { YontemSecici } from '../../components/ui/YontemSecici'
import { useBilet, useBiletTahsil, useYerKodlari } from './api'
import { BiletBilgileri, BiletEkleri, IptalButonu, useBiletAksiyonlari } from './components'
import { formatPlaka } from '../../lib/plaka'
import { formatTL } from '../../lib/money'
import { biletBorcu, odemeAlindi } from '../../lib/bilet'
import { rpcErrorText } from '../../lib/errors'
import { IconCop } from '../../components/ui/icons'
import { ODEME_DURUM_ETIKET, type OdemeYontemi } from '../../lib/types'

/** Full history of one ticket. Reached from the vehicles list and Finans. */
export default function BiletDetay() {
  const { id } = useParams()
  const navigate = useNavigate()
  const { data: bilet, isPending, error, refetch } = useBilet(id)
  const yerKodlari = useYerKodlari()

  // The hook must run on every render, so it is called before the early
  // returns and simply gets `undefined` while the ticket is loading.
  const aksiyon = useBiletAksiyonlari(bilet, { onSilindi: () => navigate('/gise') })

  // Declared before the early returns below, like the hook above: a hook that
  // only runs on some renders changes the hook order between them.
  const tahsil = useBiletTahsil()
  const [yontem, setYontem] = useState<OdemeYontemi | null>('NAKIT')
  const [tahsilHata, setTahsilHata] = useState<string | null>(null)

  // `bilet` is undefined until the query settles, so this is computed after
  // the early returns below rather than here.

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

  const borc = biletBorcu(bilet)
  const odenmedi = bilet.durum === 'KAPALI' && borc > 0 && !odemeAlindi(bilet)

  return (
    <div>
      {/* Delete sits in the header, where the app puts "remove this record"
          everywhere else, and deliberately NOT beside İptal at the bottom:
          cancelling reverses the money and keeps the history, deleting takes
          the record away, and a mis-tap between the two is not a mistake
          worth making easy. */}
      <ScreenHeader
        title={formatPlaka(bilet.plaka)}
        back
        right={
          aksiyon.silinebilir ? (
            <button
              type="button"
              onClick={aksiyon.silAc}
              // Labelled and red. A lone grey bin in a header is the one
              // control here that destroys a record, and it read as the
              // quietest thing on the screen.
              className="flex min-h-[44px] shrink-0 items-center gap-1.5 rounded-chip px-3 text-body font-medium text-danger active:bg-danger-soft"
            >
              <IconCop size={18} />
              Sil
            </button>
          ) : undefined
        }
      />

      <div className="space-y-4 px-5">
        <Card>
          <div className="flex items-baseline justify-between gap-3">
            {/* The FEE, not what was collected: since 027 a closed ticket can
                owe money, and showing ₺0,00 on a debt would read as "nothing
                to pay". They are the same number on a paid ticket. */}
            <span className="text-title font-semibold text-ink tnum">
              {bilet.durum === 'IPTAL' ? '—' : formatTL(borc)}
            </span>
            <DurumRozeti durum={bilet.durum} />
          </div>

          <div className="mt-4">
            <BiletBilgileri
              bilet={bilet}
              yerKod={bilet.park_yeri_id ? (yerKodlari[bilet.park_yeri_id] ?? null) : null}
            />
          </div>
        </Card>

        {/* The other half of "Çıkış Ver": the car has gone, the money has
            not. Only ever shown on a closed ticket that owes something —
            never on an open one, which is collected at the gate. */}
        {odenmedi && (
          <Card className="space-y-4">
            <div>
              <p className="text-label font-medium tracking-wide text-warn uppercase">
                {ODEME_DURUM_ETIKET.ALINMADI}
              </p>
              <p className="mt-1 text-body text-soft">
                Araç <strong className="font-semibold text-ink">{formatTL(borc)}</strong>{' '}
                borçlu çıktı. Parayı şimdi tahsil edebilirsiniz.
              </p>
            </div>

            <YontemSecici value={yontem} onChange={setYontem} />

            {tahsilHata && (
              <p role="alert" className="rounded-field bg-danger-soft px-3.5 py-3 text-body text-danger">
                {tahsilHata}
              </p>
            )}

            <Button
              size="lg"
              block
              loading={tahsil.isPending}
              onClick={() => {
                setTahsilHata(null)
                if (!yontem) {
                  setTahsilHata('Ödeme yöntemi seçin.')
                  return
                }
                void tahsil
                  .mutateAsync({ bilet_id: bilet.id, odeme_yontemi: yontem })
                  .catch((e) =>
                    setTahsilHata(
                      rpcErrorText(e, 'Tahsilat kaydedilemedi. Tahsilat otomatik tekrarlanmaz.'),
                    ),
                  )
              }}
            >
              {formatTL(borc)} Tahsil Et
            </Button>
          </Card>
        )}

        <BiletEkleri bilet={bilet} />

        <IptalButonu onClick={aksiyon.iptalAc} size="lg" />
      </div>

      {aksiyon.dialoglar}
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
