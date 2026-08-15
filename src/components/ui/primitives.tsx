import type { ButtonHTMLAttributes, InputHTMLAttributes, ReactNode } from 'react'
import { useNavigate } from 'react-router'
import { IconGeri } from './icons'
import { Spinner } from './Spinner'

/**
 * The shared vocabulary. Every screen is built from these, which is what
 * keeps the spacing and type ramps consistent instead of each screen
 * inventing its own one-off pixel values.
 */

/* ------------------------------------------------------------------ Button */

type ButtonVariant = 'primary' | 'secondary' | 'ghost' | 'danger'

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: ButtonVariant
  /** Primary gate actions are `lg` — 56px, thumb-sized, one-handed. */
  size?: 'md' | 'lg'
  loading?: boolean
  block?: boolean
  children: ReactNode
}

const VARIANT: Record<ButtonVariant, string> = {
  // Only the primary button is elevated. A screen where every button floats
  // has no primary action — the lift is the hierarchy.
  primary: 'bg-accent text-accent-ink shadow-raised active:brightness-95',
  secondary: 'bg-field text-ink border border-border active:brightness-95',
  ghost: 'bg-transparent text-soft active:bg-field',
  danger: 'bg-danger-soft text-danger active:brightness-95',
}

export function Button({
  variant = 'primary',
  size = 'md',
  loading = false,
  block = false,
  disabled,
  className = '',
  children,
  ...rest
}: ButtonProps) {
  return (
    <button
      {...rest}
      disabled={disabled || loading}
      className={[
        'inline-flex items-center justify-center gap-2 rounded-field font-medium',
        // The press is confirmed by the button shrinking slightly. At a barrier
        // in gloves that tactile-looking feedback is worth more than a colour
        // change, which is easy to miss in sunlight.
        'transition-[filter,opacity,transform] duration-100 active:scale-[0.98]',
        // A disabled button must not float — elevation reads as "pressable".
        'disabled:opacity-45 disabled:shadow-none disabled:active:scale-100',
        size === 'lg' ? 'min-h-[56px] px-6 text-lead' : 'min-h-[44px] px-4 text-body',
        block ? 'w-full' : '',
        VARIANT[variant],
        className,
      ].join(' ')}
    >
      {loading && <Spinner size={18} label="İşleniyor" />}
      {children}
    </button>
  )
}

/* -------------------------------------------------------------------- Card */

/**
 * The surface almost everything in the app sits on.
 *
 * The hairline border is doing more work here than the shadow. A white card on
 * a near-white page separated only by colour measured 1.04:1 before this
 * change — invisible, which is most of why the app read as unfinished. The
 * border draws the edge, the shadow supplies the lift, and neither alone is
 * enough on a phone held at an angle in daylight.
 */
export function Card({
  children,
  className = '',
  as: Tag = 'div',
}: {
  children: ReactNode
  className?: string
  as?: 'div' | 'section' | 'li'
}) {
  return (
    <Tag className={`rounded-card border border-border bg-surface p-4 shadow-card ${className}`}>
      {children}
    </Tag>
  )
}

/* -------------------------------------------------------------- BrandPanel */

/**
 * The one branded surface. Reserved for the single most important number on a
 * screen — occupancy on Araçlar, the fee on Çıkış, today's takings on Yönetim.
 *
 * Deliberately scarce: if this appears three times on one screen it has
 * stopped meaning anything, and "emphasise by de-emphasising" is exactly the
 * rule it would be breaking. White text clears AA at both ends of the
 * gradient, which is what lets `text-on-brand-soft` exist as a second, quieter
 * voice on top of it.
 */
export function BrandPanel({
  children,
  className = '',
}: {
  children: ReactNode
  className?: string
}) {
  return (
    <div className={`rounded-card bg-brand p-5 text-on-brand shadow-card ${className}`}>
      {children}
    </div>
  )
}

/* ---------------------------------------------------------------- IconTile */

type TileTone = 'accent' | 'success' | 'warn' | 'danger' | 'neutral'

const TILE: Record<TileTone, string> = {
  accent: 'bg-accent-soft text-accent',
  success: 'bg-success-soft text-success',
  warn: 'bg-warn-soft text-warn',
  danger: 'bg-danger-soft text-danger',
  neutral: 'bg-field text-soft',
}

