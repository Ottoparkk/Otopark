import { useEffect } from 'react'
import { useNavigate } from 'react-router'
import {
  Card,
  EmptyState,
  ListeDurumu,
  ScreenHeader,
} from '../../components/ui/primitives'
import { useBildirimler, useHepsiniOkundu } from './api'
import { formatGoreceli } from '../../lib/dates'
import { IconZil } from '../../components/ui/icons'
import { BILDIRIM_ETIKET, type BildirimTur } from '../../lib/types'

/** Tone per notification type — colour supports the label, never replaces it. */
const TON: Record<BildirimTur, string> = {
  YENI_UYELIK: 'bg-accent-soft text-accent',
  ABONMAN_BITIYOR: 'bg-warn-soft text-warn',
  VARDIYA_FARK: 'bg-danger-soft text-danger',
  TERK_EDILMIS: 'bg-warn-soft text-warn',
  DOLULUK: 'bg-warn-soft text-warn',
  BILET_IPTAL: 'bg-danger-soft text-danger',
  UCRET_DEGISIKLIGI: 'bg-danger-soft text-danger',
  PUAN_KULLANIM: 'bg-accent-soft text-accent',
  KAMERA: 'bg-danger-soft text-danger',
  // Routine traffic, not a problem: neutral, so a hundred of these a day do
  // not make the list look like a hundred alarms.
  KAMERA_HAREKET: 'bg-field text-soft',
  ISTISNA: 'bg-warn-soft text-warn',
  VARDIYA_ACIK: 'bg-warn-soft text-warn',
  ONAY_BEKLIYOR: 'bg-warn-soft text-warn',
  PLAKA_SUPHE: 'bg-warn-soft text-warn',
}

export default function Bildirimler() {
  const navigate = useNavigate()
  const { data: liste = [], isPending, error, refetch } = useBildirimler()
  const okundu = useHepsiniOkundu()

  // Mark read on open. Deliberately fire-and-forget: a failure here must not
  // stop the operator reading their notifications.
  useEffect(() => {
    if (liste.some((b) => b.read_at === null)) {
      okundu.mutate()
    }
    // Runs when the list first arrives; re-running on every render would loop.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isPending])

  return (
    <div>
      <ScreenHeader title="Bildirimler" back="/gise" />

      <div className="space-y-2 px-5">
        <ListeDurumu
          pending={isPending}
          error={error}
          onRetry={() => void refetch()}
          empty={liste.length === 0}
          bos={
            <EmptyState
              icon={<IconZil size={44} />}
              title="Bildirim yok"
              hint="Vardiya farkı, ücret değişikliği ve abonman uyarıları burada görünür."
            />
          }
        >
          {liste.map((b) => (
            <Card
              key={b.id}
              as="div"
              className={b.read_at ? 'opacity-70' : ''}
            >
              <button
                type="button"
                disabled={!b.link}
                onClick={() => b.link && navigate(b.link)}
                className="w-full text-left disabled:cursor-default"
              >
                <div className="flex items-start gap-3">
                  <span
                    className={`shrink-0 rounded-chip px-2.5 py-1 text-micro font-medium ${TON[b.tur]}`}
                  >
                    {BILDIRIM_ETIKET[b.tur]}
                  </span>
                  {!b.read_at && (
                    <span className="mt-1.5 size-2 shrink-0 rounded-full bg-accent" />
                  )}
                </div>
                <p className="mt-2 text-body font-medium text-ink">{b.baslik}</p>
                {b.govde && <p className="mt-0.5 text-body text-soft">{b.govde}</p>}
                <p className="mt-1.5 text-label text-faint">{formatGoreceli(b.created_at)}</p>
              </button>
            </Card>
          ))}
        </ListeDurumu>
      </div>
    </div>
  )
}
