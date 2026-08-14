import * as Dialog from '@radix-ui/react-dialog'
import type { ReactNode } from 'react'
import { Button } from './primitives'

/**
 * Confirmation for anything irreversible.
 *
 * The `error` prop is load-bearing: when the server refuses (an RPC raising
 * "Bu plaka için zaten açık bir bilet var"), the dialog STAYS OPEN and shows
 * the Turkish message. A dialog that closes on rejection looks exactly like a
 * dialog that succeeded, and the operator walks away believing it worked.
 */
export function ConfirmDialog({
  open,
  onOpenChange,
  title,
  description,
  confirmLabel = 'Onayla',
  cancelLabel = 'Vazgeç',
  onConfirm,
  loading = false,
  error = null,
  tone = 'primary',
  children,
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
  title: string
  description?: ReactNode
  confirmLabel?: string
  cancelLabel?: string
  onConfirm: () => void
  loading?: boolean
  error?: string | null
  tone?: 'primary' | 'danger'
  children?: ReactNode
}) {
  return (
    <Dialog.Root open={open} onOpenChange={loading ? undefined : onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-40 bg-black/45 backdrop-blur-[2px]" />
        <Dialog.Content
          className="fixed bottom-0 left-1/2 z-50 w-full max-w-[440px] -translate-x-1/2 rounded-t-card bg-surface p-5 shadow-modal sm:bottom-auto sm:top-1/2 sm:-translate-y-1/2 sm:rounded-card"
          onOpenAutoFocus={(e) => e.preventDefault()}
        >
          <Dialog.Title className="text-title font-semibold text-ink">{title}</Dialog.Title>
          {description && (
            <Dialog.Description asChild>
              <div className="mt-2 text-body text-soft">{description}</div>
            </Dialog.Description>
          )}

          {children && <div className="mt-4">{children}</div>}

          {error && (
            <p
              role="alert"
              className="mt-4 rounded-field bg-danger-soft px-3 py-2.5 text-body text-danger"
            >
              {error}
            </p>
          )}

          <div className="safe-bottom mt-5 flex gap-2.5">
            <Button
              variant="secondary"
              size="lg"
              block
              onClick={() => onOpenChange(false)}
              disabled={loading}
            >
              {cancelLabel}
            </Button>
            <Button
              variant={tone === 'danger' ? 'danger' : 'primary'}
              size="lg"
              block
              onClick={onConfirm}
              loading={loading}
            >
              {confirmLabel}
            </Button>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  )
}
