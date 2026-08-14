import { useId } from 'react'

/** A switch with its label, sized for a thumb (the whole row is the target). */
export function Toggle({
  checked,
  onChange,
  label,
  hint,
  disabled = false,
}: {
  checked: boolean
  onChange: (v: boolean) => void
  label: string
  hint?: string
  disabled?: boolean
}) {
  const id = useId()
  return (
    <div className="flex min-h-[56px] items-center justify-between gap-4 py-1">
      <div className="min-w-0">
        <label htmlFor={id} className="block text-body font-medium text-ink">
          {label}
        </label>
        {hint && <p className="mt-0.5 text-label text-faint">{hint}</p>}
      </div>
      <button
        id={id}
        type="button"
        role="switch"
        aria-checked={checked}
        disabled={disabled}
        onClick={() => onChange(!checked)}
        className={[
          'relative h-[32px] w-[54px] shrink-0 rounded-chip transition-colors disabled:opacity-45',
          checked ? 'bg-accent' : 'bg-field',
        ].join(' ')}
      >
        <span
          className={[
            'absolute top-[3px] size-[26px] rounded-chip bg-surface transition-[left] duration-150',
            checked ? 'left-[25px]' : 'left-[3px]',
          ].join(' ')}
        />
      </button>
    </div>
  )
}
