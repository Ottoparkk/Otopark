import { useId } from 'react'
import { Label } from './primitives'
import { normalizePlaka, plakaOlagan } from '../../lib/plaka'

/**
 * Plate entry, tuned for a thumb at a barrier.
 *
 * - Normalises on every keystroke, so what is stored matches what the server
 *   will store and the operator can see the real value, not a pretty lie.
 * - `inputMode="text"` + `autoCapitalize="characters"` gets the right keyboard
 *   without fighting autocorrect.
 * - An unusual-looking plate WARNS, it never blocks. A regex that rejects a
 *   valid plate stops a paying customer leaving, which is far worse than
 *   accepting an odd one.
 */
export function PlakaInput({
  value,
  onChange,
  label = 'Plaka',
  /**
   * A giant tracked uppercase field with a "34ABC123" placeholder is already
   * unmistakably a plate — the label above it is the exact clutter
   * Refactoring UI warns about. Hidden VISUALLY only; it stays the accessible
   * name, because an unnamed input is a real regression rather than a
   * cleaner design.
   */
  hideLabel = false,
  autoFocus = false,
  error = null,
  onEnter,
}: {
  value: string
  onChange: (v: string) => void
  label?: string
  hideLabel?: boolean
  autoFocus?: boolean
  error?: string | null
  onEnter?: () => void
}) {
  const id = useId()
  const normalized = normalizePlaka(value)
  const olagansiz = normalized.length >= 4 && !plakaOlagan(normalized)

  return (
    <div>
      {!hideLabel && <Label htmlFor={id}>{label}</Label>}
      <input
        id={id}
        aria-label={hideLabel ? label : undefined}
        value={value}
        onChange={(e) => onChange(normalizePlaka(e.target.value))}
        onKeyDown={(e) => {
          if (e.key === 'Enter' && onEnter) {
            e.preventDefault()
            onEnter()
          }
        }}
        // eslint-disable-next-line jsx-a11y/no-autofocus -- the gate screen has
        // exactly one job and the keyboard should already be up.
        autoFocus={autoFocus}
        inputMode="text"
        autoCapitalize="characters"
        autoCorrect="off"
        spellCheck={false}
        autoComplete="off"
        maxLength={15}
        placeholder="34ABC123"
        aria-invalid={error ? true : undefined}
        aria-describedby={olagansiz ? `${id}-uyari` : undefined}
        className={[
          'w-full rounded-field bg-field px-4 py-3 text-ink',
          // Big, tabular, wide-tracked: read aloud from a metre away.
          'min-h-[64px] text-center text-[28px] font-semibold tracking-[0.12em] tnum uppercase',
          'outline-none',
          error ? 'ring-2 ring-danger' : '',
        ].join(' ')}
      />
      {error ? (
        <p className="mt-1.5 text-label text-danger">{error}</p>
      ) : olagansiz ? (
        <p id={`${id}-uyari`} className="mt-1.5 text-label text-warn">
          Bu plaka alışılmadık görünüyor — yine de kaydedebilirsiniz.
        </p>
      ) : null}
    </div>
  )
}
