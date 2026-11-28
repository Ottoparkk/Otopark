import type { ComponentChildren, JSX } from 'preact'

/**
 * The terminal's few building blocks. Flat, ≥ 44 px targets, no animation
 * (spec 2026-11-28). Spacing with margins: Chrome 56 has no flex `gap`.
 */

export function Dugme({
  metin,
  onBas,
  mesgul = false,
  ikincil = false,
  devreDisi = false,
  buyuk = false,
}: {
  metin: string
  onBas: () => void
  mesgul?: boolean
  ikincil?: boolean
  devreDisi?: boolean
  buyuk?: boolean
}) {
  const sinif = ['dugme', ikincil ? 'dugme-ikincil' : 'dugme-ana', buyuk ? 'dugme-buyuk' : ''].join(' ')
  return (
    <button type="button" class={sinif} disabled={mesgul || devreDisi} onClick={onBas}>
      {mesgul ? 'Bekleyin…' : metin}
    </button>
  )
}

export function Alan({
  etiket,
  ...input
}: { etiket: string } & JSX.IntrinsicElements['input']) {
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