/**
 * A rounded tinted square holding an icon. Gives a row something to anchor on,
 * which is what stops a long menu reading as undifferentiated text.
 */
export function IconTile({
  children,
  tone = 'neutral',
  size = 'md',
}: {
  children: ReactNode
  tone?: TileTone
  size?: 'md' | 'lg'
}) {
  return (
    <span
      className={[
        'flex shrink-0 items-center justify-center rounded-field',
        size === 'lg' ? 'size-12' : 'size-11',
        TILE[tone],
      ].join(' ')}
    >
      {children}
    </span>
  )
}

/* ------------------------------------------------------------- OranCubugu */

/**
 * A capacity bar. `yuzde` is clamped rather than trusted: occupancy can exceed
 * capacity in real life (a mis-set kapasite, a car that never exited), and a
 * bar rendering at 140% width would break the layout it sits in.
 *
 * NaN is folded to 0 for the same reason. A caller dividing by a zero capacity
 * produces NaN, `width: NaN%` is an invalid declaration the browser drops, and
 * the bar would silently render empty — which looks like an empty car park
 * rather than a broken number.
 */
export function OranCubugu({
  yuzde,
  tone = 'brand',
  label = 'Doluluk oranı',
}: {
  yuzde: number
  tone?: 'brand' | 'accent'
  label?: string
}) {
  const kirpilmis = Number.isFinite(yuzde) ? Math.max(0, Math.min(100, Math.round(yuzde))) : 0
  return (
    <div
      className={`h-2 w-full overflow-hidden rounded-chip ${tone === 'brand' ? 'bg-white/25' : 'bg-field'}`}
      role="progressbar"
      aria-label={label}
      aria-valuenow={kirpilmis}
      aria-valuemin={0}
      aria-valuemax={100}
    >
      <div
        className={`h-full rounded-chip transition-[width] duration-300 ${tone === 'brand' ? 'bg-white' : 'bg-accent'}`}
        style={{ width: `${kirpilmis}%` }}
      />
    </div>
  )
}

/** Small uppercase label above a value. The lowest rung of the type ramp. */
export function Label({ children, htmlFor }: { children: ReactNode; htmlFor?: string }) {
  return (
    <label
      htmlFor={htmlFor}
      className="mb-1.5 block text-label font-medium tracking-wide text-faint uppercase"
    >
      {children}
    </label>
  )
}

/* ------------------------------------------------------------------- Input */

interface InputProps extends InputHTMLAttributes<HTMLInputElement> {
  label?: string
  /**
   * Hides the label visually while keeping it for screen readers.
   *
   * Refactoring UI: a label is a last resort. Where the format already says
   * what the field is — a plate, an amount next to a ₺ — the label is noise
   * competing with the value. Hiding it VISUALLY is the only acceptable way
   * to obey that: dropping it entirely would leave the input unnamed for
   * assistive tech, which is a real regression, not a design choice.
   */
  hideLabel?: boolean
  hint?: string
  error?: string | null
}

export function Input({
  label,
  hideLabel = false,
  hint,
  error,
  id,
  className = '',
  'aria-label': ariaLabel,
  ...rest
}: InputProps) {
  const inputId = id ?? rest.name ?? undefined
  return (
    <div>
      {label && !hideLabel && <Label htmlFor={inputId}>{label}</Label>}
      <input
        {...rest}
        id={inputId}
        // An explicit aria-label from the caller always wins; otherwise the
        // hidden visual label becomes the accessible name.
        aria-label={ariaLabel ?? (hideLabel ? label : undefined)}
        aria-invalid={error ? true : undefined}
        className={[
          'w-full rounded-field border border-border bg-field px-4 py-3 text-body text-ink',
          'min-h-[52px] outline-none',
          // The well is already darker than every surface it sits on; the
          // border is what gives it a crisp edge in daylight.
          //
          // Deliberately NOT animated. A colour transition here buys nothing —
          // the focus border reads fine switching instantly — and it makes the
          // field lag behind the rest of the screen when the theme flips,
          // which is the one moment every surface should change together.
          'focus:border-accent',
          // A disabled field must LOOK unavailable, or the operator keeps
          // tapping it and assumes the app is broken.
          'disabled:cursor-not-allowed disabled:opacity-55',
          error ? 'ring-2 ring-danger' : '',
          className,
        ].join(' ')}
      />
      {error ? (
        <p className="mt-1.5 text-label text-danger">{error}</p>
      ) : hint ? (
        <p className="mt-1.5 text-label text-faint">{hint}</p>
      ) : null}
    </div>
  )
}

