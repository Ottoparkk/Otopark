import { useNavigate, useParams } from 'react-router'
import { Card, LoadError, ScreenHeader } from '../../components/ui/primitives'
import { Spinner } from '../../components/ui/Spinner'
import { useBilet, useYerKodlari } from './api'
import { BiletBilgileri, BiletEkleri, IptalButonu, useBiletAksiyonlari } from './components'
import { formatPlaka } from '../../lib/plaka'
import { formatTL } from '../../lib/money'
import { IconCop } from '../../components/ui/icons'

/** Full history of one ticket. Reached from the vehicles list and Finans. */
export default function BiletDetay() {
  const { id } = useParams()
  const navigate = useNavigate()
  const { data: bilet, isPending, error, refetch } = useBilet(id)
  const yerKodlari = useYerKodlari()

  // The hook must run on every render, so it is called before the early
  // returns and simply gets `undefined` while the ticket is loading.
  const aksiyon = useBiletAksiyonlari(bilet, { onSilindi: () => navigate('/gise') })

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
            <span className="text-title font-semibold text-ink tnum">
              {bilet.durum === 'IPTAL' ? '—' : formatTL(bilet.tahsil_kurus)}
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
