import type { ReactNode } from 'react'
import * as Dialog from '@radix-ui/react-dialog'
import { IconCarpi } from './icons'

/**
 * A read-only bottom sheet: a title and whatever list it holds. The detail
 * one tap below a summary row (Vardiya raporu, owner 28.11 — "like Rocket
 * Money"), so the summary itself stays short. Styling matches the Devral
 * sheet; on a wide screen it centres like the other dialogs.
 */
export function AltSayfa({
  open,
  onOpenChange,
  baslik,
  aciklama,
  children,
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
  baslik: string
  /** For screen readers; the sheet's purpose in one sentence. */
  aciklama?: string
  children: ReactNode
}) {
  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-40 bg-black/45 backdrop-blur-[2px]" />
        <Dialog.Content className="fixed bottom-0 left-1/2 z-50 flex max-h-[85dvh] w-full max-w-[480px] -translate-x-1/2 flex-col rounded-t-card bg-surface shadow-modal sm:bottom-auto sm:top-1/2 sm:-translate-y-1/2 sm:rounded-card">
          <div className="flex min-h-16 items-center justify-between px-5 pt-4 pb-2">
            <Dialog.Title className="text-title font-semibold text-ink">{baslik}</Dialog.Title>
            <Dialog.Close
              aria-label="Kapat"
              className="flex size-11 items-center justify-center rounded-chip text-soft active:bg-field"
            >
              <IconCarpi size={20} />
            </Dialog.Close>
          </div>
          <Dialog.Description className="sr-only">{aciklama ?? baslik}</Dialog.Description>
          <div className="overflow-y-auto px-5 pb-[calc(20px+env(safe-area-inset-bottom))]">
            {children}
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  )
}
