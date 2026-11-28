import { useState } from 'preact/hooks'
import { pinGecerli, terminalYaz } from '../../../src/features/terminal/terminal'
import { Alan, Bilgi, Dugme, Ekran, Hata } from '../parcalar'
import { kurulumYap } from '../oturumIslem'
import type { EkranOzellik } from '../main'

/**
 * Kurulum (spec 2026-11-28): the full app's "Bu cihazı terminal yap" cannot
 * run in Chrome 56, so a Yönetici registers the P2 here once.
 */
export function Kurulum({ s, depo, git }: EkranOzellik) {
  const [eposta, setEposta] = useState('')
  const [sifre, setSifre] = useState('')
  const [ad, setAd] = useState('Gişe terminali')
  const [mesgul, setMesgul] = useState(false)
  const [hata, setHata] = useState<string | null>(null)

  function yap() {
    if (!depo) {
      setHata('Bu tarayıcı kayıt tutamıyor. Gizli sekmede olmadığınızı kontrol edin.')
      return
    }
    setMesgul(true)
    setHata(null)
    kurulumYap(s, depo, { eposta, sifre, ad }, { terminalYaz, pinGecerli }).then(
      () => git({ ekran: 'pin' }),
      (e: Error) => {
        setMesgul(false)
        setHata(e.message)
      },
    )
  }

  return (
    <Ekran baslik="Bu cihazı terminal yap">
      <Bilgi metin="Bir Yönetici bir kez giriş yapar. Sonra çıkış yapılır." />
      <Alan
        etiket="E-posta"
        type="email"
        autoComplete="username"
        value={eposta}
        onInput={(e) => setEposta(e.currentTarget.value)}
      />
      <Alan
        etiket="Şifre"
        type="password"
        autoComplete="current-password"
        value={sifre}
        onInput={(e) => setSifre(e.currentTarget.value)}
      />
      <Alan etiket="Cihaz adı" value={ad} maxLength={40} onInput={(e) => setAd(e.currentTarget.value)} />
      <Hata metin={hata} />
      <Dugme
        metin="Terminal yap"
        onBas={yap}
        mesgul={mesgul}
        devreDisi={!eposta.trim() || !sifre}
        buyuk
      />
    </Ekran>
  )
}
