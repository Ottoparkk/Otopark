import { FormModal } from '../../components/ui/FormModal'
import { IconTik, IconCarpi } from '../../components/ui/icons'

/**
 * What each role can reach — section names only, as they appear in the app
 * (owner, 2026-11-07: "don't flood with text"). Somebody reading this is
 * about to promote or demote a person; the question in their head is "will
 * they see Finans?", and a name answers it.
 *
 * Written from the route guards (App.tsx) and the RLS policies / RPC guards
 * behind them, not from which buttons happen to be visible. Keep it in step
 * with those when a section is added.
 */

const GORUR = ['Gişe', 'Vardiya', 'Çözülmemiş kayıtlar', 'Bildirimler', 'Profil']

const GOREMEZ = [
  'Finans',
  'Abonmanlar',
  'Puan hesapları',
  'Personel',
  'Otopark ayarları',
  'Kamera kurulumu',
  'Çöp Kutusu',
]

function Satir({ ad, olumlu }: { ad: string; olumlu: boolean }) {
  return (
    <li className="flex items-center gap-2.5">
      <span
        className={`flex size-5 shrink-0 items-center justify-center rounded-full ${
          olumlu ? 'bg-success-soft text-success' : 'bg-field text-faint'
        }`}
      >
        {olumlu ? <IconTik size={13} /> : <IconCarpi size={12} />}
      </span>
      <span className="text-body text-ink">{ad}</span>
    </li>
  )
}

function Bolum({
  baslik,
  maddeler,
  olumlu,
  ilk = false,
}: {
  baslik: string
  maddeler: string[]
  olumlu: boolean
  ilk?: boolean
}) {
  return (
    <div className={ilk ? undefined : 'border-t border-divider pt-4'}>
      <p className="mb-2 text-label font-medium tracking-wide text-faint uppercase">{baslik}</p>
      <ul className="space-y-2">
        {maddeler.map((m) => (
          <Satir key={m} ad={m} olumlu={olumlu} />
        ))}
      </ul>
    </div>
  )
}

export function RolBilgisi({
  open,
  onOpenChange,
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
}) {
  return (
    <FormModal
      open={open}
      onOpenChange={onOpenChange}
      title="Rol bilgisi"
      submitLabel="Kapat"
      onSubmit={() => onOpenChange(false)}
    >
      <Bolum baslik="Personel görür" maddeler={GORUR} olumlu ilk />
      <Bolum baslik="Personel göremez" maddeler={GOREMEZ} olumlu={false} />
      <Bolum baslik="Yönetici" maddeler={['Her şey']} olumlu />
    </FormModal>
  )
}
