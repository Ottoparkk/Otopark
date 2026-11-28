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
    const dinle = () => setHash(window.location.hash)
    window.addEventListener('hashchange', dinle)
    return () => window.removeEventListener('hashchange', dinle)
  }, [])

  const yol = acilisYolu(terminalOku(depo) !== null, sunucu.oturum() !== null, yolOku(hash))
  const o: EkranOzellik = { s: sunucu, depo, git }

  switch (yol.ekran) {
    case 'kurulum':
      return <Kurulum {...o} />
    case 'pin':
      // Keyed by who is signed in, so Devral starts from a fresh list.
      return <Pin key={sunucu.oturum()?.user_id ?? 'yok'} {...o} />
    case 'gise':
      return <Gise {...o} />
    case 'giris':
      return <Giris {...o} />
    case 'fis':
      return <Fis key={yol.biletId} {...o} biletId={yol.biletId} />
  }
}

render(<Uygulama />, document.getElementById('uygulama')!)
