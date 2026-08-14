import type { ReactNode } from 'react'

/** Shared frame for the signed-out screens. */
export function AuthLayout({
  title,
  subtitle,
  children,
  footer,
}: {
  title: string
  subtitle?: string
  children: ReactNode
  footer?: ReactNode
}) {
  return (
    <div className="flex min-h-dvh flex-col bg-bg">
      <div className="safe-top mx-auto flex w-full max-w-[420px] flex-1 flex-col justify-center px-6 py-10">
        <div className="mb-8">
          <div className="mb-6 flex size-14 items-center justify-center rounded-card bg-ink text-[26px] font-bold text-bg">
            P
          </div>
          <h1 className="text-title font-semibold text-ink">{title}</h1>
          {subtitle && <p className="mt-1.5 text-body text-soft">{subtitle}</p>}
        </div>

        {children}

        {footer && <div className="safe-bottom mt-8 text-center">{footer}</div>}
      </div>
    </div>
  )
}
