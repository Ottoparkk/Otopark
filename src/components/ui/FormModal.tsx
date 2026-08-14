import * as Dialog from '@radix-ui/react-dialog'
import type { FormEvent, ReactNode } from 'react'
import { Button } from './primitives'
import { IconCarpi } from './icons'

/**
 * A bottom sheet on mobile, a centred card on desktop. Used for every
 * create/edit form so they all behave the same way.
 *
 * Like ConfirmDialog, it stays open and shows `error` when the server
 * refuses — the whole point of a Turkish message raised by a constraint is
 * that the operator gets to read it.
 */
export function FormModal({
  open,
  onOpenChange,
  title,
  submitLabel = 'Kaydet',
  onSubmit,
  loading = false,
  error = null,
  disabled = false,
  children,
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
  title: string
  submitLabel?: string
  onSubmit: () => void
  loading?: boolean
  error?: string | null
  disabled?: boolean
  children: ReactNode
}) {
  function handleSubmit(e: FormEvent) {
    e.preventDefault()
    if (!loading && !disabled) onSubmit()
  }

  return (
    <Dialog.Root open={open} onOpenChange={loading ? undefined : onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-40 bg-black/45 backdrop-blur-[2px]" />
        <Dialog.Content className="fixed bottom-0 left-1/2 z-50 flex max-h-[92dvh] w-full max-w-[480px] -translate-x-1/2 flex-col rounded-t-card bg-surface shadow-modal sm:bottom-auto sm:top-1/2 sm:-translate-y-1/2 sm:rounded-card">
          <div className="flex items-center justify-between px-5 pt-5 pb-3">
            <Dialog.Title className="text-title font-semibold text-ink">{title}</Dialog.Title>
            <Dialog.Close
              aria-label="Kapat"
              className="-mr-2 flex size-11 items-center justify-center rounded-chip text-faint active:bg-field"
            >
              <IconCarpi size={20} />
            </Dialog.Close>
          </div>

          <form onSubmit={handleSubmit} className="flex min-h-0 flex-1 flex-col">
            <div className="min-h-0 flex-1 space-y-4 overflow-y-auto px-5 pb-2">{children}</div>

            {error && (
              <p
                role="alert"
                className="mx-5 mt-3 rounded-field bg-danger-soft px-3 py-2.5 text-body text-danger"
              >
                {error}
              </p>
            )}

            <div className="safe-bottom px-5 pt-4">
              <Button type="submit" size="lg" block loading={loading} disabled={disabled}>
                {submitLabel}
              </Button>
            </div>
          </form>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  )
}
