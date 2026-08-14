import { Label } from './primitives'
import { ODEME_ETIKET, type OdemeYontemi } from '../../lib/types'

const SIRA: OdemeYontemi[] = ['NAKIT', 'KREDI_KARTI', 'HAVALE']

/**
 * Payment method picker. Nakit first because it is the overwhelming majority
 * of gate transactions and should be one tap away.
 *
 * Selected state uses the method's own colour token, so Nakit reads green and
 * Kart blue at a glance — the operator confirms the method without reading.
 */
export function YontemSecici({
  value,
  onChange,
  label = 'Ödeme yöntemi',
  disabled = false,
}: {
  value: OdemeYontemi | null
  onChange: (v: OdemeYontemi) => void
  label?: string | null
  disabled?: boolean
}) {
  const tone: Record<OdemeYontemi, string> = {
    NAKIT: 'bg-nakit text-surface',
    KREDI_KARTI: 'bg-kart text-surface',
    HAVALE: 'bg-havale text-surface',
  }

  return (
    <div>
      {label && <Label>{label}</Label>}
      <div className="grid grid-cols-3 gap-2" role="radiogroup" aria-label="Ödeme yöntemi">
        {SIRA.map((y) => {
          const active = value === y
          return (
            <button
              key={y}
              type="button"
              role="radio"
              aria-checked={active}
              disabled={disabled}
              onClick={() => onChange(y)}
              className={[
                'min-h-[56px] rounded-field px-2 text-body font-medium transition-colors',
                'disabled:opacity-45',
                active ? tone[y] : 'bg-field text-soft',
              ].join(' ')}
            >
              {ODEME_ETIKET[y]}
            </button>
          )
        })}
      </div>
    </div>
  )
}
