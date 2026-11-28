import { useEffect, useState } from 'preact/hooks'
import { terminalOku } from '../../../src/features/terminal/terminal'
import { Dugme, Ekran, Hata, Kart, Satir } from '../parcalar'
import { benKimim, type Ben } from '../oturumIslem'
import type { EkranOzellik } from '../main'

/**
 * Profil on the shared terminal: who holds the shift and the device's name.
 * No sign-out — on the terminal the hand-over is Devral (084/085).
 */
export function Profil({ s, depo, git }: EkranOzellik) {
  const [ben, setBen] = useState<Ben | null>(null)
  const [hata, setHata] = useState<string | null>(null)
  useEffect(() => {
    benKimim(s).then(setBen, (e: Error) => setHata(e.message))
  }, [])
  const t = terminalOku(depo)
  return (
    <Ekran baslik="Profil">
      <Hata metin={hata} />
      <Kart>
        <Satir k="Vardiyada" v={ben ? ben.ad_soyad : '…'} />
        <Satir k="Rol" v={ben ? (ben.rol === 'YONETICI' ? 'Yönetici' : 'Personel') : '…'} />
        {t && <Satir k="Cihaz" v={t.ad} />}
      </Kart>
      <p class="bilgi">Vardiyayı başka biri alacaksa Devral'a basın; o kişi kendi PIN'ini girer.</p>
      <Dugme metin="Devral" buyuk onBas={() => git({ ekran: 'pin' })} />
    </Ekran>
  )
}