/* --------------------------------------------------------------- DataPoint */

/**
 * A read-only value with an optional QUIET caption underneath — not a label
 * above it.
 *
 * Two Refactoring UI rules at once. "Labels are a last resort": a plate looks
 * like a plate, a duration looks like a duration, and stacking
 * `PLAKA / 34 ABC 123` puts a shouting uppercase label next to the thing it
 * describes. And "emphasise by de-emphasising": where a caption is genuinely
 * needed it sits BELOW at the faintest rung, so it never competes with the
 * value.
 *
 * `size="hero"` is reserved for the one number being collected. Nothing else
 * in the app may use it.
 */
export function DataPoint({
  value,
  caption,
  size = 'md',
  tone = 'default',
  align = 'left',
}: {
  value: ReactNode
  caption?: ReactNode
  size?: 'md' | 'lg' | 'hero'
  tone?: 'default' | 'muted' | 'success' | 'danger'
  align?: 'left' | 'center' | 'right'
}) {
  const sizes = {
    md: 'text-lead font-medium',
    lg: 'text-title font-semibold',
    hero: 'text-hero font-semibold tnum',
  }
  const tones = {
    default: 'text-ink',
    muted: 'text-soft',
    success: 'text-success',
    danger: 'text-danger',
  }
  const aligns = { left: 'text-left', center: 'text-center', right: 'text-right' }

  return (
    <div className={aligns[align]}>
      <div className={`${sizes[size]} ${tones[tone]}`}>{value}</div>
      {caption && <div className="mt-1 text-label text-faint">{caption}</div>}
    </div>
  )
}

/* -------------------------------------------------------------------- Chip */

export function Chip({
  children,
  tone = 'neutral',
  className = '',
}: {
  children: ReactNode
  tone?: 'neutral' | 'accent' | 'success' | 'danger' | 'warn'
  className?: string
}) {
  const tones = {
    neutral: 'bg-field text-soft',
    accent: 'bg-accent-soft text-accent',
    success: 'bg-success-soft text-success',
    danger: 'bg-danger-soft text-danger',
    warn: 'bg-warn-soft text-warn',
  }
  return (
    <span
      className={`inline-flex items-center gap-1 rounded-chip px-2.5 py-1 text-label font-medium ${tones[tone]} ${className}`}
    >
      {children}
    </span>
  )
}

/* ----------------------------------------------------------- SegmentedControl */

export function SegmentedControl<T extends string>({
  value,
  options,
  onChange,
  label,
}: {
  value: T
  options: { value: T; label: string }[]
  onChange: (v: T) => void
  label?: string
}) {
  return (
    <div>
      {label && <Label>{label}</Label>}
      <div className="flex gap-1 rounded-field bg-field p-1" role="tablist">
        {options.map((o) => {
          const active = o.value === value
          return (
            <button
              key={o.value}
              type="button"
              role="tab"
              aria-selected={active}
              onClick={() => onChange(o.value)}
              className={[
                'min-h-[44px] flex-1 rounded-[12px] px-2 text-body font-medium transition-colors',
                // The thumb has to look like it sits ON the track, not in it.
                active ? 'bg-surface text-ink shadow-raised' : 'text-soft',
              ].join(' ')}
            >
              {o.label}
            </button>
          )
        })}
      </div>
    </div>
  )
}

/* ------------------------------------------------------------ ScreenHeader */

