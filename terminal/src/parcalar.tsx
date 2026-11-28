import type { ComponentChildren, JSX } from 'preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import type { OdemeYontemi } from '../../src/lib/types'
import type { Sunucu } from './sunucu'
import type { Yol } from './yol'

/**
 * The terminal's few building blocks. Flat, ≥ 44 px targets, no animation
 * (spec 2026-11-28). Spacing with margins: Chrome 56 has no flex `gap`.
 */

export function Dugme({
  metin,
  onBas,
  mesgul = false,
  ikincil = false,
  yumusak = false,
  devreDisi = false,
  buyuk = false,
}: {
  metin: string
  onBas: () => void
  mesgul?: boolean
  ikincil?: boolean
  yumusak?: boolean
  devreDisi?: boolean
  buyuk?: boolean
}) {
  const sinif = ['dugme', yumusak ? 'dugme-yumusak' : ikincil ? 'dugme-ikincil' : 'dugme-ana', buyuk ? 'dugme-buyuk' : ''].join(' ')
  return (
    <button type="button" class={sinif} disabled={mesgul || devreDisi} onClick={onBas}>
      {mesgul ? 'Bekleyin…' : metin}
    </button>
  )
}

export function Alan({ etiket, ...input }: { etiket: string } & JSX.IntrinsicElements['input']) {
  return (
    <label class="alan">
      <span class="alan-etiket">{etiket}</span>
      <input class="alan-girdi" {...input} />
    </label>
  )
}

export function Hata({ metin }: { metin: string | null }) {
  if (!metin) return null
  return (
    <p class="hata" role="alert">
      {metin}
    </p>
  )
}

export function Bilgi({ metin }: { metin: string | null }) {
  if (!metin) return null
  return <p class="bilgi">{metin}</p>
}

export function Ekran({ baslik, children, ust }: { baslik: string; children: ComponentChildren; ust?: ComponentChildren }) {
  return (
    <div class="ekran">
      <header class="ust-cubuk">
        <h1 class="baslik">{baslik}</h1>
        {ust}
      </header>
      <main class="icerik">{children}</main>
    </div>
  )
}

/* ---- Whole terminal (owner 28.11): parts for the Personel screens ---------- */

/** Bottom tab bar, like the main app's for a Personel: Gişe, Abonman, Profil. */
export function Sekmeler({ etkin, git }: { etkin: 'gise' | 'abonman' | 'profil' | null; git: (y: Yol) => void }) {
  const s = (ad: 'gise' | 'abonman' | 'profil', metin: string) => (
    <button type="button" class={etkin === ad ? 'sekme etkin' : 'sekme'} onClick={() => git({ ekran: ad })}>
      {metin}
    </button>
  )
  return (
    <nav class="sekmeler">
      {s('gise', 'Gişe')}
      {s('abonman', 'Abonman')}
      {s('profil', 'Profil')}
    </nav>
  )
}

const YONTEMLER: { y: OdemeYontemi; metin: string }[] = [
  { y: 'NAKIT', metin: 'Nakit' },
  { y: 'KREDI_KARTI', metin: 'Kart' },
  { y: 'HAVALE', metin: 'Havale' },
]

/** Payment method, chosen every time from nothing (owner, 23.11). */
export function YontemSecici({ deger, sec }: { deger: OdemeYontemi | null; sec: (y: OdemeYontemi) => void }) {
  return (
    <div class="yontemler">
      {YONTEMLER.map((x) => (
        <button key={x.y} type="button" class={deger === x.y ? 'yontem secili' : 'yontem'} onClick={() => sec(x.y)}>
          {x.metin}
        </button>
      ))}
    </div>
  )
}

/** A white card. */
export function Kart({ children, ton }: { children: ComponentChildren; ton?: 'uyari' | 'basari' | 'marka' }) {
  return <section class={ton ? `kart kart-${ton}` : 'kart'}>{children}</section>
}

/** One label / value line. */
export function Satir({ k, v }: { k: string; v: ComponentChildren }) {
  return (
    <p class="satir">
      <span class="satir-k">{k}</span>
      <span class="satir-v">{v}</span>
    </p>
  )
}

export function Rozet({ metin, ton }: { metin: string; ton?: 'uyari' | 'basari' | 'tehlike' | 'marka' }) {
  return <span class={ton ? `rozet rozet-${ton}` : 'rozet'}>{metin}</span>
}

/** A back button for the top bar. */
export function Geri({ onBas, metin = 'Geri' }: { onBas: () => void; metin?: string }) {
  return (
    <button type="button" class="ust-dugme" onClick={onBas}>
      {metin}
    </button>
  )
}

/**
 * Runs one money or state call at a time: a second tap while the first is in
 * flight does nothing (the bench showed taps land before a redraw).
 */
