import { useState, type ReactNode } from 'react'
import { Card } from './primitives'

/**
 * The compact "check this plate" card shared by Çözülmemiş kayıtlar and the
 * ticket's "Plaka yanlış olabilir": the photo, ONE status line, then whatever
 * the screen puts underneath (the plate field and its buttons).
 *
 * Presentational only — no data hooks, the signed photo URL is passed in — so
 * both screens can own their own mutations and errors.
 *
 * The photo is the evidence the operator compares the plate against, so it
 * leads. Tapping it toggles a taller, uncropped view: there is no lightbox in
 * the app, and a crop that cuts the plate's last character is exactly the one
 * case where the operator needs to see the whole frame.
 */
export function PlakaKontrol({
  fotoUrl,
  durum,
  ton = 'warn',
  ust,
  children,
  className = '',
}: {
  fotoUrl?: string | null
  /** The single status line. Keep it short — one line on a phone. */
  durum: string
  ton?: 'warn' | 'success' | 'neutral'
  /** Optional meta row above the photo (lane · time, a delete button). */
  ust?: ReactNode
  children?: ReactNode
  className?: string
}) {
  const [buyuk, setBuyuk] = useState(false)

  const tonCls =
    ton === 'warn' ? 'text-warn' : ton === 'success' ? 'text-success' : 'text-faint'
  const noktaCls = ton === 'warn' ? 'bg-warn' : ton === 'success' ? 'bg-success' : 'bg-faint'

  return (
    <Card className={`space-y-3 ${className}`}>
      {ust}

      {fotoUrl && (
        <button
          type="button"
          onClick={() => setBuyuk((b) => !b)}
          aria-label={buyuk ? 'Fotoğrafı küçült' : 'Fotoğrafı büyüt'}
          aria-pressed={buyuk}
          className="block w-full overflow-hidden rounded-field bg-field"
        >
          <img
            src={fotoUrl}
            alt="Plaka fotoğrafı"
            className={
              buyuk ? 'max-h-[70vh] w-full object-contain' : 'h-36 w-full object-cover'
            }
          />
        </button>
      )}

      <p className={`flex items-center gap-2 text-label font-medium ${tonCls}`}>
        <span aria-hidden className={`size-2 shrink-0 rounded-full ${noktaCls}`} />
        <span className="min-w-0 truncate">{durum}</span>
      </p>

      {children}
    </Card>
  )
}
