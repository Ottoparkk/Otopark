import {
  Card,
  EmptyState,
  ListeDurumu,
  ScreenHeader,
} from '../../components/ui/primitives'
import { useTumVardiyalar } from './api'
import { useProfiller } from '../yonetim/api'
import { formatTL } from '../../lib/money'
import { formatTam } from '../../lib/dates'
import { sureMetni } from '../../lib/sure'
import { IconVardiya } from '../../components/ui/icons'

/**
 * Every shift, with its cash count.
 *
 * The difference column is the point of this screen — a shift that comes up
 * short is the single clearest signal in a cash business, and it should be
 * readable in one scan.
 */
export default function Vardiyalar() {
  const { data: liste = [], isPending, error, refetch } = useTumVardiyalar()
  const { data: profiller = [] } = useProfiller()

  const ad = (id: string) => profiller.find((p) => p.id === id)?.ad_soyad || 'Bilinmiyor'

  return (
    <div>
      <ScreenHeader title="Vardiyalar" back="/finans" subtitle="Son 100 vardiya" />

      <div className="space-y-2 px-5">
        <ListeDurumu
          pending={isPending}
          error={error}
          onRetry={() => void refetch()}
          empty={liste.length === 0}
          bos={<EmptyState icon={<IconVardiya size={44} />} title="Vardiya kaydı yok" />}
        >
          {liste.map((v) => {
            const acik = v.kapanis_at === null
            const fark = v.fark_kurus
            return (
              <Card key={v.id}>
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0">
                    <p className="truncate text-body font-medium text-ink">{ad(v.personel_id)}</p>
                    <p className="mt-0.5 text-label text-faint">
                      {formatTam(v.acilis_at)} ·{' '}
                      {acik ? 'devam ediyor' : sureMetni(v.acilis_at, v.kapanis_at)}
                    </p>
                  </div>

                  {acik ? (
                    <span className="shrink-0 rounded-chip bg-accent-soft px-2.5 py-1 text-label font-medium text-accent">
                      Açık
                    </span>
                  ) : fark === null ? (
                    <span className="text-label text-faint">—</span>
                  ) : fark === 0 ? (
                    <span className="shrink-0 rounded-chip bg-success-soft px-2.5 py-1 text-label font-medium text-success">
                      Tutuyor
                    </span>
                  ) : (
                    <span
                      className={`shrink-0 rounded-chip px-2.5 py-1 text-label font-medium tnum ${
                        fark < 0 ? 'bg-danger-soft text-danger' : 'bg-warn-soft text-warn'
                      }`}
                    >
                      {fark > 0 ? '+' : ''}
                      {formatTL(fark)}
                    </span>
                  )}
                </div>

                {!acik && v.beklenen_nakit_kurus !== null && (
                  <div className="mt-3 flex gap-4 border-t border-divider pt-3 text-label">
                    <span className="text-faint">
                      Beklenen{' '}
                      <span className="text-soft tnum">{formatTL(v.beklenen_nakit_kurus)}</span>
                    </span>
                    <span className="text-faint">
                      Sayılan{' '}
                      <span className="text-soft tnum">
                        {formatTL(v.sayilan_nakit_kurus ?? 0)}
                      </span>
                    </span>
                  </div>
                )}

                {v.notlar && <p className="mt-2 text-label text-faint">{v.notlar}</p>}
              </Card>
            )
          })}
        </ListeDurumu>
      </div>
    </div>
  )
}
