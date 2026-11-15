import type { KimSatiri } from '../../lib/kimYapti'
import { formatTam } from '../../lib/dates'

/**
 * "Ödeme toplayan: Ayşe" / "Onaylayan: Mehmet · 15.11.2026 12:30" (063).
 * Who-did-it lines under a record. Only the Yönetici's screens render these.
 */
export function KimSatirlari({
  satirlar,
  className = '',
}: {
  satirlar: (KimSatiri | null)[]
  className?: string
}) {
  const dolu = satirlar.filter((s): s is KimSatiri => s !== null)
  if (dolu.length === 0) return null
  return (
    <div className={`space-y-0.5 text-label text-faint ${className}`}>
      {dolu.map((s) => (
        // Wraps rather than truncates: on a 360px phone the time is the part
        // a cut would drop, and "when" matters as much as "who" here.
        <p key={s.etiket} className="break-words">
          {s.etiket}: <span className="font-medium text-soft">{s.ad}</span>
          {s.zaman && (
            <span className="whitespace-nowrap tnum"> · {formatTam(s.zaman)}</span>
          )}
        </p>
      ))}
    </div>
  )
}
