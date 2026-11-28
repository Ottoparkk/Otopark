import { render } from 'preact'
import { useEffect, useState } from 'preact/hooks'
import { rpcErrorText } from '../../src/lib/errors'
import { terminalOku } from '../../src/features/terminal/terminal'
import { sunucuKur, type Depo, type Sunucu } from './sunucu'
import { acilisYolu, yolOku, yolYaz, type Yol } from './yol'
import { Kurulum } from './ekranlar/Kurulum'
import { Pin } from './ekranlar/Pin'
import { Gise } from './ekranlar/Gise'
import { Giris } from './ekranlar/Giris'
import { Fis } from './ekranlar/Fis'
import { Bilet } from './ekranlar/Bilet'
import { Kayip } from './ekranlar/Kayip'
import { Istisnalar } from './ekranlar/Istisnalar'
import { Abonman, AbonmanDetay } from './ekranlar/Abonman'
import { Profil } from './ekranlar/Profil'
import { Sekmeler } from './parcalar'
import './stil.css'

function depoAl(): Depo | null {
  try {
    return window.localStorage
  } catch (e) {
    return null
  }
}

const depo = depoAl()
const sunucu: Sunucu = sunucuKur({
  url: import.meta.env.VITE_SUPABASE_URL,
  anahtar: import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY,
  fetch: (girdi, init) => window.fetch(girdi, init),
  depo,
  simdi: () => Date.now(),
  hataMetni: rpcErrorText,
})

/** What every screen gets: the server and a way to move. */
export interface EkranOzellik {
  s: Sunucu
  depo: Depo | null
  git: (y: Yol) => void
}

export function git(y: Yol) {
  const h = yolYaz(y)
  if (window.location.hash === h) window.dispatchEvent(new HashChangeEvent('hashchange'))
  else window.location.hash = h
}

function Uygulama() {
  const [hash, setHash] = useState(window.location.hash)
  useEffect(() => {
    // A new screen starts at the top (hash routes keep the old scroll).
    const dinle = () => {
      setHash(window.location.hash)
      window.scrollTo(0, 0)
    }
    window.addEventListener('hashchange', dinle)
    return () => window.removeEventListener('hashchange', dinle)
  }, [])

  const yol = acilisYolu(terminalOku(depo) !== null, sunucu.oturum() !== null, yolOku(hash))
  const o: EkranOzellik = { s: sunucu, depo, git }

  if (yol.ekran === 'kurulum') return <Kurulum {...o} />
  // Keyed by who is signed in, so Devral starts from a fresh list.
  if (yol.ekran === 'pin') return <Pin key={sunucu.oturum()?.user_id ?? 'yok'} {...o} />

  // Signed in: the screen plus the main app's bottom tabs (Personel: Gişe,
  // Abonman, Profil). Every other screen hangs off Gişe, as in the app.
  const sekme = yol.ekran === 'abonman' || yol.ekran === 'abonmanDetay' ? 'abonman' : yol.ekran === 'profil' ? 'profil' : 'gise'
  return (
    <div class="kabuk">
      <Ekranlar yol={yol} o={o} />
      <Sekmeler etkin={sekme} git={git} />
    </div>
  )
}

function Ekranlar({ yol, o }: { yol: Yol; o: EkranOzellik }) {
  switch (yol.ekran) {
    case 'giris':
      return <Giris {...o} />
    case 'fis':
      return <Fis key={yol.biletId} {...o} biletId={yol.biletId} />
    case 'cfis':
      return <Fis key={'c' + yol.biletId} {...o} biletId={yol.biletId} tur="CIKIS" />
    case 'bilet':
      return <Bilet key={yol.biletId} {...o} biletId={yol.biletId} />
    case 'kayip':
      return <Kayip {...o} />
    case 'istisnalar':
      return <Istisnalar {...o} />
    case 'abonman':
      return <Abonman {...o} />
    case 'abonmanDetay':
      return <AbonmanDetay key={yol.id} {...o} id={yol.id} />
    case 'profil':
      return <Profil {...o} />
    default:
      return <Gise {...o} />
  }
}

render(<Uygulama />, document.getElementById('uygulama')!)
