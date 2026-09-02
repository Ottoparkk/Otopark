import { useState } from 'react'
import {
  Button,
  Card,
  Chip,
  EmptyState,
  ListeDurumu,
  ScreenHeader,
} from '../../components/ui/primitives'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { COP_TABLO_ETIKET, useCop, useCopGeriAl, useCopKaliciSil, type CopKaydi } from './api'
import { formatGoreceli } from '../../lib/dates'
import { rpcErrorText } from '../../lib/errors'
import { IconCop, IconGeri } from '../../components/ui/icons'

/**
 * Çöp Kutusu — every deleted record, newest first.
 *
 * Restoring is the point of the screen, so it is the plain button and
 * permanent deletion is the quiet one. Both are Yönetici-only in the RPC; the
 * route guard only saves a Personel from a screen that would refuse them.
 *
 * The bin holds the most recent 200 deletions. Older entries fall out and are
 * genuinely gone, which the footer says out loud rather than leaving someone
 * to discover it when a restore they expected is not there.
 */
export default function Cop() {
  const { data: liste = [], isPending, error, refetch } = useCop()
  const geriAl = useCopGeriAl()
  const kaliciSil = useCopKaliciSil()

  const [silinecek, setSilinecek] = useState<CopKaydi | null>(null)
  const [hata, setHata] = useState<string | null>(null)
  const [silHata, setSilHata] = useState<string | null>(null)

  return (
    <div>
      <ScreenHeader title="Çöp Kutusu" back="/yonetim" />

      <div className="space-y-4 px-5 md:mx-auto md:max-w-[760px]">
        {/* A restore can put money back into a closed shift, so this is not a
            neutral action and the screen should not pretend otherwise. */}
        <p className="rounded-card bg-field px-4 py-3 text-label text-soft">
          Silinen kayıt buraya düşer. Geri alındığında tahsilatları da geri gelir ve
          etkilenen vardiyanın kasa farkı yeniden hesaplanır.
        </p>

        {hata != null && (
          <p className="rounded-card bg-danger-soft px-4 py-3 text-body text-danger">{hata}</p>
        )}

        <div className="space-y-2">
          <ListeDurumu
            pending={isPending}
            error={error}
            onRetry={() => void refetch()}
            empty={liste.length === 0}
            bos={
              <EmptyState
                icon={<IconCop size={44} />}
                title="Çöp kutusu boş"
                hint="Silinen kayıtlar burada listelenir ve geri alınabilir."
              />
            }
          >
            {liste.map((c) => (
              <Card key={c.id} className="flex items-center gap-3">
                <div className="min-w-0 flex-1">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="truncate text-body font-medium text-ink">{c.ozet}</span>
                    <Chip>{COP_TABLO_ETIKET[c.tablo] ?? c.tablo}</Chip>
                  </div>
                  <p className="mt-0.5 truncate text-label text-faint">
                    {formatGoreceli(c.silindi_at)}
                    {c.silen_profil ? ` · ${c.silen_profil.ad_soyad}` : ''}
                  </p>
                </div>

                <Button
                  variant="ghost"
                  onClick={() => {
                    setHata(null)
                    void geriAl
                      .mutateAsync(c.id)
                      .catch((e) => setHata(rpcErrorText(e, 'Geri alınamadı.')))
                  }}
                  loading={geriAl.isPending && geriAl.variables === c.id}
                >
                  <IconGeri size={17} />
                  Geri al
                </Button>

                <button
                  type="button"
                  onClick={() => {
                    setSilHata(null)
                    setSilinecek(c)
                  }}
                  aria-label="Kalıcı olarak sil"
                  className="flex size-11 shrink-0 items-center justify-center rounded-chip text-faint active:bg-field"
                >
                  <IconCop size={18} />
                </button>
              </Card>
            ))}
          </ListeDurumu>
        </div>

        {liste.length > 0 && (
          <p className="text-label text-faint">
            En son 200 silme saklanır; daha eskiler kalıcı olarak kaybolur.
          </p>
        )}
      </div>

      <ConfirmDialog
        open={silinecek !== null}
        onOpenChange={() => setSilinecek(null)}
        tone="danger"
        title="Kalıcı olarak sil"
        description={
          silinecek
            ? `"${silinecek.ozet}" çöp kutusundan da silinecek. Bu işlem geri alınamaz.`
            : ''
        }
        confirmLabel="Kalıcı Sil"
        loading={kaliciSil.isPending}
        error={silHata}
        onConfirm={() => {
          if (!silinecek) return
          void kaliciSil
            .mutateAsync(silinecek.id)
            .then(() => setSilinecek(null))
            .catch((e) => setSilHata(rpcErrorText(e, 'Silinemedi.')))
        }}
      />
    </div>
  )
}
