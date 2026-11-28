import { useEffect, useState } from 'preact/hooks'
import { Dugme, Ekran, Hata } from '../parcalar'
import { benKimim, type Ben } from '../oturumIslem'
import type { EkranOzellik } from '../main'

/** Gişe, stage 1: who is working, Devral, and Giriş. İçeride / Çıkış come in stage 2. */
export function Gise({ s, git }: EkranOzellik) {
  const [ben, setBen] = useState<Ben | null>(null)
  const [hata, setHata] = useState<string | null>(null)

  useEffect(() => {
    benKimim(s).then(setBen, (e: Error) => {
      setHata(e.message)
      // A dead session: back to PIN.
      if (!s.oturum()) git({ ekran: 'pin' })
    })
  }, [])

  const ust = (
    <button type="button" class="ust-dugme" onClick={() => git({ ekran: 'pin' })}>
      Devral
    </button>
  )

  return (
    <Ekran baslik={ben ? ben.ad_soyad : 'Gişe'} ust={ust}>
      <Hata metin={hata} />
      <Dugme metin="Giriş" onBas={() => git({ ekran: 'giris' })} buyuk />
    </Ekran>
  )
}
