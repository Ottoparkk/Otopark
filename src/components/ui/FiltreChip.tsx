import type { ReactNode } from 'react'

/**
 * A filter chip: one of a row of separate buttons (Gişe's İçeride / Çıkanlar,
 * Çözülmemiş kayıtlar's tabs — owner, 27.11: separate buttons, not a glued
 * segmented bar). Visually identical to DonemSecici, deliberately — same
 * idiom, same tap target — but announced as a TOGGLE BUTTON, not a tab.
 *
 * `role="tab"` would be a promise the screen makes and then breaks: a tab owns
 * a tabpanel and answers arrow keys via roving tabindex, and neither is true
 * here.
 * `aria-pressed` describes exactly what this is (a pressed filter) and works
 * with plain Tab navigation, so nothing has to be simulated.
 */
export function FiltreChip({
  aktif,
  onClick,
  etiket,
  ikon,
}: {
  aktif: boolean
  onClick: () => void
  etiket: string
  /** Decorative (the icons are aria-hidden); the label stays the name. */
  ikon?: ReactNode
}) {
  return (
    <button
      type="button"
      aria-pressed={aktif}
      onClick={onClick}
      className={[
        'inline-flex min-h-[44px] shrink-0 items-center gap-1.5 rounded-chip px-4 text-body font-medium transition-colors',
        aktif ? 'bg-ink text-bg' : 'bg-field text-soft',
      ].join(' ')}
    >
      {ikon}
      {etiket}
    </button>
  )
}
