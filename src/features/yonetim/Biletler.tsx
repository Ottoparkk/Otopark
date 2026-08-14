import { useState } from 'react'
import { useNavigate } from 'react-router'
import {
  Card,
  EmptyState,
  Input,
  ListeDurumu,
  ScreenHeader,
} from '../../components/ui/primitives'
import { useBiletGecmisi } from './api'
import { formatPlaka } from '../../lib/plaka'
import { formatTL } from '../../lib/money'
import { formatGoreceli } from '../../lib/dates'
import { sureMetni } from '../../lib/sure'
import { IconAra, IconAraba } from '../../components/ui/icons'
import { ODEME_CHIP, ODEME_ETIKET, type BiletDurum } from '../../lib/types'

const FILTRELER: { value: BiletDurum | 'TUMU'; label: string }[] = [
  { value: 'TUMU', label: 'Tümü' },
  { value: 'ACIK', label: 'İçeride' },
  { value: 'KAPALI', label: 'Çıktı' },
  { value: 'IPTAL', label: 'İptal' },
]

export default function Biletler() {
  const navigate = useNavigate()
  const [durum, setDurum] = useState<BiletDurum | 'TUMU'>('TUMU')
  const [q, setQ] = useState('')
  const { data: liste = [], isPending, error, refetch } = useBiletGecmisi({ durum, q })

  return (
    <div>
      <ScreenHeader title="Bilet geçmişi" back="/yonetim" subtitle="Son 200 kayıt" />

      <div className="space-y-3 px-5">
        <div className="relative">
          <IconAra
            size={20}
            className="pointer-events-none absolute top-1/2 left-4 -translate-y-1/2 text-faint"
          />
          <Input
            label="Plaka ara"
            hideLabel
            value={q}
            onChange={(e) => setQ(e.target.value.toUpperCase())}
            placeholder="Plaka ara"
            autoCapitalize="characters"
            autoCorrect="off"
            spellCheck={false}
            className="pl-11 tnum"
          />
        </div>

        <div className="flex gap-2 overflow-x-auto pb-1">
          {FILTRELER.map((f) => (
            <button
              key={f.value}
              type="button"
              onClick={() => setDurum(f.value)}
              className={[
                'min-h-[40px] shrink-0 rounded-chip px-4 text-body font-medium transition-colors',
                durum === f.value ? 'bg-ink text-bg' : 'bg-field text-soft',
              ].join(' ')}
            >
              {f.label}
            </button>
          ))}
        </div>

        <div className="space-y-2">
          <ListeDurumu
            pending={isPending}
            error={error}
            onRetry={() => void refetch()}
            empty={liste.length === 0}
            bos={<EmptyState icon={<IconAraba size={44} />} title="Kayıt yok" />}
          >
            {liste.map((b) => (
              <Card key={b.id} as="div">
                <button
                  type="button"
                  onClick={() => navigate(`/gise/bilet/${b.id}`)}
                  className="w-full text-left"
                >
                  <div className="flex items-baseline justify-between gap-3">
                    <span className="truncate text-lead font-semibold tracking-wide text-ink tnum">
                      {formatPlaka(b.plaka)}
                    </span>
                    <span
                      className={`shrink-0 text-body font-semibold tnum ${
                        b.durum === 'IPTAL' ? 'text-faint line-through' : 'text-ink'
                      }`}
                    >
                      {b.durum === 'ACIK' ? '—' : formatTL(b.tahsil_kurus)}
                    </span>
                  </div>

                  <div className="mt-1 flex flex-wrap items-center gap-2">
                    <span className="text-label text-faint">
                      {formatGoreceli(b.giris_at)} · {sureMetni(b.giris_at, b.cikis_at)}
                    </span>
                    {b.odeme_yontemi && (
                      <span
                        className={`rounded-chip px-2 py-0.5 text-micro font-medium ${ODEME_CHIP[b.odeme_yontemi]}`}
                      >
                        {ODEME_ETIKET[b.odeme_yontemi]}
                      </span>
                    )}
                    {b.abonman_id && (
                      <span className="rounded-chip bg-success-soft px-2 py-0.5 text-micro font-medium text-success">
                        Abonman
                      </span>
                    )}
                    {b.ucret_degistirildi && (
                      <span className="rounded-chip bg-danger-soft px-2 py-0.5 text-micro font-medium text-danger">
                        Ücret değişti
                      </span>
                    )}
                    {b.kayip_bilet && (
                      <span className="rounded-chip bg-warn-soft px-2 py-0.5 text-micro font-medium text-warn">
                        Kayıp bilet
                      </span>
                    )}
                    {b.giris_kaynak === 'KAMERA' && (
                      <span className="rounded-chip bg-field px-2 py-0.5 text-micro font-medium text-soft">
                        Kamera
                      </span>
                    )}
                  </div>
                </button>
              </Card>
            ))}
          </ListeDurumu>
        </div>
      </div>
    </div>
  )
}
