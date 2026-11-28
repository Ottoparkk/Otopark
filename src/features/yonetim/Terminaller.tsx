import { useState } from 'react'
import { Button, Card, Chip, EmptyState, Input, ListeDurumu, ScreenHeader } from '../../components/ui/primitives'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { IconCop, IconTerminal } from '../../components/ui/icons'
import { formatGoreceli } from '../../lib/dates'
import { rpcErrorText } from '../../lib/errors'
import { useTerminalKaldir, useTerminalKaydet, useTerminaller, type TerminalSatiri } from '../terminal/api'
import { buCihaziTerminalYap, terminalKaydiniSil, useTerminal } from '../terminal/useTerminal'

/**
 * The shared handheld(s) at the gate (084, owner 28.11). The Yönetici signs in
 * ON the device once and taps "Bu cihazı terminal yap": the device keeps its
 * own secret, and from then on workers switch on it with name + PIN.
 */
export default function Terminaller() {
  const buCihaz = useTerminal()
  const { data: liste = [], isPending, error, refetch } = useTerminaller()
  const kaydet = useTerminalKaydet()
  const kaldir = useTerminalKaldir()

  const [ad, setAd] = useState('Gişe terminali')
  const [hata, setHata] = useState<string | null>(null)
  const [kaldirHedef, setKaldirHedef] = useState<TerminalSatiri | null>(null)
  const [kaldirHata, setKaldirHata] = useState<string | null>(null)

  return (
    <div>
      <ScreenHeader title="Terminaller" subtitle="Ortak el terminali" back="/yonetim" />

      <div className="space-y-5 px-5">
        <Card>
          {buCihaz ? (
            <div className="space-y-3">
              <div className="flex items-center gap-2">
                <Chip tone="success">Bu cihaz terminal</Chip>
                <p className="min-w-0 truncate text-body font-medium text-ink">{buCihaz.ad}</p>
              </div>
              <p className="text-body text-soft">
                Personel bu cihazda adını seçip PIN'ini girerek devralır. Giriş ekranında e-posta ile
                giriş de bir dokunuş uzakta kalır.
              </p>
            </div>
          ) : (
            <form
              className="space-y-3"
              onSubmit={(e) => {
                e.preventDefault()
                setHata(null)
                void kaydet
                  .mutateAsync(ad.trim())
                  .then((k) => buCihaziTerminalYap(k))
                  .catch((err) => setHata(rpcErrorText(err, 'Terminal kaydedilemedi.')))
              }}
            >
              <p className="text-body text-soft">
                Bu işlemi ortak el terminalinin <span className="font-medium text-ink">kendisinde</span>{' '}
                yapın. Cihaz kendi anahtarını saklar; personel orada isim + PIN ile devralır.
              </p>
              <Input label="Terminal adı" name="terminal_ad" value={ad} onChange={(e) => setAd(e.target.value)} />
              {hata && (
                <p role="alert" className="rounded-field bg-danger-soft px-3 py-2.5 text-body text-danger">
                  {hata}
                </p>
              )}
              <Button type="submit" block loading={kaydet.isPending} disabled={!ad.trim()}>
                Bu cihazı terminal yap
              </Button>
            </form>
          )}
        </Card>

        <section>
          <p className="mb-2 text-label font-medium tracking-wide text-faint uppercase">
            Kayıtlı terminaller
          </p>
          <ListeDurumu
            pending={isPending}
            error={error}
            onRetry={() => void refetch()}
            empty={liste.length === 0}
            bos={<EmptyState icon={<IconTerminal size={26} />} title="Kayıtlı terminal yok" />}
          >
            <div className="space-y-2">
              {liste.map((t) => (
                <Card key={t.id} className="flex items-center gap-3">
                  <IconTerminal size={22} className="shrink-0 text-soft" />
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-body font-semibold text-ink">
                      {t.ad}
                      {buCihaz?.id === t.id && (
                        <span className="ml-2 text-label font-normal text-faint">(bu cihaz)</span>
                      )}
                    </p>
                    <p className="text-label text-faint">
                      {t.son_gorulme ? `Son kullanım ${formatGoreceli(t.son_gorulme)}` : 'Henüz kullanılmadı'}
                    </p>
                  </div>
                  <button
                    type="button"
                    aria-label="Terminali kaldır"
                    onClick={() => {
                      setKaldirHata(null)
                      setKaldirHedef(t)
                    }}
                    className="flex size-11 shrink-0 items-center justify-center rounded-field bg-danger-soft text-danger active:brightness-95"
                  >
                    <IconCop size={18} />
                  </button>
                </Card>
              ))}
            </div>
          </ListeDurumu>
        </section>
      </div>

      <ConfirmDialog
        open={kaldirHedef !== null}
        onOpenChange={() => setKaldirHedef(null)}
        tone="danger"
        title="Terminali kaldır"
        description={`${kaldirHedef?.ad ?? 'Bu terminal'} artık PIN ile giriş yapamaz. Kayıtlar silinmez; gerekirse cihaz yeniden terminal yapılabilir.`}
        confirmLabel="Kaldır"
        loading={kaldir.isPending}
        error={kaldirHata}
        onConfirm={() => {
          if (!kaldirHedef) return
          const hedef = kaldirHedef
          void kaldir
            .mutateAsync(hedef.id)
            .then(() => {
              if (buCihaz?.id === hedef.id) terminalKaydiniSil()
              setKaldirHedef(null)
            })
            .catch((e) => setKaldirHata(rpcErrorText(e, 'Terminal kaldırılamadı.')))
        }}
      />
    </div>
  )
}
