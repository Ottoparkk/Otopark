/**
 * Loading indicator. Always carries a label for screen readers — and, on the
 * money screens, a visible one too: a bare spinner at a barrier tells the
 * operator nothing about whether their tap registered.
 */
export function Spinner({
  label = 'Yükleniyor',
  size = 24,
  görünürEtiket = false,
}: {
  label?: string
  size?: number
  görünürEtiket?: boolean
}) {
  return (
    <div className="flex items-center justify-center gap-3" role="status">
      <svg
        width={size}
        height={size}
        viewBox="0 0 24 24"
        fill="none"
        className="animate-spin text-accent"
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
        <span className="text-body text-soft">{label}</span>
      ) : (
        <span className="sr-only">{label}</span>
      )}
    </div>
  )
}