export function ScreenHeader({
  title,
  subtitle,
  back,
  onBack,
  right,
}: {
  title: string
  subtitle?: string
  /** true = go back one entry; a string = navigate there deterministically. */
  back?: boolean | string
  /**
   * Overrides navigation entirely — for a sub-view rendered inside the same
   * route (the collect step of Çıkış), where history has no entry to go back
   * to and navigate(-1) would leave the screen altogether.
   */
  onBack?: () => void
  right?: ReactNode
}) {
  const navigate = useNavigate()
  return (
    <header className="safe-top mb-4 flex items-start gap-3 px-5">
      {(back || onBack) && (
        <button
          type="button"
          onClick={() => {
            if (onBack) {
              onBack()
              return
            }
            if (typeof back === 'string') navigate(back)
            else navigate(-1)
          }}
          aria-label="Geri"
          className="-ml-2 flex size-11 shrink-0 items-center justify-center rounded-chip text-soft active:bg-field"
        >
          <IconGeri size={22} />
        </button>
      )}
      <div className="min-w-0 flex-1 pt-1.5">
        <h1 className="truncate text-title font-semibold text-ink">{title}</h1>
        {subtitle && <p className="mt-0.5 text-label text-faint">{subtitle}</p>}
      </div>
      {right && <div className="flex shrink-0 items-center gap-1 pt-0.5">{right}</div>}
    </header>
  )
}

/* --------------------------------------------------------------- EmptyState */

/**
 * Designed first, not as an afterthought. "Bugün henüz araç girişi yok" is a
 * real screen an operator sees every morning.
 */
export function EmptyState({
  icon,
  title,
  hint,
  action,
}: {
  icon?: ReactNode
  title: string
  hint?: string
  action?: ReactNode
}) {
  return (
    <div className="flex flex-col items-center px-8 py-14 text-center">
      {/* The icon sits in a tinted disc rather than floating grey-on-grey.
          An empty screen is one an operator sees every morning; it should look
          designed, not like something failed to load. */}
      {icon && (
        <div className="mb-4 flex size-20 items-center justify-center rounded-chip bg-field text-faint">
          {icon}
        </div>
      )}
      <p className="text-lead font-medium text-ink">{title}</p>
      {hint && <p className="mt-1.5 max-w-[36ch] text-body text-faint">{hint}</p>}
      {action && <div className="mt-5">{action}</div>}
    </div>
  )
}

/* ------------------------------------------------------------- LoadError */

/**
 * A form that renders blank on a failed load makes the user think their data
 * was deleted. Say so instead, and never draw an empty form over an error.
 *
 * text-danger on bg-danger-soft is legible in BOTH themes (measured 4.8:1
 * light, 7.1:1 dark) because dark mode redefines the red rather than reusing
 * the light one — a single shared #c0322b would land at 2.9:1 here.
 */
export function LoadError({ error, onRetry }: { error?: unknown; onRetry?: () => void }) {
  const detay =
    typeof (error as { message?: unknown })?.message === 'string'
      ? (error as { message: string }).message
      : null
  return (
    <div className="rounded-card bg-danger-soft p-4">
      <p className="text-body font-medium text-danger">Yüklenemedi.</p>
      {detay && <p className="mt-1 text-label text-soft">{detay}</p>}
      {onRetry && (
        <button
          type="button"
          onClick={onRetry}
          className="mt-3 min-h-[44px] text-body font-medium text-danger underline"
        >
          Tekrar dene
        </button>
      )}
    </div>
  )
}

/* ------------------------------------------------------------ ListeDurumu */

/**
 * The three states every list has, in the only order that is honest:
 * failed → loading → empty → rows.
 *
 * Getting this wrong is subtle and expensive: rendering "Henüz kayıt yok" over
 * a request that is still in flight — or worse, one that FAILED — tells the
 * operator their data is gone. They then re-enter it, and now there are two.
 * `empty` is a claim about the data, so it may only be made once the data has
 * actually arrived.
 */
export function ListeDurumu({
  pending,
  error,
  onRetry,
  empty,
  bos,
  children,
}: {
  pending: boolean
  error?: unknown
  onRetry?: () => void
  empty: boolean
  /** Shown ONLY when the list is known to be empty. */
  bos: ReactNode
  children: ReactNode
}) {
  if (error) return <LoadError error={error} onRetry={onRetry} />
  if (pending)
    return (
      <div className="py-10">
        <Spinner label="Yükleniyor" />
      </div>
    )
  return <>{empty ? bos : children}</>
}

/* ------------------------------------------------------------ FloatingBar */

/**
 * The primary action, pinned in the thumb zone with home-indicator clearance.
 * Shadow is earned here — this genuinely floats above scrolling content.
 */
export function FloatingBar({ children }: { children: ReactNode }) {
  return (
    <div className="safe-bottom sticky bottom-0 z-10 mt-6 bg-bg/85 px-5 pt-3 shadow-sheet backdrop-blur">
      {children}
    </div>
  )
}
