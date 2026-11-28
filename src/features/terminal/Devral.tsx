import { useEffect, useState } from 'react'
import * as Dialog from '@radix-ui/react-dialog'
import { Button, EmptyState } from '../../components/ui/primitives'
import { Spinner } from '../../components/ui/Spinner'
import { IconCarpi, IconGeri, IconKisi } from '../../components/ui/icons'
import { useAuth } from '../../app/providers/AuthProvider'
import { useDevral, useTerminalListe } from './api'
import { useTerminal } from './useTerminal'

const PIN_UZUNLUK = 4
const TUSLAR = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '', '0', 'sil'] as const

/**
 * The shared handheld's sign-in (084, owner 28.11): pick your name, type your
 * 4-digit PIN. A successful PIN is also the shift handover — the server moves
 * the till's open shift to this person in the same call.
 *
 * `onerilen` preselects a name (the reminder knows who is due next).
 */
export function DevralPaneli({
  onBitti,
  onerilen = null,
}: {
  onBitti?: () => void
  onerilen?: string | null
}) {
  const terminal = useTerminal()
  const { profile } = useAuth()
  const liste = useTerminalListe(terminal, true)
  const devral = useDevral()
  const [secili, setSecili] = useState<string | null>(onerilen)
  const [pin, setPin] = useState('')
  const [hata, setHata] = useState<string | null>(null)

  const kisi = liste.data?.find((p) => p.id === secili) ?? null

  useEffect(() => {
    if (pin.length !== PIN_UZUNLUK || !terminal || !secili || devral.isPending) return
    setHata(null)
    devral.mutate(
      { terminal, profileId: secili, pin },
      {
        onSuccess: () => onBitti?.(),
        onError: (e) => {
          setHata(e instanceof Error ? e.message : 'Giriş yapılamadı.')
          setPin('')
        },
      },
    )
    // Fires once per completed PIN; devral/onBitti identity changes must not re-send it.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pin])

  if (!terminal) return null

  if (liste.isPending) {
    return (
      <div className="flex justify-center py-10">
        <Spinner size={28} label="Yükleniyor" />
      </div>
    )
  }
  if (liste.isError) {
    return (
      <div className="space-y-3">
        <p role="alert" className="rounded-field bg-danger-soft px-3 py-2.5 text-body text-danger">
          {liste.error instanceof Error ? liste.error.message : 'Personel listesi alınamadı.'}
        </p>
        <Button variant="secondary" block onClick={() => void liste.refetch()}>
          Tekrar dene
        </Button>
      </div>
    )
  }

  // ---- 1. who is taking over --------------------------------------------
  if (!kisi) {
    if ((liste.data ?? []).length === 0) {
      return (
        <EmptyState
          icon={<IconKisi size={26} />}
          title="PIN'li personel yok"
          hint="Yönetici, Personel ekranından isim ve PIN ile personel eklemeli."
        />
      )
    }
    return (
      <div className="space-y-3">
        <p className="text-body text-soft">Kim devralıyor?</p>
        <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
          {liste.data!.map((p) => (
            <button
              key={p.id}
              type="button"
              onClick={() => {
                setSecili(p.id)
                setPin('')
                setHata(null)
              }}
              className="flex min-h-[56px] items-center justify-between gap-3 rounded-field border border-border bg-surface px-4 text-left text-lead font-medium text-ink active:brightness-95"
            >
              <span className="truncate">{p.ad_soyad || 'İsimsiz'}</span>
              {profile?.id === p.id && <span className="shrink-0 text-label text-faint">şu an</span>}
            </button>
          ))}
        </div>
      </div>
    )
  }

  // ---- 2. their PIN -------------------------------------------------------
  return (
    <div className="space-y-4">
      <div className="flex items-center gap-2">
        <button
          type="button"
          aria-label="Kişiyi değiştir"
          onClick={() => {
            setSecili(null)
            setPin('')
            setHata(null)
          }}
          className="flex size-11 shrink-0 items-center justify-center rounded-chip text-soft active:bg-field"
        >
          <IconGeri size={20} />
        </button>
        <p className="min-w-0 truncate text-lead font-semibold text-ink">{kisi.ad_soyad}</p>
      </div>

      <div className="flex justify-center gap-4" aria-label={`${pin.length} / ${PIN_UZUNLUK} rakam`}>
        {Array.from({ length: PIN_UZUNLUK }, (_, i) => (
          <span
            key={i}
            className={[
              'size-4 rounded-full border-2',
              i < pin.length ? 'border-accent bg-accent' : 'border-border',
            ].join(' ')}
          />
        ))}
      </div>

      {hata && (
        <p role="alert" className="rounded-field bg-danger-soft px-3 py-2.5 text-center text-body text-danger">
          {hata}
        </p>
      )}

      <div className="mx-auto grid max-w-[300px] grid-cols-3 gap-2">
        {TUSLAR.map((t, i) =>
          t === '' ? (
            <span key={i} />
          ) : (
            <button
              key={i}
              type="button"
              disabled={devral.isPending}
              aria-label={t === 'sil' ? 'Sil' : t}
              onClick={() => {
                if (t === 'sil') setPin((p) => p.slice(0, -1))
                else setPin((p) => (p.length < PIN_UZUNLUK ? p + t : p))
              }}
              className="flex min-h-[64px] items-center justify-center rounded-field bg-field text-title font-semibold text-ink active:brightness-95 disabled:opacity-45"
            >
              {t === 'sil' ? '⌫' : t}
            </button>
          ),
        )}
      </div>

      {devral.isPending && (
        <div className="flex justify-center">
          <Spinner size={22} label="Giriş yapılıyor" />
        </div>
      )}
    </div>
  )
}

/** The same panel in a sheet, opened from the terminal strip. */
export function DevralModal({
  open,
  onOpenChange,
  onerilen = null,
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
  onerilen?: string | null
}) {
  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-40 bg-black/45 backdrop-blur-[2px]" />
        <Dialog.Content className="fixed bottom-0 left-1/2 z-50 flex max-h-[92dvh] w-full max-w-[480px] -translate-x-1/2 flex-col rounded-t-card bg-surface shadow-modal sm:bottom-auto sm:top-1/2 sm:-translate-y-1/2 sm:rounded-card">
          <div className="flex min-h-19 items-center justify-between px-5 pt-5 pb-3">
            <Dialog.Title className="text-title font-semibold text-ink">Devral</Dialog.Title>
            <Dialog.Close
              aria-label="Kapat"
              className="flex size-11 items-center justify-center rounded-chip text-soft active:bg-field"
            >
              <IconCarpi size={20} />
            </Dialog.Close>
          </div>
          <Dialog.Description className="sr-only">
            Vardiyayı devralmak için adınızı seçip PIN'inizi girin.
          </Dialog.Description>
          <div className="overflow-y-auto px-5 pb-[calc(20px+env(safe-area-inset-bottom))]">
            {open && <DevralPaneli onerilen={onerilen} onBitti={() => onOpenChange(false)} />}
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  )
}