export function useTekSefer(): [boolean, (is: () => Promise<unknown>, bitti?: () => void, hata?: (m: string) => void) => void] {
  const [mesgul, setMesgul] = useState(false)
  const suren = useRef(false)
  function calistir(is: () => Promise<unknown>, bitti?: () => void, hata?: (m: string) => void) {
    if (suren.current) return
    suren.current = true
    setMesgul(true)
    let p: Promise<unknown>
    try {
      p = is()
    } catch (e) {
      p = Promise.reject(e)
    }
    p.then(
      () => {
        suren.current = false
        setMesgul(false)
        if (bitti) bitti()
      },
      (e: Error) => {
        suren.current = false
        setMesgul(false)
        if (hata) hata(e && e.message ? e.message : 'Bir hata oldu. Tekrar deneyin.')
      },
    )
  }
  return [mesgul, calistir]
}

/** Loads now and again every `ms` (spec: polling, no realtime). */
export function useYukle<T>(yukle: () => Promise<T>, bagimli: unknown[], ms = 15000) {
  const [veri, setVeri] = useState<T | null>(null)
  const [hata, setHata] = useState<string | null>(null)
  const sira = useRef(0)
  function yenile() {
    const benim = ++sira.current
    yukle().then(
      (v) => {
        if (benim !== sira.current) return
        setVeri(v)
        setHata(null)
      },
      (e: Error) => {
        if (benim !== sira.current) return
        setHata(e.message)
      },
    )
  }
  useEffect(() => {
    yenile()
    if (!ms) return undefined
    const t = window.setInterval(yenile, ms)
    return () => window.clearInterval(t)
  }, bagimli)
  return { veri, hata, yenile }
}

/**
 * A plate photo, loaded only when it scrolls into view (spec), small; a tap
 * shows it full width.
 */
export function Foto({ s, yol, etiket }: { s: Sunucu; yol: string | null; etiket?: string }) {
  const kutu = useRef<HTMLDivElement>(null)
  const [url, setUrl] = useState<string | null>(null)
  const [buyuk, setBuyuk] = useState(false)
  const [yok, setYok] = useState(false)
  useEffect(() => {
    if (!yol || !kutu.current) return undefined
    let bitti = false
    const al = () => {
      s.imzaliUrl('plaka-foto', yol, 600).then(
        (u) => {
          if (!bitti) setUrl(u)
        },
        () => {
          if (!bitti) setYok(true)
        },
      )
    }
    const IO = (
      window as unknown as {
        IntersectionObserver?: typeof IntersectionObserver
      }
    ).IntersectionObserver
    if (!IO) {
      al()
      return () => {
        bitti = true
      }
    }
    const g = new IO((kayitlar) => {
      for (const k of kayitlar) {
        if (k.isIntersecting || k.intersectionRatio > 0) {
          g.disconnect()
          al()
          return
        }
      }
    })
    g.observe(kutu.current)
    return () => {
      bitti = true
      g.disconnect()
    }
  }, [yol])
  if (!yol) return null
  return (
    <div ref={kutu} class={buyuk ? 'foto foto-buyuk' : 'foto'} onClick={() => setBuyuk(!buyuk)}>
      {url ? <img src={url} alt={etiket || 'Plaka fotoğrafı'} /> : <span class="foto-yer">{yok ? 'Fotoğraf açılamadı' : 'Fotoğraf'}</span>}
      {etiket && <span class="foto-etiket">{etiket}</span>}
    </div>
  )
}

export type Ton = 'marka' | 'basari' | 'tehlike' | 'uyari' | 'notr'

/** A state chip, as the main app's Chip. */
export function Cip({ metin, ton }: { metin: string; ton: Ton }) {
  return <span class={`cip-durum ton-${ton}`}>{metin}</span>
}

/** The plate, with the record's state chip on the right (main app's PlakaBasligi). */
export function PlakaBasligi({ plaka, cip }: { plaka: string; cip: ComponentChildren }) {
  return (
    <div class="plaka-satiri">
      <p class="buyuk-plaka">{plaka}</p>
      {cip}
    </div>
  )
}

/** The payment method in its own colour (main app's ODEME_CHIP). */
export function OdemeCip({ yontem, etiket }: { yontem: OdemeYontemi; etiket: string }) {
  return <span class={`cip-durum odeme-${yontem}`}>{etiket}</span>
}

/** Two figures side by side (Ücret / Süre), like the main app's ticket page. */
export function Ikili({ a, b }: { a: { k: string; v: string }; b: { k: string; v: string } }) {
  return (
    <div class="ikili">
      <div class="ikili-hucre">
        <p class="ikili-v">{a.v}</p>
        <p class="ikili-k">{a.k}</p>
      </div>
      <div class="ikili-hucre">
        <p class="ikili-v">{b.v}</p>
        <p class="ikili-k">{b.k}</p>
      </div>
    </div>
  )
}

/** The main app's floating bar: fixed above the tabs, with a spacer so nothing hides behind it. */
export function AltBar({ children }: { children: ComponentChildren }) {
  return (
    <>
      <div class="alt-bar-bosluk" />
      <div class="alt-bar">{children}</div>
    </>
  )
}
