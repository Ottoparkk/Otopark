/**
 * Loading indicator. Always carries a label for screen readers — and, on the
 * money screens, a visible one too: a bare spinner at a barrier tells the
 * operator nothing about whether their tap registered.
 */
export function Spinner({
  label = 'Yükleniyor',
  size = 24,
  görünürEtiket = false,
  /**
   * `inherit` takes the surrounding text colour instead of the accent. Needed
   * on the brand panel, where an indigo spinner on an indigo gradient is
   * effectively invisible.
   */
  tone = 'accent',
}: {
  label?: string
  size?: number
  görünürEtiket?: boolean
  tone?: 'accent' | 'inherit'
}) {
  return (
    <div className="flex items-center justify-center gap-3" role="status">
      <svg
        width={size}
        height={size}
        viewBox="0 0 24 24"
        fill="none"
        className={`animate-spin ${tone === 'accent' ? 'text-accent' : ''}`}
        aria-hidden="true"
      >
        <circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="2.5" opacity="0.2" />
        <path
          d="M21 12a9 9 0 0 0-9-9"
          stroke="currentColor"
          strokeWidth="2.5"
          strokeLinecap="round"
        />
      </svg>
      {görünürEtiket ? (
        <span className={`text-body ${tone === 'accent' ? 'text-soft' : ''}`}>{label}</span>
      ) : (
        <span className="sr-only">{label}</span>
      )}
    </div>
  )
}
